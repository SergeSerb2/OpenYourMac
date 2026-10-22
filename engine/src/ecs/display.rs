use bevy::app::{App, Plugin, PreUpdate};
use bevy::ecs::change_detection::{DetectChanges, DetectChangesMut};
use bevy::ecs::component::Component;
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::Add;
use bevy::ecs::message::MessageReader;
use bevy::ecs::observer::On;
use bevy::ecs::query::{Has, Or, With};
use bevy::ecs::schedule::IntoScheduleConfigs;
use bevy::ecs::system::{Commands, Local, NonSend, Populated, Query, Res};
use bevy::ecs::world::World;
use bevy::math::IRect;
use bevy::platform::collections::HashSet;
use bevy::time::{Time, Timer, TimerMode};
use objc2_app_kit::NSScreen;
use objc2_core_graphics::CGDirectDisplayID;
use std::collections::HashMap;
use std::pin::Pin;
use std::time::{Duration, Instant};
use tracing::{Level, debug, error, instrument, warn};

use crate::config::Config;
use crate::ecs::layout::{LayoutStrip, PARKED_STRIP_SLIVER};
use crate::ecs::workspace::PreviousStripPosition;
use crate::ecs::{
    ActiveDisplayMarker, ActiveWorkspaceMarker, EnsureVisibleMarker, FocusedMarker, LayoutPosition,
    ManualStripOffset, Position, ReadDisplayProperties, RepositionMarker, SendMessageTrigger,
    SpawnCommandsExt, Timeout,
};
use crate::events::Event;
use crate::manager::{Display, WindowManager, irect_from};
use crate::platform::{PlatformCallbacks, WorkspaceId};
use crate::util::{read_screen_property, round_px};

const ORPHANED_SPACES_TIMEOUT_SEC: u64 = 30;
const DISPLAY_SETTLE_DELAY: Duration = Duration::from_millis(350);
const DISPLAY_VERIFY_DELAY: Duration = Duration::from_secs(1);
const DISPLAY_RETRY_DELAY: Duration = Duration::from_secs(1);
const DISPLAY_RETRIES: u8 = 3;

#[derive(Default)]
pub(crate) struct DisplayReconcileState {
    pending: Option<Timer>,
    retries_left: u8,
    verify_again: bool,
    ignored: Vec<String>,
}

pub struct DisplayEventsPlugin;

impl Plugin for DisplayEventsPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            PreUpdate,
            (display_change_handler, reconcile_displays)
                .chain()
                .after(super::systems::pump_events),
        )
        .add_systems(
            bevy::app::Update,
            (
                release_ignored_windows,
                adopt_released_windows.run_if(released_windows_pending),
            )
                .chain()
                .after(super::triggers::refresh_configuration_trigger)
                .after(super::systems::window_moved_update_frame)
                .after(super::systems::window_resized_update_frame)
                .before(super::triggers::apply_window_defaults)
                .before(super::layout::layout_strip_changed),
        )
        .add_observer(read_display_properties_trigger)
        .add_observer(cleanup_active_display_marker);
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn cleanup_active_display_marker(
    trigger: On<Add, ActiveDisplayMarker>,
    displays: Query<(Entity, Has<ActiveDisplayMarker>), With<Display>>,
    mut commands: Commands,
) {
    for (entity, active) in displays {
        if active
            && entity != trigger.entity
            && let Ok(mut cmd) = commands.get_entity(entity)
        {
            debug!("Display id {entity} lost active marker.");
            cmd.try_remove::<ActiveDisplayMarker>();
        }
    }
}

/// Handles display change events.
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn display_change_handler(
    mut messages: MessageReader<Event>,
    displays: Query<(&Display, Entity, Has<ActiveDisplayMarker>)>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    if !messages
        .read()
        .any(|event| matches!(event, Event::DisplayChanged))
    {
        return;
    }

    let Ok(active_id) = window_manager.active_display_id() else {
        error!("Unable to get active display id!");
        return;
    };

    for (display, entity, focused) in displays {
        let display_id = display.id();
        if !focused
            && display_id == active_id
            && let Ok(mut cmd) = commands.get_entity(entity)
        {
            debug!("Display id {display_id} is active");
            cmd.try_insert(ActiveDisplayMarker);
        }
    }
    commands.trigger(SendMessageTrigger(Event::SpaceChanged));
}

/// Full reconciliation of the ECS display set against the OS truth.
///
/// Runs after a brief quiet period following wake or a display notification.
/// macOS may report an empty or incomplete display list during reconfiguration;
/// applying that transient list would orphan every workspace. A successful
/// scan refreshes both display ownership and the positions of its strips.
#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
pub(crate) fn reconcile_displays(
    mut messages: MessageReader<Event>,
    workspaces: Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    mut displays: Query<(&mut Display, Entity)>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    time: Res<Time>,
    mut state: Local<DisplayReconcileState>,
    mut commands: Commands,
) {
    let needs_reconcile = messages.read().fold(false, |changed, event| {
        changed
            | matches!(
                event,
                Event::SystemWoke { .. }
                    | Event::DisplayAdded { .. }
                    | Event::DisplayRemoved { .. }
                    | Event::DisplayMoved { .. }
                    | Event::DisplayResized { .. }
                    | Event::DisplayConfigured { .. }
                    | Event::DockDidChangePref { .. }
                    | Event::DockDidRestart { .. }
            )
    });
    let policy_changed = config.is_changed() && config.ignored_displays() != state.ignored;
    if policy_changed {
        state.ignored = config.ignored_displays();
    }
    if needs_reconcile || policy_changed {
        state.pending = Some(Timer::new(DISPLAY_SETTLE_DELAY, TimerMode::Once));
        state.retries_left = DISPLAY_RETRIES;
        state.verify_again = true;
        return;
    }

    let Some(timer) = state.pending.as_mut() else {
        return;
    };
    timer.tick(time.delta());
    if !timer.is_finished() {
        return;
    }
    state.pending = None;

    debug!("Reconciling displays against OS after wake / resize / configure");

    let present_displays = match window_manager.present_displays() {
        Ok(displays) => displays,
        Err(err) => {
            warn!("Unable to enumerate displays; retaining the current topology: {err}");
            if state.retries_left > 0 {
                state.retries_left -= 1;
                state.pending = Some(Timer::new(DISPLAY_RETRY_DELAY, TimerMode::Once));
            }
            return;
        }
    };
    let mut present_displays: HashMap<CGDirectDisplayID, _> = present_displays
        .into_iter()
        .map(|(display, workspaces)| (display.id(), (display, workspaces)))
        .collect();
    if present_displays.is_empty()
        || present_displays
            .values()
            .any(|(_, spaces)| spaces.is_empty())
    {
        if state.retries_left > 0 {
            state.retries_left -= 1;
            warn!("Display list is incomplete; retrying in {DISPLAY_RETRY_DELAY:?}");
            state.pending = Some(Timer::new(DISPLAY_RETRY_DELAY, TimerMode::Once));
            return;
        }
        warn!("Display list is still incomplete after retries; applying the latest scan");
    }

    // Ignoring is a policy release, never a disconnect/orphan migration.
    let ignored_ids: HashSet<_> = present_displays
        .values()
        .filter(|(display, _)| {
            display
                .uuid()
                .is_some_and(|uuid| state.ignored.iter().any(|id| id == uuid))
        })
        .map(|(display, _)| display.id())
        .collect();
    for (display, entity) in &displays {
        if ignored_ids.contains(&display.id()) {
            release_ignored_display(entity, &workspaces, &mut commands);
        }
    }
    present_displays.retain(|id, _| !ignored_ids.contains(id));

    let previous_bounds: HashMap<Entity, IRect> = displays
        .iter()
        .map(|(display, entity)| (entity, display.bounds()))
        .collect();
    let previous_parents: HashMap<Entity, IRect> = workspaces
        .iter()
        .filter_map(|(_, entity, child)| {
            let bounds = previous_bounds.get(&child?.parent())?;
            Some((entity, *bounds))
        })
        .collect();

    let existing_displays: HashMap<CGDirectDisplayID, _> = displays
        .iter()
        .filter(|(display, _)| !ignored_ids.contains(&display.id()))
        .map(|(display, workspaces)| (display.id(), (display, workspaces)))
        .collect();

    let present_ids = present_displays.keys().copied().collect::<HashSet<_>>();
    let existing_ids = existing_displays.keys().copied().collect::<HashSet<_>>();

    let adopting = present_ids.difference(&existing_ids).next().is_some();

    // Displays that vanished while we were away (e.g. unplugged during sleep).
    for display_id in existing_ids.difference(&present_ids) {
        let Some((display, _)) = existing_displays.get(display_id) else {
            error!("Unable to find removed display: {display_id}");
            continue;
        };
        remove_display(display, &workspaces, &displays, &mut commands);
    }

    // Displays that appeared while we were away.
    for display_id in present_ids.difference(&existing_ids) {
        let Some((display, workspace_ids)) = present_displays.remove(display_id) else {
            error!("Unable to find added display: {display_id}");
            continue;
        };
        add_display(display, &workspace_ids, &workspaces, &mut commands);
    }

    // Displays that are still present: refresh their bounds (resolution or
    // menubar may have changed) and re-home any workspaces that drifted.
    for display_id in present_ids.intersection(&existing_ids) {
        let Some((display, workspace_ids)) = present_displays.remove(display_id) else {
            continue;
        };
        move_display(
            display,
            &workspace_ids,
            &mut displays,
            &workspaces,
            &mut commands,
        );
    }

    commands.queue(move |world: &mut World| refresh_display_layout(world, &previous_parents));
    commands.queue(|world: &mut World| {
        let active = world
            .query_filtered::<Entity, bevy::ecs::query::With<ActiveDisplayMarker>>()
            .iter(world)
            .next();
        if active.is_none() {
            let display = world
                .query::<(Entity, &Display)>()
                .iter(world)
                .next()
                .map(|(e, _)| e);
            if let Some(display) = display {
                world.entity_mut(display).insert(ActiveDisplayMarker);
                let strip = world
                    .query::<(Entity, &LayoutStrip, &ChildOf)>()
                    .iter(world)
                    .find(|(_, _, child)| child.parent() == display)
                    .map(|(e, _, _)| e);
                if let Some(strip) = strip {
                    world
                        .entity_mut(strip)
                        .insert((ActiveWorkspaceMarker, crate::ecs::SelectedVirtualMarker));
                }
            }
        }
    });
    if adopting {
        commands.queue(|world: &mut World| {
            let config = world.resource::<Config>().clone();
            let fresh: Vec<_> = world
                .query::<&crate::manager::Application>()
                .iter(world)
                .flat_map(|app| app.window_list(&config))
                .collect();
            world.trigger(crate::ecs::SpawnWindowTrigger(fresh));
        });
    }
    commands.trigger(SendMessageTrigger(Event::DisplayChanged));
    if state.verify_again {
        // A begin-configuration callback can precede the final macOS space
        // assignment even after a quiet period. Verify once more without
        // requiring a second notification from Core Graphics.
        state.verify_again = false;
        state.pending = Some(Timer::new(DISPLAY_VERIFY_DELAY, TimerMode::Once));
    }
}

/// A window belongs to the display with the largest positive overlap. This
/// uses physical frames, so slivers on another display do not change ownership.
pub(crate) fn frame_on_ignored_display(
    frame: IRect,
    config: &Config,
    manager: &WindowManager,
) -> bool {
    let ignored = config.ignored_displays();
    if ignored.is_empty() {
        return false;
    }
    let Ok(displays) = manager.present_displays() else {
        return false;
    };
    frame_display(frame, displays.iter().map(|(display, _)| display)).is_some_and(|display| {
        display
            .uuid()
            .is_some_and(|uuid| ignored.iter().any(|id| id == uuid))
    })
}

pub(super) fn frame_on_display_set(
    frame: IRect,
    displays: &[(Display, Vec<WorkspaceId>)],
    ignored: &[String],
) -> bool {
    frame_display(frame, displays.iter().map(|(d, _)| d)).is_some_and(|d| {
        d.uuid()
            .is_some_and(|uuid| ignored.iter().any(|id| id == uuid))
    })
}

fn frame_display<'a>(
    frame: IRect,
    displays: impl Iterator<Item = &'a Display>,
) -> Option<&'a Display> {
    displays
        .filter_map(|display| {
            let overlap = frame.intersect(display.bounds());
            let area = i64::from(overlap.width().max(0)) * i64::from(overlap.height().max(0));
            (area > 0).then_some((display, area))
        })
        .max_by_key(|(_, area)| *area)
        .map(|(display, _)| display)
}

/// Released handles keep observing AX but have no Window component, so none
/// of the layout, restore or OS writers can move them. Re-admit through the
/// normal admission observer once they settle on a managed display.
#[derive(Component)]
pub(super) struct ReleasedWindow {
    window: crate::manager::Window,
    frame: IRect,
    stable_since: Instant,
    pending: bool,
}

impl ReleasedWindow {
    pub(super) fn id(&self) -> crate::platform::WinID {
        self.window.id()
    }
}

pub(super) fn track_released_window(
    window: crate::manager::Window,
    parent: Entity,
    commands: &mut Commands,
) {
    commands.queue(move |world: &mut World| {
        let exists = world
            .query::<&ReleasedWindow>()
            .iter(world)
            .any(|r| r.window.id() == window.id())
            || world
                .query::<&crate::manager::Window>()
                .iter(world)
                .any(|w| w.id() == window.id());
        if !exists && world.get_entity(parent).is_ok() {
            world.spawn((
                ReleasedWindow {
                    frame: window.frame(),
                    window,
                    stable_since: Instant::now(),
                    pending: false,
                },
                ChildOf(parent),
            ));
        }
    });
}

fn release_ignored_display(
    entity: Entity,
    strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    for (_, strip_entity, child) in strips
        .iter()
        .filter(|(_, _, child)| child.is_some_and(|c| c.parent() == entity))
    {
        let _ = child;
        commands.entity(strip_entity).despawn();
    }
    commands.entity(entity).despawn();
}

/// Drop only ECS ownership. Do not insert `Unmanaged`: its normal observer pops
/// a floating window into view, which would move the windows being released.
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn release_ignored_windows(
    mut events: MessageReader<Event>,
    config: Res<Config>,
    manager: Res<WindowManager>,
    windows: Query<(Entity, &crate::manager::Window, &ChildOf)>,
    animations: Query<(), Or<(With<RepositionMarker>, With<super::ResizeMarker>)>>,
    mut settling: Local<HashMap<crate::platform::WinID, (IRect, Instant)>>,
    mut commands: Commands,
) {
    let now = Instant::now();
    for event in events.read() {
        match event {
            Event::WindowMoved { window_id } | Event::WindowResized { window_id } => {
                if let Some((_, window, _)) = windows.iter().find(|(_, w, _)| w.id() == *window_id)
                {
                    settling.insert(*window_id, (window.frame(), now));
                }
            }
            Event::ConfigRefresh(_) | Event::DisplayConfigured { .. } => {
                settling.extend(windows.iter().map(|(_, w, _)| (w.id(), (w.frame(), now))));
            }
            _ => {}
        }
    }
    if config.is_changed() {
        settling.extend(windows.iter().map(|(_, w, _)| (w.id(), (w.frame(), now))));
    }
    settling.retain(|id, _| windows.iter().any(|(_, w, _)| w.id() == *id));
    if settling.is_empty() {
        return;
    }
    let ignored = config.ignored_displays();
    if ignored.is_empty() {
        settling.clear();
        return;
    }
    let busy = !animations.is_empty() || crate::platform::input::mouse_held();
    // Wait until at least one frame can settle before asking WindowServer.
    let displays = if !busy
        && settling
            .values()
            .any(|(_, since)| now.duration_since(*since) >= Duration::from_millis(500))
    {
        let Ok(displays) = manager.present_displays() else {
            return;
        };
        displays
    } else {
        Vec::new()
    };
    if !busy
        && displays.is_empty()
        && settling
            .values()
            .any(|(_, since)| now.duration_since(*since) >= Duration::from_millis(500))
    {
        // A transient empty display scan is not evidence of settled ownership.
        return;
    }
    for (entity, window, parent) in &windows {
        let Some((frame, since)) = settling.get_mut(&window.id()) else {
            continue;
        };
        if busy || *frame != window.frame() {
            *frame = window.frame();
            *since = now;
            continue;
        }
        if now.duration_since(*since) < Duration::from_millis(500) {
            continue;
        }
        if frame_display(*frame, displays.iter().map(|(d, _)| d)).is_some_and(|d| {
            d.uuid()
                .is_some_and(|uuid| ignored.iter().any(|id| id == uuid))
        }) {
            let parent = parent.parent();
            commands.queue(move |world: &mut World| {
                let Ok(mut source) = world.get_entity_mut(entity) else {
                    return;
                };
                let Some(window) = source.take::<crate::manager::Window>() else {
                    return;
                };
                world.despawn(entity);
                world.spawn((
                    ReleasedWindow {
                        frame: window.frame(),
                        window,
                        stable_since: Instant::now(),
                        pending: false,
                    },
                    ChildOf(parent),
                ));
            });
        }
        settling.remove(&window.id());
    }
}

fn released_windows_pending(
    mut events: MessageReader<Event>,
    released: Query<&ReleasedWindow>,
    config: Res<Config>,
) -> bool {
    let changed = events.read().fold(false, |changed, event| {
        changed
            | match event {
                Event::WindowMoved { window_id }
                | Event::WindowResized { window_id }
                | Event::WindowFocused { window_id }
                | Event::WindowDeminimized { window_id }
                | Event::WindowDestroyed { window_id, .. } => {
                    released.iter().any(|r| r.window.id() == *window_id)
                }
                Event::DisplayChanged | Event::ConfigRefresh(_) => true,
                _ => false,
            }
    });
    changed
        || config.is_changed()
        || released
            .iter()
            .any(|r| r.pending && r.stable_since.elapsed() >= Duration::from_millis(500))
}

fn adopt_released_windows(
    mut events: MessageReader<Event>,
    mut released: Populated<(Entity, &mut ReleasedWindow)>,
    existing: Query<&crate::manager::Window>,
    displays: Query<&Display>,
    manager: Res<WindowManager>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let now = Instant::now();
    for event in events.read() {
        for (entity, mut released) in &mut released {
            match event {
                Event::WindowDestroyed { window_id, .. } if *window_id == released.window.id() => {
                    released.pending = false;
                    commands.entity(entity).despawn();
                }
                Event::WindowMoved { window_id }
                | Event::WindowResized { window_id }
                | Event::WindowFocused { window_id }
                | Event::WindowDeminimized { window_id }
                    if *window_id == released.window.id() =>
                {
                    released.pending = true;
                    released.stable_since = now;
                }
                Event::DisplayChanged | Event::ConfigRefresh(_) => {
                    released.pending = true;
                    released.stable_since = now;
                }
                _ => {}
            }
        }
    }
    let held = crate::platform::input::mouse_held();
    let ignored = config.ignored_displays();
    let present = if !held
        && released.iter().any(|(_, r)| {
            r.pending && now.duration_since(r.stable_since) >= Duration::from_millis(500)
        }) {
        let Ok(displays) = manager.present_displays() else {
            return;
        };
        displays
    } else {
        Vec::new()
    };
    if !held
        && present.is_empty()
        && released.iter().any(|(_, r)| {
            r.pending && now.duration_since(r.stable_since) >= Duration::from_millis(500)
        })
    {
        return;
    }
    for (entity, mut released) in &mut released {
        if existing.iter().any(|w| w.id() == released.window.id()) {
            commands.entity(entity).despawn();
            continue;
        }
        if !released.pending {
            continue;
        }
        if held {
            released.stable_since = now;
            continue;
        }
        let Ok(frame) = released.window.update_frame() else {
            // AX can temporarily fail during app/Space transitions. Keep the
            // handle until an actual destroy notification or its app exits.
            released.stable_since = now;
            continue;
        };
        if frame != released.frame {
            released.frame = frame;
            released.stable_since = now;
            continue;
        }
        if now.duration_since(released.stable_since) < Duration::from_millis(500) {
            continue;
        }
        released.pending = false;
        if frame_display(frame, present.iter().map(|(d, _)| d)).is_some_and(|d| {
            displays.iter().any(|managed| managed.id() == d.id())
                && !d
                    .uuid()
                    .is_some_and(|uuid| ignored.iter().any(|id| id == uuid))
        }) {
            commands.queue(move |world: &mut World| {
                let Ok(mut source) = world.get_entity_mut(entity) else {
                    return;
                };
                if let Some(released) = source.take::<ReleasedWindow>() {
                    world.despawn(entity);
                    world.trigger(super::SpawnWindowTrigger(vec![released.window]));
                }
            });
        }
    }
}

/// Rebase each strip onto its current display and ask the layout and OS writers
/// to replay window frames. This also covers wakeups where macOS moved windows
/// without changing the reported display geometry.
fn refresh_display_layout(world: &mut World, previous_parents: &HashMap<Entity, IRect>) {
    let strips = world
        .query_filtered::<Entity, With<LayoutStrip>>()
        .iter(world)
        .collect::<Vec<_>>();
    let focused = world
        .query_filtered::<Entity, With<FocusedMarker>>()
        .iter(world)
        .next();

    for strip_entity in strips {
        refresh_strip_layout(
            world,
            strip_entity,
            previous_parents.get(&strip_entity).copied(),
            focused,
        );
    }
}

/// Replays a strip that acquired a display after the initial reconciliation.
/// macOS may publish the space ownership later than the display itself.
pub(crate) fn refresh_reparented_strip(world: &mut World, strip_entity: Entity) {
    let focused = world
        .query_filtered::<Entity, With<FocusedMarker>>()
        .iter(world)
        .next();
    refresh_strip_layout(world, strip_entity, None, focused);
}

fn refresh_strip_layout(
    world: &mut World,
    strip_entity: Entity,
    previous_bounds: Option<IRect>,
    focused: Option<Entity>,
) {
    let Some(display_entity) = world.get::<ChildOf>(strip_entity).map(ChildOf::parent) else {
        return;
    };
    let Some(display_bounds) = world.get::<Display>(display_entity).map(Display::bounds) else {
        return;
    };
    if previous_bounds.is_none() {
        // A rescued orphan has no usable display-relative scroll offset.
        world.entity_mut(strip_entity).remove::<ManualStripOffset>();
    }
    let hidden = world.get::<PreviousStripPosition>(strip_entity).is_some();
    if let Some(mut position) = world.get_mut::<Position>(strip_entity) {
        let origin = if hidden {
            display_bounds.max - PARKED_STRIP_SLIVER
        } else if let Some(previous_bounds) = previous_bounds {
            position.0 + display_bounds.min - previous_bounds.min
        } else {
            display_bounds.min
        };
        if position.0 != origin {
            position.0 = origin;
        }
    }
    if let Some(mut previous) = world.get_mut::<PreviousStripPosition>(strip_entity) {
        previous.origin = previous_bounds.map_or(display_bounds.min, |bounds| {
            previous.origin + display_bounds.min - bounds.min
        });
    }
    if let Some(mut target) = world.get_mut::<RepositionMarker>(strip_entity) {
        target.0 = if hidden {
            display_bounds.max - PARKED_STRIP_SLIVER
        } else {
            previous_bounds.map_or(display_bounds.min, |bounds| {
                target.0 + display_bounds.min - bounds.min
            })
        };
    }

    let Some(mut strip) = world.get_mut::<LayoutStrip>(strip_entity) else {
        return;
    };
    let windows = strip.all_windows();
    strip.set_changed();
    if let Some(focused) = focused.filter(|focused| windows.contains(focused)) {
        world
            .entity_mut(focused)
            .insert(EnsureVisibleMarker { snap: true });
    }
    for window in windows {
        if let Some(mut layout) = world.get_mut::<LayoutPosition>(window) {
            layout.set_changed();
        }
        if let Some(mut position) = world.get_mut::<Position>(window) {
            position.set_changed();
        }
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(display_id))]
fn add_display(
    display: Display,
    workspace_ids: &[WorkspaceId],
    existing_strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    let display_id = display.id();
    debug!("Display Added: {display_id}");

    let display_bounds = display.bounds();
    let display_entity = commands.spawn(display).id();
    commands.trigger(ReadDisplayProperties(display_entity));

    reparent_existing_workspaces(
        workspace_ids,
        display_entity,
        &display_bounds,
        existing_strips,
        commands,
    );
}

#[instrument(level = Level::DEBUG, skip_all, fields(display_id))]
fn remove_display(
    display: &Display,
    workspaces: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    displays: &Query<(&mut Display, Entity)>,
    commands: &mut Commands,
) {
    let display_id = display.id();
    debug!("Display Removed: {display_id:?}");
    let Some((display, display_entity)) = displays
        .into_iter()
        .find(|(display, _)| display.id() == display_id)
    else {
        error!("Unable to find removed display!");
        return;
    };

    for (strip, entity, _) in workspaces
        .into_iter()
        .filter(|(_, _, child)| child.is_some_and(|child| child.parent() == display_entity))
    {
        let display_id = display.id();
        debug!(
            "orphaning strip {} after removal of display {display_id}.",
            strip.id(),
        );
        let timeout = Timeout::new(
            Duration::from_secs(ORPHANED_SPACES_TIMEOUT_SEC),
            Some(format!(
                "Orphaned strip {} ({strip}) could not be re-inserted after {ORPHANED_SPACES_TIMEOUT_SEC}s.",
                strip.id()
            )),
            commands,
        );
        if let Ok(mut commands) = commands.get_entity(entity) {
            commands.try_insert(timeout);
        }
        if let Ok(mut commands) = commands.get_entity(display_entity) {
            commands.detach_child(entity);
        }
    }

    if let Ok(mut commands) = commands.get_entity(display_entity) {
        commands.try_despawn();
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(display_id))]
fn move_display(
    moved_display: Display,
    workspace_ids: &[WorkspaceId],
    displays: &mut Query<(&mut Display, Entity)>,
    existing_strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    let display_id = moved_display.id();
    debug!("Display Moved: {display_id:?}");
    let Some((mut display, display_entity)) = displays
        .iter_mut()
        .find(|(display, _)| display.id() == display_id)
    else {
        error!("Unable to find moved display!");
        return;
    };
    *display = moved_display;
    commands.trigger(ReadDisplayProperties(display_entity));

    reparent_existing_workspaces(
        workspace_ids,
        display_entity,
        &display.bounds(),
        existing_strips,
        commands,
    );
}

fn reparent_existing_workspaces(
    workspace_ids: &[WorkspaceId],
    display_entity: Entity,
    display_bounds: &IRect,
    existing_strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    // Verifies that a moved display has all the workspaces which it owns.
    for &id in workspace_ids {
        let mut found = false;
        for (strip, entity, child) in existing_strips {
            if strip.id() == id {
                found = true;
                if child.is_none_or(|child| child.parent() != display_entity) {
                    // Re-parent this workspace
                    if let Ok(mut cmd) = commands.get_entity(entity) {
                        debug!("reparenting workspace {id} to display {display_entity}");
                        cmd.try_remove::<Timeout>()
                            .try_remove::<ChildOf>()
                            .try_insert(ChildOf(display_entity));
                    }
                }
            }
        }

        if !found {
            // New workspace.
            let origin = display_bounds.min;
            debug!("new workspace {id} on display {display_entity}");
            commands.spawn_layout_strip(LayoutStrip::new(id, 0), origin, display_entity, false);
        }
    }
}

/// Tracks whether floating windows on a workspace sit above or behind tiled
/// ones in the OS z-order. Default is `Front` (floats above tiles).
#[derive(Clone, Component, Copy)]
pub struct FloatingLayer {
    pub workspace_id: WorkspaceId,
    pub front: bool,
}

impl FloatingLayer {
    pub fn new(workspace_id: WorkspaceId) -> Self {
        Self {
            workspace_id,
            front: false,
        }
    }

    pub fn flip(&mut self) {
        self.front = !self.front;
    }
}

fn read_display_properties_trigger(
    trigger: On<ReadDisplayProperties>,
    mut displays: Query<(&mut Display, Entity)>,
    platform: Option<NonSend<Pin<Box<PlatformCallbacks>>>>,
    config: Option<Res<Config>>,
    mut commands: Commands,
) {
    let Ok((mut display, entity)) = displays.get_mut(trigger.event().0) else {
        return;
    };
    let display_id = display.id();

    // NSScreen::screen needs to run in the main thread, thus we run it in a NonSend trigger.
    let Some(screens) = platform.map(|platform| NSScreen::screens(platform.main_thread_marker))
    else {
        return;
    };

    let notch = read_screen_property(&screens, display_id, |screen| {
        let insets = screen.safeAreaInsets();
        debug!("notch on display {display_id}: {insets:?}");
        round_px(insets.top)
    });
    if let Some(height) = notch {
        display.set_notch_height(height);
    }

    let dock = read_screen_property(&screens, display_id, |screen| {
        let visible_frame = irect_from(screen.visibleFrame());
        display.locate_dock(&visible_frame)
    });
    if let Some(dock) = dock {
        debug!("dock on display {display_id}: {:?}", dock);
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_insert(dock);
        }
    }

    if let Some(config) = config {
        let height = config.menubar_height();
        display.set_menubar_height_override(height);
    }
}
