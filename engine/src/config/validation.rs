use super::{
    InitialWindowWidth, InnerConfig, MAX_DEFAULT_WORKSPACES, decorations::BorderRadiusOption,
};
use crate::errors::{Error, Result};

fn finite(name: &str, value: Option<f64>) -> Result<()> {
    if value.is_some_and(|value| !value.is_finite()) {
        return Err(Error::InvalidConfig(format!("{name} must be finite")));
    }
    Ok(())
}

fn color(name: &str, value: Option<&str>, alpha: bool) -> Result<()> {
    if let Some(value) = value {
        let hex = value.strip_prefix('#').unwrap_or(value);
        if !(hex.len() == 6 || (alpha && hex.len() == 8))
            || !hex.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(Error::InvalidConfig(format!(
                "{name}: invalid hex color {value:?}"
            )));
        }
    }
    Ok(())
}

fn radius(name: &str, value: Option<&BorderRadiusOption>) -> Result<()> {
    if let Some(BorderRadiusOption::Value(value)) = value {
        finite(name, Some(*value))?;
    }
    Ok(())
}

impl InnerConfig {
    pub(super) fn validate(&self) -> Result<()> {
        if self
            .default_workspaces
            .is_some_and(|count| count > MAX_DEFAULT_WORKSPACES)
        {
            return Err(Error::InvalidConfig(format!(
                "default_workspaces must not exceed {MAX_DEFAULT_WORKSPACES}"
            )));
        }
        self.validate_options()?;
        if let Some(swipe) = &self.swipe {
            finite("[swipe] sensitivity", swipe.sensitivity)?;
            finite("[swipe] deceleration", swipe.deceleration)?;
        }
        if let Some(decorations) = &self.decorations {
            for (name, general) in [
                ("active", &decorations.active),
                ("inactive", &decorations.inactive),
            ] {
                if let Some(general) = general {
                    if let Some(border) = &general.border {
                        let name = format!("[decorations.{name}.border]");
                        finite(&format!("{name} width"), border.width)?;
                        finite(&format!("{name} opacity"), border.opacity)?;
                        radius(&format!("{name} radius"), border.radius.as_ref())?;
                        color(&format!("{name} color"), border.color.as_deref(), false)?;
                    }
                    if let Some(dim) = &general.dim {
                        let name = format!("[decorations.{name}.dim]");
                        finite(&format!("{name} opacity"), dim.opacity.map(f64::from))?;
                        finite(
                            &format!("{name} opacity_night"),
                            dim.opacity_night.map(f64::from),
                        )?;
                        color(&format!("{name} color"), dim.color.as_deref(), false)?;
                    }
                }
            }
            if let Some(menu) = &decorations.menu {
                finite("[decorations.menu] angle", menu.angle)?;
                if let Some(indicator) = &menu.indicator {
                    finite(
                        "[decorations.menu.indicator] font_size",
                        indicator.font_size,
                    )?;
                }
                for value in menu
                    .colors
                    .iter()
                    .flatten()
                    .filter(|value| !value.is_empty())
                {
                    color("[decorations.menu] colors", Some(value), false)?;
                }
            }
        }
        for (name, params) in self.windows.iter().flatten() {
            let name = format!("[windows.{name}]");
            finite(&format!("{name} border_radius"), params.border_radius)?;
            if let Some(InitialWindowWidth::Ratio(width)) = params.width {
                finite(&format!("{name} width"), Some(width))?;
                if width <= 0.0 {
                    return Err(Error::InvalidConfig(format!(
                        "{name} width must be positive"
                    )));
                }
            }
            if params.grid.is_some() && params.grid_ratios().is_none() {
                return Err(Error::InvalidConfig(format!(
                    "{name} grid: expected cols:rows:x:y:w:h with finite positive dimensions/spans and placement inside the grid"
                )));
            }
        }
        Ok(())
    }
    fn validate_options(&self) -> Result<()> {
        let o = &self.options;
        for (name, value) in [
            ("gap_inner", o.gap_inner),
            ("gap_outer", o.gap_outer),
            ("animation_duration_ms", o.animation_duration_ms),
            ("animation_damping", o.animation_damping),
            ("animation_speed", o.animation_speed),
            ("focus_border_width", o.focus_border_width),
            ("focus_border_radius", o.focus_border_radius),
            ("dim_inactive_opacity", o.dim_inactive_opacity),
            ("sliver_height", o.sliver_height),
            ("border_opacity", o.border_opacity),
            ("border_width", o.border_width),
            ("swipe_sensitivity", o.swipe_sensitivity),
            ("swipe_deceleration", o.swipe_deceleration),
            ("window_hidden_ratio", o.window_hidden_ratio),
            (
                "dim_inactive_windows",
                o.dim_inactive_windows.map(f64::from),
            ),
        ] {
            finite(&format!("[options] {name}"), value)?;
        }
        radius("[options] border_radius", o.border_radius.as_ref())?;
        for (name, values) in [
            ("preset_column_widths", &o.preset_column_widths),
            ("preset_stack_heights", &o.preset_stack_heights),
        ] {
            for value in values {
                finite(&format!("[options] {name}"), Some(*value))?;
            }
        }
        if o.preset_stack_heights
            .iter()
            .any(|height| *height <= 0.0 || *height > 1.0)
        {
            return Err(Error::InvalidConfig(
                "[options] preset_stack_heights must be greater than 0 and at most 1".into(),
            ));
        }
        for (name, value, alpha) in [
            ("border_color", o.border_color.as_deref(), false),
            ("dim_inactive_color", o.dim_inactive_color.as_deref(), false),
            ("focus_border_color", o.focus_border_color.as_deref(), true),
            ("pinned_color", o.pinned_color.as_deref(), true),
        ] {
            color(&format!("[options] {name}"), value, alpha)?;
        }
        Ok(())
    }
}
