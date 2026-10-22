//! Bounded post-open retries and event-driven float classification.
use super::layout::LayoutStrip;
use super::{Initializing, PreviousManagedStrip, RepositionMarker, ResizeMarker, Unmanaged};
use crate::config::Config;
use crate::events::Event as WMEvent;
use crate::manager::{Application, FloatReason, Window, WindowManager};
use bevy::prelude::*;
use std::time::{Duration, Instant};

#[derive(Component)]
pub(super) struct FloatRecheck {
    next: Instant,
    remaining: u8,
}
impl FloatRecheck {
    pub fn new() -> Self {
        Self {
            next: Instant::now() + Duration::from_secs(3),
            remaining: 2,
        }
    }
}
/// A saved tiled match takes precedence at admission, until the next reload.
#[derive(Component)]
pub(super) struct RestoredFloatPolicy;

pub(super) struct FloatingPlugin;
impl Plugin for FloatingPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            recheck_floats
                .after(super::triggers::apply_window_positions)
                .after(super::systems::window_resized_update_frame)
                .run_if(floats_needed),
        );
    }
}

fn floats_needed(
    mut events: MessageReader<WMEvent>,
    retries: Query<&FloatRecheck>,
    config: Res<Config>,
) -> bool {
    let event = events.read().any(|event| {
        matches!(
            event,
            WMEvent::WindowFocused { .. }
                | WMEvent::WindowResized { .. }
                | WMEvent::WindowTitleChanged { .. }
        )
    });
    config.is_changed() || event || retries.iter().any(|retry| Instant::now() >= retry.next)
}

#[allow(
    clippy::too_many_arguments,
    clippy::type_complexity,
    clippy::too_many_lines
)]
fn recheck_floats(
    mut events: MessageReader<WMEvent>,
    mut windows: Query<(
        Entity,
        &Window,
        &ChildOf,
        &mut FloatReason,
        Option<&mut FloatRecheck>,
        Option<&Unmanaged>,
        Has<RepositionMarker>,
        Has<ResizeMarker>,
        Has<RestoredFloatPolicy>,
    )>,
    apps: Query<&Application>,
    strips: Query<(Entity, &LayoutStrip, &ChildOf)>,
    manager: Res<WindowManager>,
    config: Res<Config>,
    initializing: Option<Res<Initializing>>,
    mut commands: Commands,
) {
    if initializing.is_some() {
        return;
    }
    let changed: Vec<_> = events
        .read()
        .filter_map(|event| match event {
            WMEvent::WindowFocused { window_id } | WMEvent::WindowResized { window_id } => {
                Some((*window_id, false))
            }
            WMEvent::WindowTitleChanged { window_id } => Some((*window_id, true)),
            _ => None,
        })
        .collect();
    let now = Instant::now();
    let ignored = config.ignored_displays();
    let present = if ignored.is_empty() {
        Vec::new()
    } else {
        let Ok(displays) = manager.present_displays() else {
            return;
        };
        displays
    };
    for (entity, window, parent, mut reason, mut retry, unmanaged, moving, resizing, restored) in
        &mut windows
    {
        if reason.is_added() || (restored && !config.is_changed()) {
            continue;
        }
        if restored {
            commands.entity(entity).remove::<RestoredFloatPolicy>();
        }
        if !config.float_recheck() || !reason.automatic() {
            if retry.is_some() {
                commands.entity(entity).remove::<FloatRecheck>();
            }
            retry = None;
        }
        if matches!(*reason, FloatReason::User | FloatReason::UserTile) {
            continue;
        }
        if reason.automatic()
            && !config.is_changed()
            && strips.iter().any(|(_, strip, _)| strip.tabbed(entity))
        {
            commands.entity(entity).remove::<FloatRecheck>();
            continue;
        }
        if unmanaged.is_some_and(|u| !matches!(u, Unmanaged::Floating)) || moving || resizing {
            if let Some(ref mut retry) = retry {
                retry.next = now + Duration::from_secs(3);
            }
            continue;
        }
        let event = changed.iter().find(|(id, _)| *id == window.id());
        let timer = retry.as_ref().is_some_and(|retry| now >= retry.next);
        if !config.is_changed()
            && !event.is_some_and(|(_, title)| *title)
            && !(config.float_recheck() && reason.automatic() && (timer || event.is_some()))
        {
            continue;
        }
        // E2 owns ignored-display state. Never re-tile a window there.
        let frame = window.frame();
        if super::display::frame_on_display_set(frame, &present, &ignored) {
            if let Some(ref mut retry) = retry {
                retry.next = now + Duration::from_secs(3);
            }
            continue;
        }
        let Ok(app) = apps.get(parent.parent()) else {
            commands.entity(entity).remove::<FloatRecheck>();
            continue;
        };
        if timer && retry.as_ref().is_some_and(|retry| retry.remaining == 2) {
            window.confirm_fixed_size();
        }
        let properties = super::WindowProperties::new(app, window, &config);
        let next = properties.float_reason;
        if !config.float_recheck() && !config.is_changed() && reason.automatic() && next.automatic()
        {
            continue;
        }
        if matches!(unmanaged, Some(Unmanaged::Floating)) != next.floating() {
            if next.floating() {
                // Save the exact former slot before Unmanaged's observer removes it.
                if let Some((_, strip, _)) = strips.iter().find(|(_, s, _)| s.contains(entity))
                    && let Ok(index) = strip.index_of(entity)
                {
                    commands.entity(entity).insert(PreviousManagedStrip {
                        workspace_id: strip.id(),
                        virtual_index: strip.virtual_index,
                        index,
                    });
                }
                commands.entity(entity).insert(Unmanaged::Floating);
            } else if matches!(unmanaged, Some(Unmanaged::Floating)) {
                // The upstream Remove<Unmanaged> observer restores the old slot.
                commands.entity(entity).remove::<Unmanaged>();
            }
        }
        if *reason != next {
            *reason = next;
        }
        if timer && let Some(ref mut retry) = retry {
            retry.remaining = retry.remaining.saturating_sub(1);
            if retry.remaining == 0 {
                commands.entity(entity).remove::<FloatRecheck>();
            } else {
                retry.next = now + Duration::from_secs(3);
            }
        }
    }
}
