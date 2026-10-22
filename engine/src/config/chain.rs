//! Flat `ChainYourMac` options. Nested upstream tables take priority at the call
//! sites in config.rs; all product numeric fallbacks reject non-finite values.
use super::Config;
use crate::platform::Modifiers;
use tracing::warn;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CenterFocusedColumn {
    Never,
    OnOverflow,
    Always,
}

pub(super) fn finite(value: Option<f64>, fallback: f64, min: f64, max: f64) -> f64 {
    value
        .filter(|value| value.is_finite())
        .unwrap_or(fallback)
        .clamp(min, max)
}

fn rgba(input: Option<&str>, fallback: (f64, f64, f64, f64)) -> (f64, f64, f64, f64) {
    let Some(hex) = input.map(|s| s.trim().trim_start_matches('#')) else {
        return fallback;
    };
    if !matches!(hex.len(), 6 | 8) || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return fallback;
    }
    let Ok(rgb) = u32::from_str_radix(hex, 16) else {
        return fallback;
    };
    let (rgb, alpha) = if hex.len() == 8 {
        (rgb >> 8, f64::from(rgb & 255) / 255.0)
    } else {
        (rgb, 1.0)
    };
    (
        f64::from((rgb >> 16) & 255) / 255.0,
        f64::from((rgb >> 8) & 255) / 255.0,
        f64::from(rgb & 255) / 255.0,
        alpha,
    )
}

pub(super) fn scroll_modifier(input: &str) -> Option<Modifiers> {
    let value = input.trim().to_ascii_lowercase();
    if matches!(value.as_str(), "off" | "none" | "false") {
        return None;
    }
    let mut mask = Modifiers::empty();
    for term in value.split('+').map(str::trim) {
        mask |= match term {
            "alt" | "opt" | "option" | "⌥" => Modifiers::ALT,
            "shift" | "⇧" => Modifiers::SHIFT,
            "cmd" | "command" | "⌘" => Modifiers::CMD,
            "ctrl" | "control" | "⌃" => Modifiers::CTRL,
            _ => {
                warn!("invalid scroll_modifier {input:?}; using ctrl + alt");
                return Some(Modifiers::CTRL | Modifiers::ALT);
            }
        };
    }
    Some(mask)
}

// Accessors are part of the E2/E3 contract, including ones not consumed by E1.
#[allow(dead_code)]
impl Config {
    pub fn gap_inner(&self) -> f64 {
        finite(self.options().gap_inner, 8.0, 0.0, 64.0)
    }
    pub fn gap_outer(&self) -> f64 {
        finite(self.options().gap_outer, 8.0, 0.0, 64.0)
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    pub(super) fn default_outer_padding(&self) -> u16 {
        self.gap_outer().round() as u16
    }
    /// `WindowOS` surrounds each member on both sides, so each side gets half
    /// `gap_inner`. Adjacent members contribute a full gap; explicit rule padding
    /// still specifies the per-side amount. E3 can refine edge compensation.
    pub fn default_window_padding(&self) -> i32 {
        crate::util::round_px(self.gap_inner() / 2.0)
    }
    pub fn dock_aware(&self) -> bool {
        self.options().dock_aware.unwrap_or(true)
    }
    /// E2 wires centering during navigation and swipe settling.
    pub fn center_focused_column(&self) -> CenterFocusedColumn {
        match self
            .options()
            .center_focused_column
            .as_deref()
            .unwrap_or("never")
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "always" => CenterFocusedColumn::Always,
            "on-overflow" | "on_overflow" | "overflow" => CenterFocusedColumn::OnOverflow,
            _ => CenterFocusedColumn::Never,
        }
    }
    /// E2 captures and applies original/manual lone-window heights.
    pub fn keep_window_height(&self) -> bool {
        self.options().keep_window_height.unwrap_or(false)
    }
    /// E2 applies free versus aligned swipe settling. Exact lowercase free only.
    pub fn swipe_snap(&self) -> bool {
        self.options()
            .swipe_snap
            .as_deref()
            .unwrap_or("snap")
            .trim()
            != "free"
    }
    pub fn animation_duration_ms(&self) -> f64 {
        let options = self.options();
        let mode = match options.animation.as_deref().unwrap_or("smooth").trim() {
            "instant" => 0.0,
            "fast" => 140.0,
            _ => 222.0,
        };
        finite(
            options
                .animation_duration_ms
                .filter(|value| value.is_finite())
                .or(options.animation_speed),
            mode,
            0.0,
            2000.0,
        )
    }
    pub fn animation_damping(&self) -> f64 {
        finite(self.options().animation_damping, 1.0, 0.4, 1.5)
    }
    pub fn focus_border_color(&self) -> (f64, f64, f64, f64) {
        rgba(
            self.options().focus_border_color.as_deref(),
            (247.0 / 255.0, 160.0 / 255.0, 40.0 / 255.0, 1.0),
        )
    }
    pub fn focus_border_width(&self) -> f64 {
        finite(self.options().focus_border_width, 2.0, 1.0, 12.0)
    }
    pub fn focus_border_radius(&self) -> f64 {
        finite(self.options().focus_border_radius, 10.0, 0.0, 40.0)
    }
    /// E3 draws the line and minimap pin using this RGBA color.
    pub fn pinned_color(&self) -> (f64, f64, f64, f64) {
        rgba(
            self.options().pinned_color.as_deref(),
            (76.0 / 255.0, 154.0 / 255.0, 1.0, 1.0),
        )
    }
    /// E3 controls automatic minimap visibility.
    pub fn minimap(&self) -> bool {
        self.options().minimap.unwrap_or(true)
    }
    /// E3 wires minimap hold, clicks and drag hit testing.
    pub fn strip_indicator_interactive(&self) -> bool {
        self.options().strip_indicator_interactive.unwrap_or(true)
    }
    /// E3 controls pin visuals independently from E2 pin layout.
    pub fn pin_indicator(&self) -> bool {
        self.options().pin_indicator.unwrap_or(true)
    }
    /// E3 wires real-window and minimap drag reorder.
    pub fn drag_reorder(&self) -> bool {
        self.options().drag_reorder.unwrap_or(true)
    }
    /// E3 wires custom tab-strip click interception.
    pub fn tab_bar_clicks(&self) -> bool {
        self.options().tab_bar_clicks.unwrap_or(true)
    }
    /// E3 wires custom tab-strip title labels.
    pub fn tab_bar_titles(&self) -> bool {
        self.options().tab_bar_titles.unwrap_or(true)
    }
    /// E3 wires dialog/preview AX heuristics, respecting explicit tile rules.
    pub fn float_dialogs(&self) -> bool {
        self.options().float_dialogs.unwrap_or(true)
    }
    /// E3 rechecks default/dialog floating; never overrides user floating.
    pub fn float_recheck(&self) -> bool {
        self.options().float_recheck.unwrap_or(true)
    }
    /// E3 gates automatic native-fullscreen exits.
    pub fn exit_native_fullscreen(&self) -> bool {
        self.options().exit_native_fullscreen.unwrap_or(false)
    }
    /// E3 gates the SLS bounds/liveness fast path; other SLS uses remain.
    pub fn use_skylight(&self) -> bool {
        self.options().use_skylight.unwrap_or(true)
    }
    /// E2 matches display UUID strings, not numeric CoreGraphics display IDs.
    pub fn ignored_displays(&self) -> Vec<String> {
        self.options()
            .ignored_displays
            .unwrap_or_default()
            .into_iter()
            .map(|id| id.trim().to_ascii_lowercase())
            .collect()
    }
    /// E2 applies ignored-display policy when joining/moving windows.
    pub fn display_ignored(&self, uuid: &str) -> bool {
        self.ignored_displays()
            .iter()
            .any(|id| id.eq_ignore_ascii_case(uuid.trim()))
    }
    pub fn detailed_logging(&self) -> bool {
        self.options().detailed_logging.unwrap_or(false)
    }
}
