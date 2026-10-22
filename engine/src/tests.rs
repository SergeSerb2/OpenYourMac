mod display;
mod focus_or_virtual;
mod harness;
mod interaction;
mod mocks;
mod session_restore;
mod state;
mod tabbed_display;
mod tabs;
mod tiling;

pub(crate) use harness::*;
pub(crate) use mocks::*;

pub(crate) const TEST_PROCESS_ID: i32 = 1;
pub(crate) const TEST_DISPLAY_ID: u32 = 1;
pub(crate) const TEST_WORKSPACE_ID: u64 = 2;
pub(crate) const TEST_DISPLAY_WIDTH: i32 = 1024;
pub(crate) const TEST_DISPLAY_HEIGHT: i32 = 768;

pub(crate) const EXT_DISPLAY_ID: u32 = 2;
pub(crate) const EXT_WORKSPACE_ID: u64 = 20;
pub(crate) const EXT_DISPLAY_WIDTH: i32 = 1920;
pub(crate) const EXT_DISPLAY_HEIGHT: i32 = 1200;

pub(crate) const TEST_MENUBAR_HEIGHT: i32 = 20;
pub(crate) const TEST_WINDOW_WIDTH: i32 = 400;
pub(crate) const TEST_WINDOW_HEIGHT: i32 = 1000;

#[allow(unused_imports)]
use crate::events::Event;
#[allow(unused_imports)]
use crate::manager::Window;
#[allow(unused_imports)]
use crate::platform::WorkspaceId;

/// Existing upstream layout fixtures use zero gaps, mouse focus and immediate
/// movement. Keep those choices explicit after the product defaults change.
pub(crate) fn upstream_options() -> crate::config::MainOptions {
    crate::config::MainOptions {
        gap_inner: Some(0.0),
        gap_outer: Some(0.0),
        focus_follows_mouse: Some(true),
        mouse_follows_focus: Some(true),
        animation: Some("instant".to_string()),
        swipe_sensitivity: Some(0.35),
        swipe_snap: Some("free".to_string()),
        ..Default::default()
    }
}
