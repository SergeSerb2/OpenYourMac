use std::collections::{HashMap, HashSet};
use std::time::Duration;

use bevy::ecs::component::Component;
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::observer::On;
use bevy::ecs::query::Has;
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{Commands, Populated, Query, Res, ResMut};
use bevy::time::{Time, Timer, TimerMode, Virtual};
use objc2_core_graphics::CGDirectDisplayID;
use tracing::{Level, info, instrument, warn};

use crate::config::{Config, MissingWindowBehavior};
use crate::ecs::layout::{Column, LayoutStrip, PARKED_STRIP_SLIVER};
use crate::ecs::params::{WindowCtx, Windows};
use crate::ecs::state::{
    PaneruState, SavedColumn, SavedStackItem, SavedStrip, SavedWindow, SavedWorkspace,
};
use crate::ecs::workspace::PreviousStripPosition;
use crate::ecs::{
    ActiveDisplayMarker, ActiveWorkspaceMarker, RestoreWindowState, SpawnCommandsExt, Unmanaged,
};
use crate::manager::{Application, Display, Window};
use crate::platform::{Pid, WinID, WorkspaceId};

#[derive(Debug, Resource)]
pub(crate) struct SessionRestore {
    state: PaneruState,
    timer: Timer,
    saved_hard_keys: HashSet<WindowHardMatchKey>,
}

#[derive(Component)]
pub(super) struct RestoredColumnWidth(i32);

/// Admission defaults run after the restore observer during startup.
pub(super) fn apply_restored_widths(
    windows: Populated<(
        Entity,
        &RestoredColumnWidth,
        &mut super::Bounds,
        Option<&mut super::ResizeMarker>,
    )>,
    mut commands: Commands,
) {
    for (entity, width, mut bounds, resizing) in windows {
        bounds.0.x = width.0;
        if let Some(mut resizing) = resizing {
            resizing.0.x = width.0;
        }
        commands.entity(entity).remove::<RestoredColumnWidth>();
    }
}

impl SessionRestore {
    fn new(state: PaneruState, grace: Duration) -> Self {
        let saved_hard_keys = saved_hard_match_keys(&state);
        Self {
            state,
            timer: Timer::new(grace, TimerMode::Once),
            saved_hard_keys,
        }
    }
}

pub(super) fn tick_restore_grace(
    time: Res<Time<Virtual>>,
    mut session: Option<ResMut<SessionRestore>>,
    mut commands: Commands,
) {
    let Some(session) = session.as_mut() else {
        return;
    };

    session.timer.tick(time.delta());
    if session.timer.is_finished() {
        info!("Session restore grace period ended");
        commands.remove_resource::<SessionRestore>();
        commands.remove_resource::<PaneruState>();
    }
}

#[derive(Clone, Debug)]
pub(crate) struct CurrentWindowIdentity {
    pub entity: Entity,
    pub window_id: WinID,
    pub pid: Pid,
    pub bundle_id: String,
    pub title: String,
    pub identifier: String,
    pub role: String,
    pub subrole: String,
}

impl CurrentWindowIdentity {
    fn hard_key(&self) -> WindowHardMatchKey {
        WindowHardMatchKey::new(self.window_id, self.pid, self.bundle_id.clone())
    }

    #[cfg(test)]
    pub(crate) fn fallback_only(entity: Entity, bundle_id: &str, title: &str) -> Self {
        Self {
            entity,
            window_id: -1,
            pid: -1,
            bundle_id: bundle_id.to_string(),
            title: title.to_string(),
            identifier: "main".to_string(),
            role: "AXWindow".to_string(),
            subrole: "AXStandardWindow".to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WindowHardMatchKey {
    window_id: WinID,
    pid: Pid,
    bundle_id: String,
}

impl WindowHardMatchKey {
    fn new(window_id: WinID, pid: Pid, bundle_id: String) -> Self {
        Self {
            window_id,
            pid,
            bundle_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PlannedColumn {
    Single(Entity),
    Stack(Vec<PlannedStackItem>),
    Tabs(Vec<Entity>),
    Fullscreen(Entity),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PlannedStackItem {
    Single(Entity),
    Tabs(Vec<Entity>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PlannedStrip {
    pub workspace_id: WorkspaceId,
    pub display_id: Option<CGDirectDisplayID>,
    pub virtual_index: u32,
    pub columns: Vec<PlannedColumn>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RestorePlan {
    pub strips: Vec<PlannedStrip>,
    matched_windows: HashMap<WindowHardMatchKey, Entity>,
    pub active_virtual_by_workspace: HashMap<WorkspaceId, u32>,
    pub consumed_entities: HashSet<Entity>,
    pub ignored_missing_windows: usize,
    pub skipped_ambiguous_matches: usize,
}

pub(crate) struct RestorePlanner<'a> {
    state: &'a PaneruState,
    saved_hard_keys: HashSet<WindowHardMatchKey>,
}

impl<'a> RestorePlanner<'a> {
    pub(crate) fn new(state: &'a PaneruState) -> Self {
        Self {
            state,
            saved_hard_keys: saved_hard_match_keys(state),
        }
    }

    pub(crate) fn plan(&self, current: &[CurrentWindowIdentity]) -> RestorePlan {
        let mut plan = RestorePlan::default();

        for workspace in &self.state.workspaces {
            let surviving_strips = self.plan_workspace(workspace, current, &mut plan);
            Self::record_active_virtual(workspace, &surviving_strips, &mut plan);
            plan.strips.extend(surviving_strips);
        }

        plan
    }

    fn plan_workspace(
        &self,
        workspace: &SavedWorkspace,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Vec<PlannedStrip> {
        workspace
            .strips
            .iter()
            .filter_map(|strip| self.plan_strip(workspace, strip, current, plan))
            .collect()
    }

    fn plan_strip(
        &self,
        workspace: &SavedWorkspace,
        strip: &SavedStrip,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<PlannedStrip> {
        if crate::types::commands::virtual_workspace_number(strip.virtual_index).is_none() {
            warn!(
                "Skipping saved virtual workspace index {}; supported numbers are 1 to {}",
                strip.virtual_index,
                crate::types::commands::MAX_VIRTUAL_WORKSPACES
            );
            return None;
        }
        let columns = strip
            .columns
            .iter()
            .filter_map(|column| self.plan_column(column, current, plan))
            .collect::<Vec<_>>();

        (!columns.is_empty()).then_some(PlannedStrip {
            workspace_id: workspace.workspace_id,
            display_id: workspace.display_id,
            virtual_index: strip.virtual_index,
            columns,
        })
    }

    fn plan_column(
        &self,
        column: &SavedColumn,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<PlannedColumn> {
        match column {
            SavedColumn::Single(saved) => self
                .match_window(saved, current, plan)
                .map(PlannedColumn::Single),
            SavedColumn::Fullscreen(saved) => self
                .match_window(saved, current, plan)
                .map(PlannedColumn::Fullscreen),
            SavedColumn::Tabs(tabs) => compact_entities(
                tabs.iter()
                    .filter_map(|saved| self.match_window(saved, current, plan))
                    .collect(),
            ),
            SavedColumn::Stack(items) => compact_stack_items(
                items
                    .iter()
                    .filter_map(|item| self.plan_stack_item(item, current, plan))
                    .collect(),
            ),
        }
    }

    fn plan_stack_item(
        &self,
        item: &SavedStackItem,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<PlannedStackItem> {
        match item {
            SavedStackItem::Single(saved) => self
                .match_window(saved, current, plan)
                .map(PlannedStackItem::Single),
            SavedStackItem::Tabs(tabs) => compact_stack_tabs(
                tabs.iter()
                    .filter_map(|saved| self.match_window(saved, current, plan))
                    .collect(),
            ),
        }
    }

    fn match_window(
        &self,
        saved: &SavedWindow,
        current: &[CurrentWindowIdentity],
        plan: &mut RestorePlan,
    ) -> Option<Entity> {
        if let Some(window) = current.iter().find(|window| {
            !plan.consumed_entities.contains(&window.entity)
                && saved.hard_match(window.window_id, window.pid, &window.bundle_id)
        }) {
            plan.consumed_entities.insert(window.entity);
            plan.matched_windows.insert(saved.hard_key(), window.entity);
            return Some(window.entity);
        }

        let fallback_matches = current
            .iter()
            .filter(|window| {
                !plan.consumed_entities.contains(&window.entity)
                    && saved.fallback_match(window)
                    && !self.current_window_has_saved_hard_match(window)
            })
            .collect::<Vec<_>>();

        match fallback_matches.as_slice() {
            [window] => {
                plan.consumed_entities.insert(window.entity);
                plan.matched_windows.insert(saved.hard_key(), window.entity);
                Some(window.entity)
            }
            [] => {
                plan.ignored_missing_windows += 1;
                None
            }
            _ => {
                plan.skipped_ambiguous_matches += 1;
                None
            }
        }
    }

    fn current_window_has_saved_hard_match(&self, current: &CurrentWindowIdentity) -> bool {
        self.saved_hard_keys.contains(&current.hard_key())
    }

    fn record_active_virtual(
        workspace: &SavedWorkspace,
        surviving_strips: &[PlannedStrip],
        plan: &mut RestorePlan,
    ) {
        let Some(saved_active) = workspace.active_virtual_index else {
            if let Some(first_survivor) = surviving_strips
                .iter()
                .map(|strip| strip.virtual_index)
                .min()
            {
                plan.active_virtual_by_workspace
                    .insert(workspace.workspace_id, first_survivor);
            }
            return;
        };
        let Some(nearest_active) = surviving_strips
            .iter()
            .map(|strip| strip.virtual_index)
            .min_by_key(|virtual_index| (virtual_index.abs_diff(saved_active), *virtual_index))
        else {
            return;
        };

        plan.active_virtual_by_workspace
            .insert(workspace.workspace_id, nearest_active);
    }
}

fn saved_windows_in_state(state: &PaneruState) -> impl Iterator<Item = &SavedWindow> {
    state
        .workspaces
        .iter()
        .flat_map(|workspace| &workspace.strips)
        .flat_map(|strip| &strip.columns)
        .flat_map(saved_windows_in_column)
}

fn saved_windows_in_column(column: &SavedColumn) -> Box<dyn Iterator<Item = &SavedWindow> + '_> {
    match column {
        SavedColumn::Single(saved) | SavedColumn::Fullscreen(saved) => {
            Box::new(std::iter::once(saved))
        }
        SavedColumn::Tabs(tabs) => Box::new(tabs.iter()),
        SavedColumn::Stack(items) => Box::new(items.iter().flat_map(saved_windows_in_stack_item)),
    }
}

fn saved_windows_in_stack_item(
    item: &SavedStackItem,
) -> Box<dyn Iterator<Item = &SavedWindow> + '_> {
    match item {
        SavedStackItem::Single(saved) => Box::new(std::iter::once(saved)),
        SavedStackItem::Tabs(tabs) => Box::new(tabs.iter()),
    }
}

impl SavedWindow {
    fn hard_key(&self) -> WindowHardMatchKey {
        WindowHardMatchKey::new(self.window_id, self.pid, self.bundle_id.clone())
    }

    fn fallback_match(&self, current: &CurrentWindowIdentity) -> bool {
        !self.title.is_empty()
            && self.bundle_id == current.bundle_id
            && self.title == current.title
            && self.identifier == current.identifier
            && self.role == current.role
            && self.subrole == current.subrole
    }
}

fn saved_hard_match_keys(state: &PaneruState) -> HashSet<WindowHardMatchKey> {
    saved_windows_in_state(state)
        .map(SavedWindow::hard_key)
        .collect()
}

fn has_saved_fallback_windows(state: &PaneruState) -> bool {
    saved_windows_in_state(state).any(|window| !window.title.is_empty())
}

pub(crate) fn matches_startup_restore_state(
    window: &Window,
    app: &Application,
    session: Option<&SessionRestore>,
    restoration: Option<&PaneruState>,
    config: &Config,
) -> bool {
    // The app's own windows always float, including across engine restarts.
    if app
        .bundle_id()
        .is_some_and(|id| id == "com.openyourmac.OpenYourMac")
    {
        return false;
    }
    if !config.restore_enabled() {
        return false;
    }

    let Ok(pid) = window.pid() else {
        return false;
    };
    let bundle_id = app.bundle_id().unwrap_or_default().clone();
    let key = WindowHardMatchKey::new(window.id(), pid, bundle_id.clone());

    if let Some(session) = session {
        return session.saved_hard_keys.contains(&key);
    }

    let Some(state) = restoration else {
        return false;
    };
    saved_windows_in_state(state).any(|saved| saved.hard_match(window.id(), pid, &bundle_id))
}

#[allow(clippy::too_many_lines)]
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
pub(super) fn restore_window_state(
    _: On<RestoreWindowState>,
    mut workspaces: Query<(
        Entity,
        &mut LayoutStrip,
        Option<&ChildOf>,
        Has<ActiveWorkspaceMarker>,
    )>,
    displays: Query<(Entity, &Display, Has<ActiveDisplayMarker>)>,
    apps: Query<&Application>,
    session: Option<Res<SessionRestore>>,
    restoration: Option<Res<PaneruState>>,
    mut ctx: WindowCtx,
) {
    let restoration = if let Some(session) = session.as_deref() {
        &session.state
    } else {
        let Some(restoration) = restoration.as_deref() else {
            return;
        };
        if !ctx.config.restore_enabled() {
            info!("Session restore disabled by configuration");
            ctx.commands.remove_resource::<PaneruState>();
            return;
        }
        match ctx.config.restore_missing_windows() {
            MissingWindowBehavior::Ignore => {}
        }
        ctx.commands.insert_resource(SessionRestore::new(
            restoration.clone(),
            ctx.config.restore_startup_grace(),
        ));
        restoration
    };

    let current = current_window_identities(&ctx.windows, &apps, restoration);
    let plan = RestorePlanner::new(restoration).plan(&current);

    if plan.consumed_entities.is_empty() {
        info!(
            "Session restore matched 0 windows; missing={}, ambiguous={}",
            plan.ignored_missing_windows, plan.skipped_ambiguous_matches
        );
        return;
    }

    let mut existing_workspace_parents = HashMap::new();
    let mut active_workspace_ids = HashSet::new();
    let mut emptied_existing_strips = HashSet::new();
    for (entity, mut strip, child, active) in &mut workspaces {
        if active {
            active_workspace_ids.insert(strip.id());
        }
        if let Some(child) = child {
            existing_workspace_parents
                .entry(strip.id())
                .or_insert_with(|| child.parent());
        }

        let had_consumed_window = plan
            .consumed_entities
            .iter()
            .any(|entity| strip.contains(*entity));
        for entity in &plan.consumed_entities {
            strip.remove(*entity);
        }

        // Row 0 is the row every space is created with. Emptying it is normal
        // (its windows move onto the restored rows), but despawning it leaves
        // the space numbered from "2" with no row that any later switch or
        // reap path recreates, so it is kept and reused instead.
        if had_consumed_window && strip.all_windows().is_empty() && strip.virtual_index > 0 {
            emptied_existing_strips.insert(entity);
        }
    }

    for entity in &emptied_existing_strips {
        if let Ok(mut entity_commands) = ctx.commands.get_entity(*entity) {
            entity_commands.try_despawn();
        }
    }

    for entity in &plan.consumed_entities {
        if let Ok(mut entity_commands) = ctx.commands.get_entity(*entity) {
            entity_commands
                .try_remove::<Unmanaged>()
                .try_insert(super::floating::RestoredFloatPolicy)
                .try_remove::<super::floating::FloatRecheck>();
        }
    }

    let mut restored_strips = 0;
    for planned in &plan.strips {
        let Some((display_entity, display)) = select_display(
            planned.workspace_id,
            planned.display_id,
            &existing_workspace_parents,
            &displays,
        ) else {
            warn!(
                "Skipping restore for workspace {} virtual {} because no display exists",
                planned.workspace_id, planned.virtual_index
            );
            continue;
        };

        let mut strip = layout_strip_from_plan(planned);
        if strip.all_windows().is_empty() {
            continue;
        }

        // Keep unmatched startup windows on the same normal row. Fullscreen
        // strips must remain single-column, so leave those rows separate.
        if !strip.is_fullscreen()
            && let Some((entity, mut existing, _, _)) =
                workspaces.iter_mut().find(|(entity, existing, _, _)| {
                    !emptied_existing_strips.contains(entity)
                        && existing.id() == planned.workspace_id
                        && existing.virtual_index == planned.virtual_index
                        && !existing.is_fullscreen()
                })
        {
            strip.append_strip(&mut existing);
            emptied_existing_strips.insert(entity);
            if let Ok(mut entity_commands) = ctx.commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
        }

        let is_active = plan
            .active_virtual_by_workspace
            .get(&planned.workspace_id)
            .is_some_and(|active| *active == planned.virtual_index);
        let is_global_active = is_active && active_workspace_ids.contains(&planned.workspace_id);
        if is_active {
            for (entity, strip, _, _) in &mut workspaces {
                if strip.id() == planned.workspace_id
                    && !emptied_existing_strips.contains(&entity)
                    && is_global_active
                    && let Ok(mut entity_commands) = ctx.commands.get_entity(entity)
                {
                    entity_commands.try_remove::<ActiveWorkspaceMarker>();
                }
            }
        }

        for metadata in restoration.layout.columns.iter().filter(|m| {
            m.workspace_id == planned.workspace_id && m.virtual_index == planned.virtual_index
        }) {
            let members: Vec<_> = metadata
                .members
                .iter()
                .filter_map(|member| {
                    plan.matched_windows
                        .get(&member.window.hard_key())
                        .copied()
                        .filter(|e| strip.contains(*e))
                        .map(|e| (e, member))
                })
                .collect();
            let Some((top, _)) = members.first() else {
                continue;
            };
            if let Some(edge) = metadata.pinned {
                let width = metadata
                    .width_before_pin
                    .or_else(|| ctx.windows.size(*top).map(|s| s.x))
                    .unwrap_or(160);
                strip.restore_pin(*top, edge, width);
            }
            if metadata.tabbed && !strip.is_tabbed_display(*top) {
                strip.toggle_tabbed_display(*top);
            }
            let active = metadata
                .members
                .get(metadata.active)
                .and_then(|member| plan.matched_windows.get(&member.window.hard_key()))
                .copied()
                .filter(|e| strip.contains(*e))
                .unwrap_or(*top);
            strip.select_member(active);
            for (entity, member) in members {
                if metadata.pinned.is_none()
                    && let Some(width) = metadata
                        .width
                        .filter(|width| (1..=super::state::MAX_SAVED_COLUMN_WIDTH).contains(width))
                {
                    ctx.commands
                        .entity(entity)
                        .insert(RestoredColumnWidth(width));
                }
                if let Some(weight) = member.weight {
                    strip.set_row_weight(entity, weight);
                }
                if restoration
                    .layout
                    .boot_session
                    .as_deref()
                    .zip(super::state::boot_session())
                    .is_some_and(|(saved, current)| saved.eq_ignore_ascii_case(current))
                    && metadata.members.len() == 1
                    && !metadata.tabbed
                    && strip
                        .index_of(entity)
                        .and_then(|i| strip.get(i))
                        .is_ok_and(|column| matches!(column, Column::Single(_)))
                    && let Some(height) = member.kept_height.filter(|height| *height > 0)
                {
                    ctx.commands
                        .entity(entity)
                        .insert(super::oym_layout::KeptHeight(height));
                }
            }
        }

        let origin = if is_global_active {
            display.bounds().min
        } else {
            display.bounds().max - PARKED_STRIP_SLIVER
        };
        let previous = PreviousStripPosition {
            origin: display.bounds().min,
            focus: strip
                .all_columns()
                .first()
                .map(|top| strip.active_member(*top).unwrap_or(*top)),
        };
        let initial_focus = ctx
            .windows
            .focused()
            .map(|(_, entity)| entity)
            .filter(|entity| strip.contains(*entity))
            .map(|entity| strip.active_member(entity).unwrap_or(entity))
            .or(previous.focus);

        let mut spawned =
            ctx.commands
                .spawn_layout_strip(strip, origin, display_entity, is_global_active);

        if !is_global_active {
            spawned.insert(previous);
        } else if let Some(focus) = initial_focus {
            ctx.commands.focus_entity(focus, true);
        }
        restored_strips += 1;
    }

    info!(
        "Session restore applied: matched={}, strips={}, missing={}, ambiguous={}",
        plan.consumed_entities.len(),
        restored_strips,
        plan.ignored_missing_windows,
        plan.skipped_ambiguous_matches
    );
}

fn layout_strip_from_plan(planned: &PlannedStrip) -> LayoutStrip {
    if let [PlannedColumn::Fullscreen(entity)] = planned.columns.as_slice() {
        let mut strip = LayoutStrip::fullscreen(planned.workspace_id, *entity);
        strip.virtual_index = planned.virtual_index;
        return strip;
    }

    let mut strip = LayoutStrip::new(planned.workspace_id, planned.virtual_index);
    apply_planned_columns(&mut strip, &planned.columns);
    strip
}

fn current_window_identities(
    windows: &Windows,
    apps: &Query<&Application>,
    restoration: &PaneruState,
) -> Vec<CurrentWindowIdentity> {
    let mut current = windows
        .managed_iter()
        .filter_map(|(window, entity, child)| {
            let app = apps.get(child.parent()).ok()?;
            if app
                .bundle_id()
                .is_some_and(|id| id == "com.openyourmac.OpenYourMac")
            {
                return None;
            }
            Some(CurrentWindowIdentity {
                entity,
                window_id: window.id(),
                pid: window.pid().ok()?,
                bundle_id: app.bundle_id().unwrap_or_default().clone(),
                title: String::new(),
                identifier: String::new(),
                role: String::new(),
                subrole: String::new(),
            })
        })
        .collect::<Vec<_>>();

    if has_saved_fallback_windows(restoration) {
        let saved_hard_keys = saved_hard_match_keys(restoration);
        hydrate_fallback_identities(&mut current, windows, &saved_hard_keys);
    }

    current
}

fn hydrate_fallback_identities(
    current: &mut [CurrentWindowIdentity],
    windows: &Windows,
    saved_hard_keys: &HashSet<WindowHardMatchKey>,
) {
    for identity in current {
        if saved_hard_keys.contains(&identity.hard_key()) {
            continue;
        }
        let Some(window) = windows.get(identity.entity) else {
            continue;
        };
        identity.title = window.title().unwrap_or_default();
        if identity.title.is_empty() {
            continue;
        }
        identity.identifier = window.identifier().unwrap_or_default();
        identity.role = window.role().unwrap_or_default();
        identity.subrole = window.subrole().unwrap_or_default();
    }
}

fn select_display<'a>(
    workspace_id: WorkspaceId,
    planned_display_id: Option<CGDirectDisplayID>,
    existing_workspace_parents: &HashMap<WorkspaceId, Entity>,
    displays: &'a Query<(Entity, &Display, Has<ActiveDisplayMarker>)>,
) -> Option<(Entity, &'a Display)> {
    if let Some(display_entity) = existing_workspace_parents.get(&workspace_id)
        && let Ok((entity, display, _)) = displays.get(*display_entity)
    {
        let current_display_id = display.id();
        if planned_display_id.is_some_and(|display_id| display_id != current_display_id) {
            info!(
                "Session restore remapping workspace {} from saved display {:?} to current display {}",
                workspace_id, planned_display_id, current_display_id
            );
            return Some((entity, display));
        }
    }

    if let Some(display_id) = planned_display_id {
        if let Some((entity, display, _)) = displays
            .iter()
            .find(|(_, display, _)| display.id() == display_id)
        {
            return Some((entity, display));
        }
        info!(
            "Session restore remapping workspace {} from missing display {}",
            workspace_id, display_id
        );
    }

    if let Some(display_entity) = existing_workspace_parents.get(&workspace_id)
        && let Ok((entity, display, _)) = displays.get(*display_entity)
    {
        return Some((entity, display));
    }

    displays
        .iter()
        .find(|(_, _, active)| *active)
        .or_else(|| displays.iter().min_by_key(|(_, display, _)| display.id()))
        .map(|(entity, display, _)| (entity, display))
}

fn apply_planned_columns(strip: &mut LayoutStrip, columns: &[PlannedColumn]) {
    for column in columns {
        match column {
            PlannedColumn::Single(entity) | PlannedColumn::Fullscreen(entity) => {
                strip.append(*entity);
            }
            PlannedColumn::Tabs(entities) => {
                append_tabs(strip, entities);
            }
            PlannedColumn::Stack(items) => {
                append_stack(strip, items);
            }
        }
    }
}

fn append_tabs(strip: &mut LayoutStrip, entities: &[Entity]) -> Option<Entity> {
    let leader = *entities.first()?;
    strip.append(leader);
    for follower in &entities[1..] {
        _ = strip.convert_to_tabs(leader, *follower);
    }
    Some(leader)
}

fn append_stack(strip: &mut LayoutStrip, items: &[PlannedStackItem]) {
    let mut first = true;
    for item in items {
        let Some(leader) = append_stack_item(strip, item) else {
            continue;
        };
        if first {
            first = false;
        } else {
            _ = strip.stack(leader);
        }
    }
}

fn append_stack_item(strip: &mut LayoutStrip, item: &PlannedStackItem) -> Option<Entity> {
    match item {
        PlannedStackItem::Single(entity) => {
            strip.append(*entity);
            Some(*entity)
        }
        PlannedStackItem::Tabs(entities) => append_tabs(strip, entities),
    }
}

fn compact_entities(entities: Vec<Entity>) -> Option<PlannedColumn> {
    match entities.as_slice() {
        [] => None,
        [entity] => Some(PlannedColumn::Single(*entity)),
        _ => Some(PlannedColumn::Tabs(entities)),
    }
}

fn compact_stack_tabs(entities: Vec<Entity>) -> Option<PlannedStackItem> {
    match entities.as_slice() {
        [] => None,
        [entity] => Some(PlannedStackItem::Single(*entity)),
        _ => Some(PlannedStackItem::Tabs(entities)),
    }
}

fn compact_stack_items(items: Vec<PlannedStackItem>) -> Option<PlannedColumn> {
    match items.as_slice() {
        [] => None,
        [PlannedStackItem::Single(entity)] => Some(PlannedColumn::Single(*entity)),
        [PlannedStackItem::Tabs(entities)] => Some(PlannedColumn::Tabs(entities.clone())),
        _ => Some(PlannedColumn::Stack(items)),
    }
}
