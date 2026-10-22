//! Column metadata and product layout operations. Geometry remains in `layout`.
use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};

pub use crate::commands::Edge;
use crate::commands::{Direction, Operation, filter_window_operations};
use crate::config::Config;
use crate::ecs::layout::{Column, LayoutStrip, MIN_WINDOW_HEIGHT, StackItem};
use crate::ecs::params::{ActiveDisplayMut, Windows};
use crate::ecs::{FullWidthMarker, SpawnCommandsExt};
use crate::events::Event;
use crate::manager::Window;
use crate::util::round_px;
use bevy::ecs::entity::{EntityHashMap, EntityHashSet};
use bevy::prelude::*;
use tracing::debug;

/// A column's identity survives reordering, native-tab promotion and removal of
/// its first member. It is process-local; persistence rebinds metadata to saved
/// window identities rather than serializing Bevy entities or these counters.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ColumnId(u64);

impl ColumnId {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Self(NEXT.fetch_add(1, Ordering::Relaxed))
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct PinnedColumn {
    pub edge: Edge,
    pub width_before: i32,
    anchor: Option<ColumnId>,
    anchor_after: bool,
}

/// Mirrored on every member for overlays. `LayoutStrip` owns the pin, keyed by
/// `ColumnId`; changing a column's active/first member cannot transfer the pin.
#[derive(Component, Clone, Copy, Debug, PartialEq, Eq)]
pub struct EdgePin(pub Edge);

/// Width saved by pinning, independent of the full-width toggle's memory.
#[derive(Component, Clone, Copy, Debug, PartialEq, Eq)]
pub struct WidthBeforePin {
    pub column: ColumnId,
    pub width: i32,
}

/// Real window height in logical points, excluding per-window padding. Captured
/// before admission writes. Engine resize echoes and width-only resizes never
/// replace it. Persistence applies it only when boot identifiers match.
#[derive(Component, Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeptHeight(pub i32);

#[derive(Component, Clone, Copy, Debug)]
pub struct PinGeometry {
    pub viewport: IRect,
    pub left_width: i32,
    pub left_x: i32,
    pub right_x: i32,
    pub right_width: i32,
}

impl LayoutStrip {
    pub fn column_id(&self, entity: Entity) -> Option<ColumnId> {
        self.column_ids.get(&entity).copied()
    }

    pub fn active_member(&self, entity: Entity) -> Option<Entity> {
        self.active_members.get(&self.column_id(entity)?).copied()
    }

    pub(crate) fn select_member(&mut self, entity: Entity) {
        if let Some(id) = self.column_id(entity) {
            self.active_members.insert(id, entity);
        }
    }

    pub fn edge_pinned(&self, entity: Entity) -> Option<Edge> {
        self.pins.get(&self.column_id(entity)?).map(|pin| pin.edge)
    }

    pub fn edge_pinned_column(&self, column: &Column) -> Option<Edge> {
        column.window_iter().find_map(|e| self.edge_pinned(e))
    }

    /// Unpinned columns in their strip order. Their layout x starts at zero;
    /// pinned columns occupy fixed display slots outside that coordinate space.
    pub fn scroll_columns(&self) -> impl Iterator<Item = &Column> {
        self.columns()
            .filter(|col| self.edge_pinned_column(col).is_none())
    }

    /// Reconciles identities and metadata after *every* structural mutation.
    /// Surviving members keep the original column identity. A split assigns a
    /// fresh identity to the expelled item; a merge retains the target identity.
    /// Pins are ordered at their edges and there can be only one per edge.
    pub(super) fn normalize_columns(&mut self) {
        let mut used = HashSet::new();
        let mut ids = EntityHashMap::default();
        let mut tabbed = EntityHashSet::default();
        for column in &self.columns {
            let id = column
                .window_iter()
                .filter_map(|e| self.column_ids.get(&e).copied())
                .find(|id| !used.contains(id))
                .unwrap_or_else(ColumnId::new);
            used.insert(id);
            let is_tabbed = matches!(column, Column::Stack(items) if items.len() > 1)
                && column
                    .window_iter()
                    .any(|e| self.tabbed_stacks.contains(&e));
            for entity in column.window_iter() {
                ids.insert(entity, id);
                if is_tabbed {
                    tabbed.insert(entity);
                }
            }
        }
        self.column_ids = ids;
        self.tabbed_stacks = tabbed;
        self.row_weights
            .retain(|e, _| self.column_ids.contains_key(e));
        self.pins.retain(|id, _| used.contains(id));
        self.active_members
            .retain(|id, entity| self.column_ids.get(entity) == Some(id));
        let mut left = false;
        let mut right = false;
        // Strip order makes duplicate resolution deterministic, including restore.
        for column in &self.columns {
            let Some(id) = column.top().and_then(|e| self.column_id(e)) else {
                continue;
            };
            if let Some(pin) = self.pins.get(&id) {
                let occupied = match pin.edge {
                    Edge::Left => &mut left,
                    Edge::Right => &mut right,
                };
                if *occupied {
                    self.pins.remove(&id);
                } else {
                    *occupied = true;
                }
            }
        }
        if let Some(index) = self
            .columns
            .iter()
            .position(|c| self.edge_pinned_column(c) == Some(Edge::Left))
            && let Some(column) = self.columns.remove(index)
        {
            self.columns.push_front(column);
        }
        if let Some(index) = self
            .columns
            .iter()
            .position(|c| self.edge_pinned_column(c) == Some(Edge::Right))
            && let Some(column) = self.columns.remove(index)
        {
            self.columns.push_back(column);
        }
    }

    /// Moves the entire column to `index` (clamped to the last column), keeping
    /// its identity, stack members, tab selection, weights and pin. Pinned
    /// columns retain their edge ordering after normalization. Shared by
    /// numbered swap and optional minimap/drag clients.
    pub fn move_column_to(&mut self, entity: Entity, index: usize) -> crate::errors::Result<()> {
        let from = self.index_of(entity)?;
        if let Some(column) = self.columns.remove(from) {
            self.columns.insert(index.min(self.columns.len()), column);
        }
        self.normalize_columns();
        Ok(())
    }

    fn unpin_id(&mut self, id: ColumnId) {
        let Some(pin) = self.pins.remove(&id) else {
            return;
        };
        if let Some(anchor) = pin.anchor
            && let Some(from) = self
                .columns
                .iter()
                .position(|c| c.top().and_then(|e| self.column_id(e)) == Some(id))
            && let Some(column) = self.columns.remove(from)
        {
            let at = self
                .columns
                .iter()
                .position(|c| c.top().and_then(|e| self.column_id(e)) == Some(anchor))
                .map_or(self.columns.len(), |at| at + usize::from(pin.anchor_after));
            self.columns.insert(at, column);
        }
    }

    pub fn toggle_pin(&mut self, entity: Entity, edge: Edge, width: i32) {
        self.normalize_columns();
        if self
            .index_of(entity)
            .ok()
            .and_then(|i| self.get(i).ok())
            .is_some_and(|c| matches!(c, Column::Fullscren(_)))
        {
            return;
        }
        let Some(id) = self.column_id(entity) else {
            return;
        };
        if self.edge_pinned(entity) == Some(edge) {
            self.unpin_id(id);
        } else {
            let previous = self.pins.get(&id).copied();
            let displaced = self
                .pins
                .iter()
                .find_map(|(other, pin)| (pin.edge == edge).then_some(*other));
            if let Some(other) = displaced {
                self.unpin_id(other);
            }
            let anchor = self.index_of(entity).ok().and_then(|index| {
                let neighbour = match edge {
                    Edge::Left => index.checked_add(1),
                    Edge::Right => index.checked_sub(1),
                }?;
                self.columns
                    .get(neighbour)?
                    .top()
                    .and_then(|e| self.column_id(e))
            });
            self.pins.insert(
                id,
                PinnedColumn {
                    edge,
                    width_before: previous.map_or(width, |p| p.width_before),
                    anchor: previous.and_then(|p| p.anchor).or(anchor),
                    anchor_after: previous.map_or(edge == Edge::Right, |pin| pin.anchor_after),
                },
            );
        }
        self.normalize_columns();
    }

    pub(crate) fn restore_pin(&mut self, entity: Entity, edge: Edge, width: i32) {
        if self.edge_pinned(entity) != Some(edge) {
            self.toggle_pin(entity, edge, width);
        }
    }

    pub(super) fn padding_gap(
        &self,
        left: Option<Entity>,
        right: Option<Entity>,
        horizontal: bool,
    ) -> i32 {
        let padding = |entity| {
            self.window_padding
                .get(&entity)
                .map(|(h, v)| if horizontal { *h } else { *v })
        };
        if left.and_then(padding) == Some(self.default_half_gap)
            && right.and_then(padding) == Some(self.default_half_gap)
        {
            self.gap_adjustment
        } else {
            0
        }
    }

    pub(super) fn column_gap(&self, left: &Column, right: &Column) -> i32 {
        self.padding_gap(left.top(), right.top(), true)
    }

    /// A pin's resize budget excludes only the other pin and the scrolling
    /// reserve, so resizing it does not change its own width denominator.
    pub(crate) fn resize_viewport<W>(&self, entity: Entity, full: IRect, frame: &W) -> IRect
    where
        W: Fn(Entity) -> Option<IRect>,
    {
        let Some(edge) = self.edge_pinned(entity) else {
            return self.pin_geometry(full, frame).viewport;
        };
        let other = self
            .columns()
            .find(|column| {
                self.edge_pinned_column(column)
                    .is_some_and(|pin| pin != edge)
            })
            .and_then(|column| column.width(frame))
            .unwrap_or(0)
            .max(0);
        let reserve = if self.scroll_columns().next().is_some() {
            160.min(full.width().max(1))
        } else {
            0
        };
        let width = (full.width() - other - reserve).max(1);
        let mut viewport = full;
        match edge {
            Edge::Left => viewport.max.x = viewport.min.x + width,
            Edge::Right => viewport.min.x = viewport.max.x - width,
        }
        viewport
    }

    /// Reserve pins' logical cell widths, including their two half-gap pads.
    /// Leave at least min(160, viewport) points for scrolling when it has any
    /// columns. Oversized pins share the remaining budget proportionally. With
    /// no scrolling columns, pins may use the entire viewport. The edge-facing
    /// half-padding is compensated by `Display::actual_display_bounds`.
    pub fn pin_geometry<W>(&self, viewport: IRect, frame: &W) -> PinGeometry
    where
        W: Fn(Entity) -> Option<IRect>,
    {
        let width = |edge| {
            self.columns()
                .find(|c| self.edge_pinned_column(c) == Some(edge))
                .and_then(|c| c.width(frame))
                .unwrap_or(0)
                .max(0)
        };
        let (mut left, mut right) = (width(Edge::Left), width(Edge::Right));
        let reserve = if self.scroll_columns().next().is_some() {
            160.min(viewport.width().max(1))
        } else {
            0
        };
        let budget = (viewport.width() - reserve).max(0);
        let total = left + right;
        if total > budget && total > 0 {
            left = round_px(f64::from(left) * f64::from(budget) / f64::from(total));
            right = budget - left;
        }
        let left_column = self
            .columns()
            .find(|col| self.edge_pinned_column(col) == Some(Edge::Left));
        let right_column = self
            .columns()
            .find(|col| self.edge_pinned_column(col) == Some(Edge::Right));
        let first_scroll = self.scroll_columns().next();
        let last_scroll = self.scroll_columns().last();
        let left_gap = left_column
            .zip(first_scroll)
            .map_or(0, |(left, right)| self.column_gap(left, right));
        let right_gap = last_scroll
            .zip(right_column)
            .map_or(0, |(left, right)| self.column_gap(left, right));
        let mut reduced = viewport;
        reduced.min.x += left + left_gap;
        reduced.max.x -= right + right_gap;
        PinGeometry {
            viewport: reduced,
            left_x: viewport.min.x,
            right_x: viewport.max.x - right,
            left_width: left,
            right_width: right,
        }
    }

    /// Valid offsets keep the scrolling strip's first or last cell at a viewport
    /// edge. A short strip can move between the two edge alignments. Pinned
    /// cells never contribute to the range. Legacy continuous swipe can expose
    /// an endpoint at the opposite edge, as upstream allowed.
    pub fn scroll_range<W>(&self, viewport: IRect, frame: &W, continuous: bool) -> (i32, i32)
    where
        W: Fn(Entity) -> Option<IRect>,
    {
        let extents: Vec<_> = self
            .column_positions(frame)
            .filter(|(column, _)| self.edge_pinned_column(column).is_none())
            .filter_map(|(column, x)| column.width(frame).map(|width| (x, width)))
            .collect();
        let total = extents.last().map_or(0, |(x, width)| x + width);
        if continuous && let Some((last_x, _)) = extents.last() {
            (viewport.min.x - last_x, viewport.max.x)
        } else {
            let far = viewport.max.x - total;
            (viewport.min.x.min(far), viewport.min.x.max(far))
        }
    }

    /// Merges the focused column with the adjacent column. Like upstream
    /// `stack`, all source members follow the focused window; consume-west and
    /// legacy stack are exact aliases even when the source is already stacked.
    pub fn consume(&mut self, entity: Entity, east: bool) -> crate::errors::Result<()> {
        self.consume_column(entity, east)
    }

    pub(super) fn consume_column(
        &mut self,
        entity: Entity,
        east: bool,
    ) -> crate::errors::Result<()> {
        self.normalize_columns();
        let index = self.index_of(entity)?;
        let source = self.get(index)?;
        if self.edge_pinned_column(&source).is_some() {
            debug!(?entity, "consume refused: pinned columns are barriers");
            return Ok(());
        }
        let target_index = if east {
            index.checked_add(1)
        } else {
            index.checked_sub(1)
        };
        let Some(target_index) = target_index.filter(|i| *i < self.len()) else {
            return Ok(());
        };
        let target = self.get(target_index)?;
        if self.edge_pinned_column(&target).is_some() {
            debug!(?entity, "consume refused: pinned columns are barriers");
            return Ok(());
        }
        if matches!(source, Column::Fullscren(_)) || matches!(target, Column::Fullscren(_)) {
            return Ok(());
        }
        let target_id = target.top().and_then(|e| self.column_id(e));
        let target_tabbed = target.window_iter().any(|e| self.is_tabbed_display(e));
        let into_items = |c| match c {
            Column::Single(e) | Column::Fullscren(e) => vec![StackItem::Single(e)],
            Column::Tabs(t) => vec![StackItem::Tabs(t)],
            Column::Stack(s) => s,
        };
        let mut items = into_items(target);
        let source_items = into_items(source);
        if items
            .iter()
            .chain(&source_items)
            .flat_map(StackItem::window_iter)
            .any(|e| self.row_weights.contains_key(&e))
        {
            for group in [&items, &source_items] {
                let weights: Vec<_> = group
                    .iter()
                    .map(|item| {
                        item.window_iter()
                            .find_map(|e| self.row_weights.get(&e))
                            .copied()
                            .unwrap_or(1.0)
                    })
                    .collect();
                let total: f64 = weights.iter().sum();
                for (item, weight) in group.iter().zip(weights) {
                    for e in item.window_iter() {
                        self.row_weights.insert(e, weight / total);
                    }
                }
            }
        }
        items.extend(source_items);
        let merged = Column::Stack(items);
        for e in merged.window_iter() {
            if let Some(id) = target_id {
                self.column_ids.insert(e, id);
            }
            if target_tabbed {
                self.tabbed_stacks.insert(e);
            } else {
                self.tabbed_stacks.remove(&e);
            }
        }
        self.columns.remove(index.max(target_index));
        self.columns.remove(index.min(target_index));
        self.columns.insert(index.min(target_index), merged);
        self.normalize_columns();
        self.select_member(entity);
        Ok(())
    }

    pub fn expel(&mut self, entity: Entity, west: bool) -> crate::errors::Result<()> {
        self.normalize_columns();
        let index = self.index_of(entity)?;
        let neighbour = if west {
            index.checked_sub(1)
        } else {
            index.checked_add(1)
        };
        if self.edge_pinned(entity).is_some()
            || neighbour
                .and_then(|i| self.get(i).ok())
                .is_some_and(|column| self.edge_pinned_column(&column).is_some())
        {
            debug!(?entity, "expel refused: pinned columns are barriers");
            return Ok(());
        }
        let Column::Stack(items) = self.get(index)? else {
            return Ok(());
        };
        let Some(item) = items.iter().find(|item| item.contains(entity)).cloned() else {
            return Ok(());
        };
        let survivor = items
            .iter()
            .find(|other| !other.contains(entity))
            .and_then(StackItem::top);
        for member in item.window_iter() {
            self.remove(member);
        }
        let at = survivor
            .and_then(|e| self.index_of(e).ok())
            .unwrap_or(index)
            + usize::from(!west);
        match item {
            StackItem::Single(e) => self.insert_at(at, e),
            StackItem::Tabs(tabs) => self.insert_tab_group_at(at, &tabs),
        }
        self.normalize_columns();
        self.select_member(entity);
        Ok(())
    }

    pub(crate) fn set_row_weight(&mut self, entity: Entity, weight: f64) {
        if weight.is_finite() && weight > 0.0 {
            self.row_weights.insert(entity, weight);
        }
    }

    pub(super) fn weighted_heights(&self, items: &[StackItem], height: i32) -> Option<Vec<i32>> {
        if !items.iter().any(|item| {
            item.window_iter()
                .any(|e| self.row_weights.contains_key(&e))
        }) {
            return None;
        }
        // Match the binpack path's capacity limit and cell-height floor.
        if height < MIN_WINDOW_HEIGHT.checked_mul(i32::try_from(items.len()).ok()?)? {
            return None;
        }
        let weights: Vec<_> = items
            .iter()
            .map(|item| {
                item.window_iter()
                    .find_map(|e| self.row_weights.get(&e))
                    .copied()
                    .unwrap_or(1.0)
            })
            .collect();
        let pads: Vec<_> = items
            .iter()
            .map(|item| {
                item.top()
                    .and_then(|e| self.window_padding.get(&e))
                    .map_or(0, |(_, vertical)| 2 * vertical)
            })
            .collect();
        let total: f64 = weights.iter().sum();
        let available = (height - pads.iter().sum::<i32>()).max(0);
        let mut remaining = available;
        let mut heights: Vec<i32> = weights
            .iter()
            .enumerate()
            .map(|(i, weight)| {
                let h = if i + 1 == weights.len() {
                    remaining
                } else {
                    round_px(f64::from(available) * weight / total).clamp(0, remaining)
                };
                remaining -= h;
                h + pads[i]
            })
            .collect();
        let mut excess = 0;
        for height in &mut heights {
            excess += (MIN_WINDOW_HEIGHT - *height).max(0);
            *height = (*height).max(MIN_WINDOW_HEIGHT);
        }
        // Preserve the total: raise short rows by taking slack from the largest
        // row, choosing a new donor if it reaches the same floor.
        while excess > 0 {
            let largest = heights.iter_mut().max()?;
            let taken = excess.min(*largest - MIN_WINDOW_HEIGHT);
            if taken <= 0 {
                return None;
            }
            *largest -= taken;
            excess -= taken;
        }
        Some(heights)
    }
}

pub struct OpenYourMacLayoutPlugin;
impl Plugin for OpenYourMacLayoutPlugin {
    fn build(&self, app: &mut App) {
        app.add_observer(capture_admitted_height);
        app.add_observer(clear_unmanaged_pin);
        app.add_systems(
            Update,
            (remember_active_member, invalidate_layout_on_config)
                .before(prepare_gap_geometry)
                .before(super::layout::layout_strip_changed),
        );
        app.add_systems(
            PreUpdate,
            layout_operations.run_if(bevy::ecs::schedule::common_conditions::on_message::<Event>),
        );
        app.add_systems(
            Update,
            (
                prepare_gap_geometry,
                sync_pin_components,
                clear_stacked_kept_heights,
            )
                .chain()
                .after(super::triggers::apply_window_positions)
                .before(super::layout::layout_strip_changed),
        );
    }
}

/// Two rounded half-pads can exceed an odd inner gap by one point. Correct the
/// distance between cells/rows, leaving each window's explicit padding intact.
fn prepare_gap_geometry(
    mut strips: Query<&mut LayoutStrip, Changed<LayoutStrip>>,
    config: Res<Config>,
    windows: Query<&Window>,
) {
    let adjustment = round_px(config.gap_inner()) - 2 * config.default_window_padding();
    for mut strip in &mut strips {
        let padding = strip
            .all_windows()
            .into_iter()
            .filter_map(|entity| {
                windows
                    .get(entity)
                    .ok()
                    .map(|w| (entity, (w.horizontal_padding(), w.vertical_padding())))
            })
            .collect();
        let strip = strip.bypass_change_detection();
        strip.gap_adjustment = adjustment;
        strip.default_half_gap = config.default_window_padding();
        strip.window_padding = padding;
    }
}

fn invalidate_layout_on_config(config: Res<Config>, mut strips: Query<&mut LayoutStrip>) {
    if config.is_changed() {
        for mut strip in &mut strips {
            strip.set_changed();
        }
    }
}

fn remember_active_member(
    focused: Query<Entity, Added<crate::ecs::FocusedMarker>>,
    mut strips: Query<&mut LayoutStrip>,
) {
    for entity in focused {
        for mut strip in &mut strips {
            if strip.contains(entity) {
                strip.select_member(entity);
            }
        }
    }
}

/// Floating, hidden and minimized windows leave their column. Drop the overlay
/// mirror as well as the strip-owned pin; releasing a window must not resize it.
fn clear_unmanaged_pin(
    trigger: On<Add, crate::ecs::Unmanaged>,
    unmanaged: Query<&crate::ecs::Unmanaged>,
    mut commands: Commands,
) {
    if let Ok(mut entity) = commands.get_entity(trigger.entity) {
        entity.try_remove::<(EdgePin, WidthBeforePin)>();
        if unmanaged
            .get(trigger.entity)
            .is_ok_and(|state| matches!(state, crate::ecs::Unmanaged::Floating))
        {
            entity.try_remove::<KeptHeight>();
        }
    }
}

fn capture_admitted_height(
    trigger: On<Add, Window>,
    windows: Query<&Window, Without<crate::ecs::Unmanaged>>,
    config: Res<Config>,
    mut commands: Commands,
) {
    if config.keep_window_height()
        && let Ok(window) = windows.get(trigger.entity)
    {
        commands.entity(trigger.entity).insert(KeptHeight(
            (window.frame().height() - 2 * window.vertical_padding()).max(1),
        ));
    }
}

/// A split/native-tab/custom-tab height is never a lone window's original
/// height. Clear it before layout can apply it after a later expel or close.
fn clear_stacked_kept_heights(
    strips: Query<&LayoutStrip, Changed<LayoutStrip>>,
    kept: Query<(), With<KeptHeight>>,
    mut commands: Commands,
) {
    for strip in &strips {
        for column in strip
            .columns()
            .filter(|column| !matches!(column, Column::Single(_)))
        {
            for entity in column.window_iter().filter(|entity| kept.contains(*entity)) {
                commands.entity(entity).remove::<KeptHeight>();
            }
        }
    }
}

fn sync_pin_components(
    strips: Query<&LayoutStrip, Changed<LayoutStrip>>,
    old: Query<(Option<&EdgePin>, Option<&WidthBeforePin>)>,
    windows: Windows,
    mut commands: Commands,
) {
    for strip in strips {
        for entity in strip.all_windows() {
            let Ok((edge, before)) = old.get(entity) else {
                continue;
            };
            let pin = strip
                .column_id(entity)
                .and_then(|id| strip.pins.get(&id).map(|pin| (id, pin)));
            if let Some((id, pin)) = pin {
                if edge.map(|p| p.0) != Some(pin.edge) || before.is_none_or(|p| p.column != id) {
                    commands.entity(entity).insert((
                        EdgePin(pin.edge),
                        WidthBeforePin {
                            column: id,
                            width: pin.width_before,
                        },
                    ));
                }
            } else if edge.is_some() || before.is_some() {
                if let Some(before) = before.filter(|p| Some(p.column) == strip.column_id(entity))
                    && let Some(size) = windows.size(entity)
                {
                    commands.resize_entity(entity, size.with_x(before.width));
                }
                commands
                    .entity(entity)
                    .remove::<(EdgePin, WidthBeforePin)>();
            }
        }
    }
}

fn layout_operations(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut active: ActiveDisplayMut,
    kept: Query<&KeptHeight>,
    config: Res<Config>,
    mut commands: Commands,
) {
    for operation in filter_window_operations(&mut messages, |op| {
        matches!(
            op,
            Operation::Pin(_)
                | Operation::Consume(_)
                | Operation::Expel(_)
                | Operation::AdjustWidth(_)
                | Operation::AdjustHeight(_)
        )
    }) {
        let Some((_, entity)) = windows.focused() else {
            continue;
        };
        if windows
            .get_managed(entity)
            .is_none_or(|(_, _, unmanaged)| unmanaged.is_some())
        {
            continue;
        }
        let full = active.actual_bounds(&config);
        let strip = active.active_strip();
        let Ok(index) = strip.index_of(entity) else {
            continue;
        };
        let Ok(column) = strip.get(index) else {
            continue;
        };
        match operation {
            Operation::Pin(edge) => strip.toggle_pin(
                entity,
                *edge,
                column.width(&|e| windows.moving_frame(e)).unwrap_or(160),
            ),
            Operation::Consume(direction) | Operation::Expel(direction) => {
                if !matches!(direction, Direction::East | Direction::West) {
                    debug!(?operation, "non-horizontal consume/expel is a no-op");
                    continue;
                }
                if matches!(operation, Operation::Consume(_)) {
                    _ = strip.consume(entity, *direction == Direction::East);
                } else {
                    _ = strip.expel(entity, *direction == Direction::West);
                }
            }
            Operation::AdjustWidth(delta) if delta.is_finite() => {
                let Some(width) = stepped_width(strip, &column, entity, full, *delta, &windows)
                else {
                    continue;
                };
                for member in column.window_iter() {
                    commands.entity(member).remove::<FullWidthMarker>();
                    if let Some(size) = windows.size(member) {
                        commands.resize_entity(member, size.with_x(width));
                    }
                }
            }
            Operation::AdjustHeight(delta) if delta.is_finite() => {
                if let Column::Stack(items) = column {
                    adjust_shares(
                        strip,
                        &items,
                        entity,
                        *delta,
                        full.height(),
                        &windows,
                        &mut commands,
                    );
                } else if config.keep_window_height() && matches!(column, Column::Single(_)) {
                    let padding = windows.get(entity).map_or(0, |w| 2 * w.vertical_padding());
                    let available = (full.height() - padding).max(1);
                    let height = kept.get(entity).map_or(available, |h| h.0);
                    let height =
                        (height + round_px(delta * f64::from(available))).clamp(1, available);
                    commands.entity(entity).insert(KeptHeight(height));
                    if let Some(size) = windows.size(entity) {
                        commands.resize_entity(entity, size.with_y(height + padding));
                    }
                }
            }
            _ => {}
        }
        commands.ensure_visible(entity);
    }
}

fn stepped_width(
    strip: &LayoutStrip,
    column: &Column,
    entity: Entity,
    full: IRect,
    delta: f64,
    windows: &Windows,
) -> Option<i32> {
    let pins = strip.pin_geometry(full, &|e| windows.moving_frame(e));
    let viewport = pins.viewport;
    // Bounds include virtual half-gap padding; step and minimum
    // sizes are visible logical points, so add padding only after
    // clamping the actual column width.
    let padding = column
        .top()
        .and_then(|e| windows.get(e))
        .map_or(0, |w| 2 * w.horizontal_padding());
    let (step_budget, available) = if let Some(edge) = strip.edge_pinned(entity) {
        let other_pin = match edge {
            Edge::Left => pins.right_width,
            Edge::Right => pins.left_width,
        };
        let usable = full.width() - padding;
        (usable, (usable - other_pin - 160).max(0))
    } else {
        let usable = viewport.width() - padding;
        (usable, usable)
    };
    if available <= 0 {
        return None;
    }
    let current = column
        .width(&|e| windows.moving_frame(e))
        .unwrap_or(160 + padding)
        - padding;
    Some(
        (current + round_px(delta * f64::from(step_budget))).clamp(160.min(available), available)
            + padding,
    )
}

fn adjust_shares(
    strip: &mut LayoutStrip,
    items: &[StackItem],
    entity: Entity,
    delta: f64,
    height: i32,
    windows: &Windows,
    commands: &mut Commands,
) {
    let Some(focused) = items.iter().position(|item| item.contains(entity)) else {
        return;
    };
    let tabbed = strip.is_tabbed_display(entity);
    let weights: Vec<_> = items
        .iter()
        .map(|item| {
            if tabbed {
                item.window_iter()
                    .find_map(|e| strip.row_weights.get(&e))
                    .copied()
                    .unwrap_or(1.0)
            } else {
                item.top()
                    .and_then(|e| windows.moving_frame(e).map(|frame| (e, frame)))
                    .map_or(1.0, |(e, frame)| {
                        let padding = windows.get(e).map_or(0, |w| 2 * w.vertical_padding());
                        f64::from((frame.height() - padding).max(1))
                    })
            }
        })
        .collect();
    let total: f64 = weights.iter().sum();
    let Ok(neighbours) = u32::try_from(items.len().saturating_sub(1)) else {
        return;
    };
    let next = (weights[focused] / total + delta)
        .clamp(0.12, (1.0 - 0.12 * f64::from(neighbours)).max(0.12));
    let rest = total - weights[focused];
    for (index, item) in items.iter().enumerate() {
        let share = if index == focused {
            next
        } else {
            (1.0 - next) * weights[index] / rest
        };
        for member in item.window_iter() {
            strip.set_row_weight(member, share);
        }
    }
    if !tabbed {
        let gaps: i32 = items
            .windows(2)
            .map(|pair| strip.padding_gap(pair[0].top(), pair[1].top(), false))
            .sum();
        if let Some(heights) = strip.weighted_heights(items, height - gaps) {
            for (item, height) in items.iter().zip(heights) {
                for member in item.window_iter() {
                    if let Some(size) = windows.size(member) {
                        commands.resize_entity(member, size.with_y(height));
                    }
                }
            }
        }
    }
}
