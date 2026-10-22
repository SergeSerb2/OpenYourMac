//! Real title-bar drag reorder, separate from modifier resize and reveal clicks.
use super::layout::{Column, LayoutStrip};
use super::oym_layout::EdgePin;
use super::oym_visual::{DragShape, drag_shape, reorder, snapshot};
use super::{
    ActiveWorkspaceMarker, LayoutPosition, MissionControlActive, MouseHeldMarker, RepositionMarker,
    ResizeMarker, SpawnCommandsExt, Unmanaged,
};
use crate::config::Config;
use crate::events::Event as WMEvent;
use crate::manager::{Display, Window, WindowManager, origin_from};
use crate::minimap;
use bevy::prelude::*;
use std::time::{Duration, Instant};

/// Temporary ownership of a real title-bar press. Layout must not animate
/// the source back under the user's pointer. Expiry covers a lost mouse-up.
#[derive(Component)]
pub(super) struct TitleDragMarker {
    until: Instant,
    dragged: bool,
}

#[derive(Default, Resource)]
pub(super) struct DragState {
    drag: Option<Drag>,
}
struct Drag {
    entity: Entity,
    strip: Entity,
    columns: Vec<Column>,
    shape: DragShape,
    source: usize,
    start: bevy::math::IRect,
    pressed: crate::manager::Origin,
    last_event: Instant,
    moved: bool,
    dragged: bool,
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    clippy::type_complexity
)]
pub(super) fn drag_reorder(
    mut events: MessageReader<WMEvent>,
    mut state: ResMut<DragState>,
    mut strips: Query<
        (Entity, &mut LayoutStrip, &super::Position, &ChildOf),
        With<ActiveWorkspaceMarker>,
    >,
    windows: Query<(
        Entity,
        &Window,
        Has<RepositionMarker>,
        Has<ResizeMarker>,
        Has<Unmanaged>,
    )>,
    displays: Query<(&Display, Option<&super::DockPosition>)>,
    geometry: Query<(&LayoutPosition, &super::Bounds)>,
    pins: Query<&EdgePin>,
    held: Query<Entity, With<MouseHeldMarker>>,
    manager: Res<WindowManager>,
    config: Res<Config>,
    mission: Res<MissionControlActive>,
    mut commands: Commands,
) {
    if (!config.drag_reorder()
        || mission.0
        || state.drag.as_ref().is_some_and(|d| {
            !d.dragged
                && d.last_event.elapsed() > Duration::from_secs(5)
                && !crate::platform::input::mouse_held()
        }))
        && let Some(drag) = state.drag.take()
    {
        commands.entity(drag.entity).remove::<TitleDragMarker>();
        if !crate::platform::input::mouse_held() {
            commands.reshuffle_around(drag.entity);
        }
    }
    for event in events.read() {
        match event {
            WMEvent::SystemWoke { .. }
            | WMEvent::SpaceChanged
            | WMEvent::DisplayChanged
            | WMEvent::DisplayRemoved { .. } => {
                if let Some(drag) = state.drag.take() {
                    commands.entity(drag.entity).remove::<TitleDragMarker>();
                }
                minimap::cancel_input();
            }
            WMEvent::MouseDown { point, modifiers } => {
                if let Some(drag) = state.drag.take() {
                    commands.entity(drag.entity).remove::<TitleDragMarker>();
                }
                if !config.drag_reorder()
                    || mission.0
                    || config
                        .mouse_resize_modifier()
                        .is_some_and(|m| m.matches(*modifiers))
                {
                    continue;
                }
                let Ok(id) = manager.find_window_at_point(point) else {
                    continue;
                };
                let Some((entity, window, false, false, false)) =
                    windows.iter().find(|(_, w, _, _, _)| w.id() == id)
                else {
                    continue;
                };
                let frame = window.frame();
                let cursor = origin_from(*point);
                let top = frame.min.y + window.vertical_padding();
                if cursor.y < top
                    || cursor.y > top + 28
                    || cursor.x < frame.min.x + window.horizontal_padding()
                    || cursor.x >= frame.max.x - window.horizontal_padding()
                {
                    continue;
                }
                let Ok((owner, strip, _, _)) = strips.single() else {
                    continue;
                };
                let Ok(source) = strip.index_of(entity) else {
                    continue;
                };
                if strip
                    .get(source)
                    .is_ok_and(|c| c.window_iter().any(|e| pins.get(e).is_ok()))
                {
                    continue;
                }
                commands.entity(entity).insert(TitleDragMarker {
                    until: Instant::now() + Duration::from_secs(5),
                    dragged: false,
                });
                state.drag = Some(Drag {
                    entity,
                    strip: owner,
                    columns: snapshot(strip),
                    shape: drag_shape(strip, &pins, |e| {
                        windows.get(e).ok().map(|(_, w, _, _, _)| w.frame())
                    }),
                    source,
                    start: frame,
                    pressed: cursor,
                    last_event: Instant::now(),
                    moved: false,
                    dragged: false,
                });
            }
            WMEvent::MouseDragged { point, .. } => {
                let Some(drag) = state.drag.as_mut() else {
                    continue;
                };
                drag.last_event = Instant::now();
                drag.dragged = true;
                commands.entity(drag.entity).insert(TitleDragMarker {
                    until: drag.last_event + Duration::from_secs(5),
                    dragged: true,
                });
                let Ok((_, window, moving, resizing, unmanaged)) = windows.get(drag.entity) else {
                    state.drag = None;
                    continue;
                };
                // AX echoes of our own animation cannot start a drag. A real
                // move must change origin without changing size, after >6pt travel.
                let current = window.frame();
                let cursor = origin_from(*point);
                if moving
                    || resizing
                    || unmanaged
                    || current.size().chebyshev_distance(drag.start.size()) > 2
                {
                    commands.entity(drag.entity).remove::<TitleDragMarker>();
                    state.drag = None;
                    continue;
                }
                if (cursor.x - drag.pressed.x).abs() > 6
                    && (current.min.x - drag.start.min.x).abs() > 4
                {
                    drag.moved = true;
                    for entity in &held {
                        commands.entity(entity).despawn();
                    }
                }
            }
            WMEvent::MouseUp { point, .. } => {
                let Some(drag) = state.drag.take() else {
                    continue;
                };
                commands.entity(drag.entity).remove::<TitleDragMarker>();
                if !drag.moved {
                    invalidate_position(drag.entity, &mut commands);
                    continue;
                }
                let cursor = origin_from(*point);
                if super::display::frame_on_ignored_display(
                    bevy::math::IRect::from_center_size(cursor, bevy::math::IVec2::ONE),
                    &config,
                    &manager,
                ) {
                    continue;
                }
                invalidate_position(drag.entity, &mut commands);
                let Ok((owner, mut strip, strip_position, parent)) = strips.single_mut() else {
                    continue;
                };
                if owner != drag.strip
                    || snapshot(&strip) != drag.columns
                    || drag.shape
                        != drag_shape(&strip, &pins, |e| {
                            windows.get(e).ok().map(|(_, w, _, _, _)| w.frame())
                        })
                {
                    continue;
                }
                if !windows
                    .get(drag.entity)
                    .is_ok_and(|(_, _, moving, resizing, unmanaged)| {
                        !moving && !resizing && !unmanaged
                    })
                {
                    continue;
                }
                let Ok((display, dock)) = displays.get(parent.parent()) else {
                    continue;
                };
                let frame = |e| {
                    geometry
                        .get(e)
                        .ok()
                        .map(|(p, b)| bevy::math::IRect::from_corners(p.0, p.0 + b.0))
                };
                let pins_geometry =
                    strip.pin_geometry(display.actual_display_bounds(dock, &config), &frame);
                if !pins_geometry.viewport.contains(cursor) {
                    continue;
                }
                // Logical layout positions plus the strip offset retain the
                // distinct centres of offscreen columns parked at one sliver.
                let slot = strip
                    .columns()
                    .enumerate()
                    .find_map(|(i, column)| {
                        if i == drag.source || strip.edge_pinned_column(column).is_some() {
                            return None;
                        }
                        let (position, bounds) = geometry.get(column.top()?).ok()?;
                        (cursor.x < strip_position.0.x + position.0.x + bounds.0.x / 2).then_some(i)
                    })
                    .unwrap_or_else(|| {
                        strip
                            .columns()
                            .position(|c| {
                                strip.edge_pinned_column(c) == Some(super::oym_layout::Edge::Right)
                            })
                            .unwrap_or(strip.len())
                    });
                if reorder(&mut strip, drag.source, slot, &pins) {
                    commands.reshuffle_around(drag.entity);
                }
            }
            _ => {}
        }
    }
}

pub(super) fn expire_drag_markers(
    markers: Populated<(Entity, &TitleDragMarker)>,
    mut events: MessageReader<WMEvent>,
    mut state: ResMut<DragState>,
    mut commands: Commands,
) {
    // Let the normal mouse-up transaction commit even after a long pause.
    let released = events
        .read()
        .any(|event| matches!(event, WMEvent::MouseUp { .. }));
    if released || crate::platform::input::mouse_held() {
        return;
    }
    for (entity, marker) in &markers {
        if marker.dragged || Instant::now() >= marker.until {
            if state
                .drag
                .as_ref()
                .is_some_and(|drag| drag.entity == entity)
            {
                state.drag = None;
            }
            commands.entity(entity).remove::<TitleDragMarker>();
            invalidate_position(entity, &mut commands);
            commands.reshuffle_around(entity);
        }
    }
}

/// A skipped layout change must be reconsidered after the press ends, even if
/// the final column index did not change. Never reclaim an E2-released window.
fn invalidate_position(entity: Entity, commands: &mut Commands) {
    commands.queue(move |world: &mut World| {
        if world.get::<Unmanaged>(entity).is_none()
            && let Some(mut position) = world.get_mut::<LayoutPosition>(entity)
        {
            position.set_changed();
        }
    });
}
