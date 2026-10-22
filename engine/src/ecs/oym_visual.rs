//! Strip HUD, pin lines and custom tab bars. All `AppKit` work stays in minimap.rs.
use super::layout::{Column, LayoutStrip, StackItem};
use super::oym_layout::{Edge, EdgePin};
use super::{
    ActiveWorkspaceMarker, Bounds, DockPosition, FocusedMarker, MissionControlActive, Position,
    RepositionMarker, ResizeMarker, Scrolling, SelectedVirtualMarker, SpawnCommandsExt,
};
use crate::commands::Command;
use crate::config::Config;
use crate::events::Event as WMEvent;
use crate::manager::{Display, Window};
use crate::minimap::{
    self, Content, Geometry, HitRegion, MapModel, PointerPhase, Tile, VisualPanels, rect,
};
use bevy::prelude::*;
use std::sync::{Arc, atomic::Ordering};
use std::time::{Duration, Instant};

#[derive(Event, Clone, Copy, Debug)]
pub struct StripIndicatorRequest;

#[derive(Default, Resource)]
pub(super) struct Visibility {
    last_activity: Option<Instant>,
    dirty: bool,
    drag: Option<MapDrag>,
    targets: Vec<Target>,
    map_frame: Option<objc2_core_foundation::CGRect>,
    geometry: Option<Geometry>,
    interactive: bool,
    active_tabs: std::collections::HashMap<Entity, Entity>,
}
impl Visibility {
    pub(super) fn fading(&self) -> bool {
        self.last_activity
            .is_some_and(|last| last.elapsed() < Duration::from_millis(1100))
    }
}
struct MapDrag {
    strip: Entity,
    columns: Arc<Vec<Column>>,
    shape: Arc<DragShape>,
    source: usize,
    start: objc2_core_foundation::CGPoint,
    slot: usize,
    moved: bool,
    began: Instant,
}
#[derive(Clone)]
enum Target {
    Column {
        strip: Entity,
        index: usize,
        columns: Arc<Vec<Column>>,
        shape: Arc<DragShape>,
    },
    Member {
        strip: Entity,
        entity: Entity,
        columns: Arc<Vec<Column>>,
    },
}

pub struct OpenYourMacVisualPlugin;
impl Plugin for OpenYourMacVisualPlugin {
    fn build(&self, app: &mut App) {
        app.add_plugins(super::floating::FloatingPlugin)
            .init_resource::<Visibility>()
            .add_systems(
                PreUpdate,
                visual_commands
                    .after(super::systems::pump_events)
                    .run_if(bevy::ecs::schedule::common_conditions::on_message::<WMEvent>),
            )
            .add_systems(
                Update,
                interact_visuals
                    .before(super::layout::position_layout_windows)
                    .run_if(minimap::has_input),
            )
            .add_systems(
                PostUpdate,
                minimap::refresh_occlusion
                    .run_if(bevy::time::common_conditions::on_timer(
                        Duration::from_millis(100),
                    ))
                    .run_if(minimap::has_hits)
                    .after(update_visuals),
            )
            .add_observer(show_strip)
            .add_systems(
                PostUpdate,
                retire_decorations
                    .after(super::systems::update_overlays)
                    .run_if(decorations_changed),
            )
            .add_systems(
                PostUpdate,
                update_visuals
                    .after(super::systems::animate_entities)
                    .after(super::systems::animate_resize_entities)
                    .run_if(visuals_needed),
            );
    }
}
type VisualChangeFilter = Or<(
    Changed<Position>,
    Changed<Bounds>,
    Changed<LayoutStrip>,
    Changed<Display>,
    Changed<DockPosition>,
    Changed<EdgePin>,
    Changed<ChildOf>,
    Added<FocusedMarker>,
    Added<ActiveWorkspaceMarker>,
    Added<SelectedVirtualMarker>,
)>;
type MotionFilter = Or<(With<RepositionMarker>, With<ResizeMarker>, With<Scrolling>)>;
type DecorationChangeFilter = Or<(
    Added<FocusedMarker>,
    Changed<LayoutStrip>,
    Added<ActiveWorkspaceMarker>,
)>;

/// Cheap change filters gate expensive model extraction and AX title reads.
#[derive(bevy::ecs::system::SystemParam)]
struct VisualChanges<'w, 's> {
    changed: Query<'w, 's, (), VisualChangeFilter>,
    windows: RemovedComponents<'w, 's, Window>,
    strips: RemovedComponents<'w, 's, LayoutStrip>,
    displays: RemovedComponents<'w, 's, Display>,
    focus: RemovedComponents<'w, 's, FocusedMarker>,
    pins: RemovedComponents<'w, 's, EdgePin>,
    active: RemovedComponents<'w, 's, ActiveWorkspaceMarker>,
    selected: RemovedComponents<'w, 's, SelectedVirtualMarker>,
    moving: RemovedComponents<'w, 's, RepositionMarker>,
    resizing: RemovedComponents<'w, 's, ResizeMarker>,
    scrolling: RemovedComponents<'w, 's, Scrolling>,
}
impl VisualChanges<'_, '_> {
    fn changed(&mut self) -> bool {
        let removed = self.windows.read().count()
            + self.strips.read().count()
            + self.displays.read().count()
            + self.focus.read().count()
            + self.pins.read().count()
            + self.active.read().count()
            + self.selected.read().count()
            + self.moving.read().count()
            + self.resizing.read().count()
            + self.scrolling.read().count();
        removed > 0 || !self.changed.is_empty()
    }
}
fn visuals_needed(
    mut invalidation: VisualChanges,
    motion: Query<(), MotionFilter>,
    config: Res<Config>,
    mission: Res<MissionControlActive>,
    visibility: Res<Visibility>,
) -> bool {
    let dirty = invalidation.changed() || config.is_changed() || mission.is_changed();
    let moving = !motion.is_empty();
    dirty
        || visibility.dirty
        || visibility.fading()
        || visibility.interactive
        || moving
        || visibility.drag.is_some()
        || minimap::HELD.load(Ordering::Relaxed)
}
fn decorations_changed(
    changed: Query<(), DecorationChangeFilter>,
    mut focus: RemovedComponents<FocusedMarker>,
    mut active: RemovedComponents<ActiveWorkspaceMarker>,
    mut strips: RemovedComponents<LayoutStrip>,
    config: Res<Config>,
    mission: Res<MissionControlActive>,
) -> bool {
    let removed = focus.read().count() + active.read().count() + strips.read().count();
    removed > 0 || !changed.is_empty() || config.is_changed() || mission.is_changed()
}
fn show_strip(_: On<StripIndicatorRequest>, mut visibility: ResMut<Visibility>) {
    visibility.last_activity = Some(Instant::now());
    visibility.dirty = true;
}
fn visual_commands(
    mut events: MessageReader<WMEvent>,
    mut commands: Commands,
    config: Res<Config>,
    mut visibility: ResMut<Visibility>,
) {
    for event in events.read() {
        match event {
            WMEvent::Command {
                command: Command::ShowStrip,
            } => commands.trigger(StripIndicatorRequest),
            WMEvent::Command {
                command: Command::PauseBindings(paused),
            } => {
                crate::runtime::pause_bindings(*paused);
                if *paused {
                    minimap::cancel_input();
                }
            }
            WMEvent::SystemWoke { .. }
            | WMEvent::SpaceChanged
            | WMEvent::DisplayChanged
            | WMEvent::DisplayRemoved { .. }
            | WMEvent::MissionControlShowAllWindows
            | WMEvent::MissionControlShowFrontWindows
            | WMEvent::MissionControlShowDesktop => {
                visibility.drag = None;
                visibility.last_activity = None;
                minimap::cancel_input();
                visibility.dirty = true;
            }
            WMEvent::WindowTitleChanged { .. }
            | WMEvent::DisplayAdded { .. }
            | WMEvent::DisplayMoved { .. }
            | WMEvent::DisplayResized { .. }
            | WMEvent::DisplayConfigured { .. }
            | WMEvent::DockDidChangePref { .. }
            | WMEvent::DockDidRestart { .. }
            | WMEvent::MenuBarHiddenChanged { .. }
            | WMEvent::ThemeChanged
            | WMEvent::WindowDestroyed { .. }
            | WMEvent::MissionControlExit => visibility.dirty = true,
            // Only navigation the user does starts the minimap: window
            // commands (keys, CLI, menu), modifier-scroll steps, and swipes
            // with the configured finger count. Focus changes and resizes
            // happen without input (clicks, apps resizing themselves, our own
            // moves), so they only redraw an indicator that is already up.
            WMEvent::Command {
                command: Command::Window(_),
            }
            | WMEvent::Scroll { .. } => {
                if config.minimap() {
                    visibility.last_activity = Some(Instant::now());
                }
                visibility.dirty = true;
            }
            WMEvent::Swipe { fingers, .. } => {
                if config.minimap() && config.swipe_gesture_fingers() == Some(*fingers) {
                    visibility.last_activity = Some(Instant::now());
                }
                visibility.dirty = true;
            }
            WMEvent::WindowFocused { .. } | WMEvent::WindowResized { .. } => {
                visibility.dirty = true;
            }
            _ => {}
        }
    }
}
/// Custom display tabs represent stack rows, not the app's hidden native tabs.
pub(super) fn members(column: &Column) -> Vec<Entity> {
    match column {
        Column::Stack(items) => items.iter().filter_map(StackItem::top).collect(),
        _ => column.top().into_iter().collect(),
    }
}

pub(super) type DragShape = Vec<(Entity, crate::manager::Size, bool, Option<Edge>)>;

/// Include every member, its size, custom tab mode and pin assignment. A
/// changed/closed/resized column invalidates the entire drop transaction.
pub(super) fn drag_shape(
    strip: &LayoutStrip,
    pins: &Query<&EdgePin>,
    frame: impl Fn(Entity) -> Option<bevy::math::IRect>,
) -> DragShape {
    strip
        .columns()
        .flat_map(Column::window_iter)
        .filter_map(|entity| {
            frame(entity).map(|frame| {
                (
                    entity,
                    frame.size(),
                    strip.is_tabbed_display(entity),
                    pins.get(entity).ok().map(|p| p.0),
                )
            })
        })
        .collect()
}

pub(super) fn snapshot(strip: &LayoutStrip) -> Vec<Column> {
    strip.columns().cloned().collect()
}

/// Pinned columns are barriers. Neither the source nor any crossed column may
/// be pinned. Callers also check the original full membership/order snapshot.
pub(super) fn reorder(
    strip: &mut LayoutStrip,
    from: usize,
    slot: usize,
    pins: &Query<&EdgePin>,
) -> bool {
    if from >= strip.len() || slot > strip.len() {
        return false;
    }
    let to = if slot > from { slot - 1 } else { slot };
    let blocked = strip.columns().enumerate().any(|(i, c)| {
        i >= from.min(to) && i <= from.max(to) && c.window_iter().any(|e| pins.get(e).is_ok())
    });
    !blocked && strip.move_column(from, to)
}

type VisualWindows<'w, 's> = Query<
    'w,
    's,
    (
        &'static Window,
        Ref<'static, Position>,
        Ref<'static, Bounds>,
        Has<FocusedMarker>,
        Has<RepositionMarker>,
        Has<ResizeMarker>,
    ),
>;

/// Input transactions run before layout. Panel rendering remains in `PostUpdate`.
#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn interact_visuals(
    mut visibility: ResMut<Visibility>,
    mut strips: Query<(Entity, &mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    windows: VisualWindows,
    pins: Query<&EdgePin>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let input = minimap::take_input();
    if input.is_empty() {
        return;
    }
    let now = Instant::now();
    for event in input {
        visibility.dirty = true;
        if matches!(event.phase, PointerPhase::Cancel) {
            visibility.drag = None;
            visibility.interactive = false;
            continue;
        }
        visibility.last_activity = Some(now);
        let owner = match event.phase {
            PointerPhase::Down => match visibility.targets.get(event.target) {
                Some(Target::Column { strip, .. } | Target::Member { strip, .. }) => Some(*strip),
                _ => None,
            },
            _ => visibility.drag.as_ref().map(|drag| drag.strip),
        };
        let Some(owner) = owner else {
            continue;
        };
        let Ok((strip_entity, mut strip, active)) = strips.get_mut(owner) else {
            visibility.drag = None;
            continue;
        };
        match event.phase {
            PointerPhase::Down => match visibility.targets.get(event.target).cloned() {
                Some(Target::Member {
                    entity, columns, ..
                }) => {
                    if config.tab_bar_clicks()
                        && columns.as_ref() == &snapshot(&strip)
                        && strip.is_tabbed_display(entity)
                        && strip.contains(entity)
                        && windows.get(entity).is_ok()
                    {
                        commands.focus_entity(entity, true);
                    }
                }
                Some(Target::Column {
                    strip: owner,
                    index,
                    columns,
                    shape,
                }) if active
                    && owner == strip_entity
                    && columns.as_ref() == &snapshot(&strip)
                    && shape.as_ref()
                        == &drag_shape(&strip, &pins, |e| {
                            windows.get(e).ok().map(|(w, _, _, _, _, _)| w.frame())
                        }) =>
                {
                    visibility.drag = Some(MapDrag {
                        strip: owner,
                        columns,
                        shape,
                        source: index,
                        start: event.point,
                        slot: index,
                        moved: false,
                        began: now,
                    });
                }
                _ => {}
            },
            PointerPhase::Drag => {
                let geometry = visibility.geometry;
                let frame = visibility.map_frame;
                if let Some(drag) = visibility.drag.as_mut() {
                    drag.began = now;
                    drag.moved |= (event.point.x - drag.start.x).abs() > 5.0
                        || (event.point.y - drag.start.y).abs() > 5.0;
                    if let (Some(geometry), Some(frame)) = (geometry, frame) {
                        let x = event.point.x - frame.origin.x;
                        drag.slot = (0..strip.len())
                            .find(|&i| x < geometry.tile(i).origin.x + 31.0 * geometry.scale)
                            .unwrap_or(strip.len());
                    }
                }
            }
            PointerPhase::Up => {
                if let Some(drag) = visibility.drag.take()
                    && now.duration_since(drag.began) <= Duration::from_secs(5)
                    && active
                    && drag.strip == strip_entity
                    && snapshot(&strip) == *drag.columns
                    && drag.shape.as_ref()
                        == &drag_shape(&strip, &pins, |e| {
                            windows.get(e).ok().map(|(w, _, _, _, _, _)| w.frame())
                        })
                {
                    if drag.moved && config.drag_reorder() {
                        let inside = visibility.map_frame.is_some_and(|r| {
                            event.point.x >= r.origin.x
                                && event.point.x <= r.origin.x + r.size.width
                                && event.point.y >= r.origin.y
                                && event.point.y <= r.origin.y + r.size.height
                        });
                        if inside
                            && reorder(&mut strip, drag.source, drag.slot, &pins)
                            && let Some(entity) = strip
                                .get(if drag.slot > drag.source {
                                    drag.slot - 1
                                } else {
                                    drag.slot
                                })
                                .ok()
                                .and_then(|c| c.top())
                        {
                            commands.reshuffle_around(entity);
                        }
                    } else if let Some(entity) = strip.get(drag.source).ok().and_then(|c| c.top()) {
                        commands.focus_entity(entity, true);
                    }
                }
            }
            PointerPhase::Cancel => {}
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    clippy::cast_precision_loss,
    clippy::type_complexity
)]
fn update_visuals(
    mut panels: Option<NonSendMut<VisualPanels>>,
    mut visibility: ResMut<Visibility>,
    strips: Query<
        (
            Entity,
            Ref<LayoutStrip>,
            &ChildOf,
            Ref<Position>,
            Option<&Scrolling>,
        ),
        With<ActiveWorkspaceMarker>,
    >,
    selected: Query<(Entity, Ref<LayoutStrip>, &ChildOf), With<SelectedVirtualMarker>>,
    manager: Res<crate::manager::WindowManager>,
    displays: Query<(&Display, Option<&DockPosition>)>,
    windows: VisualWindows,
    pins: Query<&EdgePin>,
    mut invalidation: VisualChanges,
    motion: Query<(), MotionFilter>,
    mission: Res<MissionControlActive>,
    config: Res<Config>,
) {
    let Some(ref mut panels) = panels else {
        return;
    };
    let now = Instant::now();
    let Ok((strip_entity, strip, parent, _strip_position, scrolling)) = strips.single() else {
        panels.hide_from(0);
        minimap::set_hits(Vec::new());
        visibility.drag = None;
        visibility.last_activity = None;
        visibility.interactive = false;
        visibility.targets.clear();
        visibility.dirty = false;
        return;
    };
    let Ok((display, dock)) = displays.get(parent.parent()) else {
        panels.hide_from(0);
        minimap::set_hits(Vec::new());
        visibility.drag = None;
        visibility.last_activity = None;
        visibility.interactive = false;
        visibility.targets.clear();
        visibility.dirty = false;
        return;
    };
    if mission.0 {
        panels.hide_from(0);
        minimap::set_hits(Vec::new());
        visibility.drag = None;
        visibility.last_activity = None;
        visibility.interactive = false;
        visibility.targets.clear();
        visibility.dirty = false;
        return;
    }
    if visibility.drag.as_ref().is_some_and(|d| {
        d.strip != strip_entity
            || (now.duration_since(d.began) > Duration::from_secs(5)
                && !crate::platform::input::mouse_held())
    }) {
        visibility.drag = None;
        minimap::cancel_input();
    }
    let fullscreen = strip.is_fullscreen();
    if fullscreen {
        visibility.drag = None;
        visibility.last_activity = None;
        visibility.interactive = false;
    }
    let held = !fullscreen
        && config.strip_indicator_interactive()
        && minimap::POINTER_AVAILABLE.load(Ordering::Relaxed)
        && minimap::HELD.load(Ordering::Relaxed)
        && !crate::runtime::bindings_paused();
    let changed = invalidation.changed() || config.is_changed() || mission.is_changed();
    let moving = !motion.is_empty() || scrolling.is_some();
    // Motion (animations, swipe settling) keeps a visible indicator up while
    // things move, but never opens it: windows also move without any input.
    let visible = visibility
        .last_activity
        .is_some_and(|t| now.duration_since(t) < Duration::from_millis(1060));
    if moving && config.minimap() && visible {
        visibility.last_activity = Some(now);
    }
    if visibility.interactive && !held {
        visibility.last_activity = Some(now);
    }
    let elapsed = visibility.last_activity.map(|t| now.duration_since(t));
    let showing = held
        || visibility.drag.is_some()
        || elapsed.is_some_and(|d| d < Duration::from_millis(1060));
    // Opacity-only frames do not rebuild models, labels, hit maps or views.
    if !changed && !visibility.dirty && held == visibility.interactive {
        if let Some(panel) = panels.panels.first_mut() {
            if showing {
                panel.opacity(indicator_opacity(
                    held || visibility.drag.is_some(),
                    elapsed,
                ));
            } else {
                panel.hide();
                visibility.last_activity = None;
            }
        }
        return;
    }
    visibility.interactive = held;
    visibility.dirty = false;
    let usable = display.actual_display_bounds(dock, &config);
    let screen_height =
        objc2_core_graphics::CGDisplayBounds(objc2_core_graphics::CGMainDisplayID())
            .size
            .height;
    let focused = windows
        .iter()
        .find_map(|(w, _, _, f, _, _)| f.then_some(w.id()));
    let columns = Arc::new(snapshot(&strip));
    let shape = Arc::new(drag_shape(&strip, &pins, |e| {
        windows.get(e).ok().map(|(w, _, _, _, _, _)| w.frame())
    }));
    let focus = columns
        .iter()
        .position(|c| {
            c.window_iter().any(|e| {
                windows
                    .get(e)
                    .is_ok_and(|(w, _, _, _, _, _)| Some(w.id()) == focused)
            })
        })
        .unwrap_or_default();
    let tiles = columns
        .iter()
        .map(|column| {
            let members = members(column);
            Tile {
                selected: members.iter().position(|&e| {
                    windows
                        .get(e)
                        .is_ok_and(|(w, _, _, _, _, _)| Some(w.id()) == focused)
                }),
                members: members.len(),
                tabbed: column.top().is_some_and(|e| strip.is_tabbed_display(e))
                    || matches!(column, Column::Tabs(_)),
                pinned: config.pin_indicator() && column.window_iter().any(|e| pins.get(e).is_ok()),
                apps: members
                    .iter()
                    .map(|&e| {
                        windows
                            .get(e)
                            .ok()
                            .and_then(|(w, _, _, _, _, _)| w.pid().ok())
                    })
                    .collect(),
            }
        })
        .collect();
    let model = MapModel {
        tiles,
        focus,
        pin_color: config.pinned_color(),
        insertion: visibility.drag.as_ref().filter(|d| d.moved).map(|d| d.slot),
    };
    let geometry = Geometry::new(&model, f64::from(display.bounds().width()));
    let frame = rect(
        f64::from(usable.min.x) + (f64::from(usable.width()) - geometry.width) / 2.0,
        f64::from(usable.max.y) - 28.0 - geometry.height,
        geometry.width,
        geometry.height,
    );
    let mut hits = Vec::new();
    visibility.targets.clear();
    let content = Content::Map(model, geometry);
    let panel = panels.panel(0, &content);
    if showing && !columns.is_empty() {
        let alpha = indicator_opacity(held || visibility.drag.is_some(), elapsed);
        panel.update(frame, content, alpha, held, screen_height);
        if held {
            for index in 0..columns.len() {
                let tile = geometry.tile(index);
                let left = tile.origin.x.max(0.0);
                let right = (tile.origin.x + tile.size.width).min(frame.size.width);
                if right <= left {
                    continue;
                }
                let target = visibility.targets.len();
                visibility.targets.push(Target::Column {
                    strip: strip_entity,
                    index,
                    columns: Arc::clone(&columns),
                    shape: Arc::clone(&shape),
                });
                hits.push(HitRegion {
                    frame: rect(
                        frame.origin.x + left,
                        frame.origin.y + tile.origin.y,
                        right - left,
                        tile.size.height,
                    ),
                    panel: panel.id(),
                    owner: 0,
                    target,
                });
            }
        }
    } else {
        panel.hide();
        visibility.last_activity = None;
    }
    visibility.geometry = Some(geometry);
    visibility.map_frame = Some(frame);
    let mut panel_index = 1;
    let mut column_keys = Vec::new();
    let style = PanelStyle {
        pin: config.pin_indicator(),
        pin_color: config.pinned_color(),
        titles: config.tab_bar_titles(),
        clickable: config.tab_bar_clicks() && minimap::POINTER_AVAILABLE.load(Ordering::Relaxed),
    };
    let ignored = config.ignored_displays();
    for (owner, visible_strip, child) in &selected {
        let Ok((host, dock)) = displays.get(child.parent()) else {
            continue;
        };
        if visible_strip.is_fullscreen()
            || !manager
                .active_display_space(host.id())
                .is_ok_and(|space| space == visible_strip.id())
        {
            continue;
        }
        if host
            .uuid()
            .is_some_and(|uuid| ignored.iter().any(|id| id == uuid))
        {
            continue;
        }
        let visible_columns = Arc::new(snapshot(&visible_strip));
        column_keys.extend(visible_columns.iter().filter_map(Column::top));
        sync_column_panels(
            panels,
            &mut visibility,
            &visible_strip,
            owner,
            &visible_columns,
            focused,
            &windows,
            &pins,
            &style,
            host.actual_display_bounds(dock, &config),
            screen_height,
            &mut hits,
            &mut panel_index,
        );
    }
    visibility
        .active_tabs
        .retain(|key, _| column_keys.contains(key));
    panels.hide_from(panel_index);
    minimap::set_hits(hits);
}

fn indicator_opacity(keep: bool, elapsed: Option<Duration>) -> f64 {
    if keep {
        1.0
    } else {
        elapsed.map_or(0.0, |d| {
            (1.0 - (d.as_secs_f64() - 0.9) / 0.16).clamp(0.0, 1.0)
        })
    }
}

/// Clear decorations on transitions that have no replacement focused window.
fn retire_decorations(
    focused: Query<(), With<FocusedMarker>>,
    strips: Query<&LayoutStrip, With<ActiveWorkspaceMarker>>,
    mission: Res<MissionControlActive>,
    config: Res<Config>,
    overlays: Option<NonSendMut<crate::overlay::OverlayManager>>,
) {
    let Some(mut overlays) = overlays else {
        return;
    };
    if !config.border_active_window() && config.dim_inactive_opacity() == 0.0 {
        overlays.remove_all();
    } else if focused.is_empty()
        || mission.0
        || strips.iter().next().is_none_or(LayoutStrip::is_fullscreen)
    {
        overlays.hide_all();
    }
}

struct PanelStyle {
    pin: bool,
    pin_color: (f64, f64, f64, f64),
    titles: bool,
    clickable: bool,
}

/// Synchronize only auxiliary column panels. The HUD has its own lifetime.
#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    clippy::cast_precision_loss
)]
fn sync_column_panels(
    panels: &mut VisualPanels,
    visibility: &mut Visibility,
    strip: &LayoutStrip,
    strip_entity: Entity,
    columns: &Arc<Vec<Column>>,
    focused: Option<crate::platform::WinID>,
    windows: &VisualWindows,
    pins: &Query<&EdgePin>,
    style: &PanelStyle,
    usable: bevy::math::IRect,
    screen_height: f64,
    hits: &mut Vec<HitRegion>,
    panel_index: &mut usize,
) {
    for column in columns.iter() {
        let member_list = members(column);
        let selected = member_list.iter().position(|&e| {
            windows
                .get(e)
                .is_ok_and(|(w, _, _, _, _, _)| Some(w.id()) == focused)
        });
        let key = column.top().unwrap_or(strip_entity);
        if let Some(index) = selected {
            visibility.active_tabs.insert(key, member_list[index]);
        }
        let active = selected
            .or_else(|| {
                strip
                    .active_member(key)
                    .and_then(|active| member_list.iter().position(|e| *e == active))
            })
            .or_else(|| {
                visibility
                    .active_tabs
                    .get(&key)
                    .and_then(|previous| member_list.iter().position(|e| e == previous))
            })
            .unwrap_or_default();
        let representative = member_list.get(active).copied();
        let Some((window, _, _, _, _, _)) = representative.and_then(|e| windows.get(e).ok()) else {
            continue;
        };
        let actual = window.frame();
        // Skip offscreen/parked columns. Clip all auxiliary visuals to the viewport.
        let left = (actual.min.x + window.horizontal_padding()).max(usable.min.x);
        let right = (actual.max.x - window.horizontal_padding()).min(usable.max.x);
        let top = (actual.min.y + window.vertical_padding()).max(usable.min.y);
        let bottom = (actual.max.y - window.vertical_padding()).min(usable.max.y);
        if left >= right || top >= bottom {
            continue;
        }
        if style.pin
            && let Some(pin) = column.window_iter().find_map(|e| pins.get(e).ok())
        {
            let pin_top = member_list
                .iter()
                .filter_map(|&e| windows.get(e).ok())
                .map(|(w, _, _, _, _, _)| w.frame().min.y + w.vertical_padding())
                .min()
                .unwrap_or(top)
                .max(usable.min.y);
            let pin_bottom = member_list
                .iter()
                .filter_map(|&e| windows.get(e).ok())
                .map(|(w, _, _, _, _, _)| w.frame().max.y - w.vertical_padding())
                .max()
                .unwrap_or(bottom)
                .min(usable.max.y);
            let x = if pin.0 == Edge::Left { right } else { left - 3 };
            let content = Content::Pin(style.pin_color);
            panels.panel(*panel_index, &content).update(
                rect(
                    f64::from(x),
                    f64::from(pin_top),
                    3.0,
                    f64::from(pin_bottom - pin_top),
                ),
                content,
                1.0,
                false,
                screen_height,
            );
            *panel_index += 1;
        }
        if representative.is_some_and(|e| strip.is_tabbed_display(e)) && member_list.len() > 1 {
            let labels = member_list
                .iter()
                .enumerate()
                .map(|(i, &e)| {
                    if style.titles {
                        windows
                            .get(e)
                            .ok()
                            .and_then(|(w, _, _, _, _, _)| w.title().ok())
                            .unwrap_or_else(|| format!("{}", i + 1))
                    } else {
                        format!("{}", i + 1)
                    }
                })
                .collect();
            let content = Content::Tabs {
                titles: labels,
                active,
            };
            let bar = rect(
                f64::from(left),
                f64::from(top),
                f64::from(right - left),
                24.0,
            );
            let panel = panels.panel(*panel_index, &content);
            let clickable = style.clickable;
            panel.update(bar, content, 1.0, clickable, screen_height);
            panel.follow_window(window.id());
            if clickable {
                let width = bar.size.width / member_list.len() as f64;
                for (i, &entity) in member_list.iter().enumerate() {
                    let target = visibility.targets.len();
                    visibility.targets.push(Target::Member {
                        strip: strip_entity,
                        entity,
                        columns: Arc::clone(columns),
                    });
                    hits.push(HitRegion {
                        frame: rect(bar.origin.x + i as f64 * width, bar.origin.y, width, 24.0),
                        panel: panel.id(),
                        owner: u32::try_from(window.id()).unwrap_or_default(),
                        target,
                    });
                }
            }
            *panel_index += 1;
        }
    }
}
