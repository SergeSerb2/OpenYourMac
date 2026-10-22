# OpenYourMac configuration

This guide describes the shipped TOML profile. The bundled engine has no Lua
runtime. Start with [resources/default-config.toml](../resources/default-config.toml)
and the app's main controls. This page covers selected file-only options and
compatibility priorities; it is not a complete schema for all retained upstream
features.

## File discovery and validation

The app creates and edits `~/.config/openyourmac/openyourmac.toml`. It always
passes that path to its child. The engine chooses its TOML path in this order:

1. `--config <path>` on the engine command line.
2. `OPENYOURMAC_CONFIG` in the engine environment.
3. `$HOME/.config/openyourmac/openyourmac.toml`.

An override remains authoritative even when the file is missing. The no-Lua
engine does not discover `~/.paneru`, `PANERU_CONFIG`, or Lua init files.
A missing config uses embedded product defaults at runtime. A valid reload
replaces the active config; a failed reload keeps the previous config.

Validate a file without managing windows, from the repository root:

```sh
engine/target/debug/openyourmac-engine check-config resources/default-config.toml
```

An explicit missing file or a type/parse error fails validation. A missing implicit
default path reports that built-in defaults apply. Read warnings too: an
unresolved binding can be skipped while `check-config` still exits successfully.

## Main settings

These keys belong in `[options]`. Values below are the shipped template values.
Lengths use logical screen points, not backing pixels. The app offers a subset
of the engine's file ranges.

| Keys | Shipped value or behavior |
| --- | --- |
| `focus_follows_mouse`, `mouse_follows_focus` | Both `false`. |
| `session_restore`, `native_tabs`, `float_dialogs` | All `true`. |
| `ignored_displays` | `[]`; entries are display UUID strings. |
| `preset_column_widths` | `[0.25, 0.33, 0.5, 0.66, 0.75]`, in cycle order. |
| `gap_inner`, `gap_outer` | Both `8`; file values clamp to 0–64 points. |
| `dock_aware` | `true`; reserve Dock space. |
| `center_focused_column` | `"never"`; also `"on-overflow"` or `"always"`. |
| `keep_window_height` | `false`; retain lone-window height when enabled. |
| `animation` | `"smooth"`; also `"fast"` or `"instant"`. |
| `focus_border` | `false`. |
| `focus_border_width`, `focus_border_radius` | `2` and `10` points; file ranges 1–12 and 0–40. |
| `focus_border_color` | `"#F7A028"`. |
| `dim_inactive`, `dim_inactive_opacity` | `false` and `0.25`; opacity clamps to 0–0.9. |
| `minimap`, `strip_indicator_interactive`, `pin_indicator` | All `true`. |
| `swipe_gesture_fingers` | `4`; `0` disables; the engine also accepts `3` and `5`. |
| `swipe_natural`, `swipe_snap` | `true` and `"snap"`; `"free"` disables settling to column alignment. |
| `drag_reorder` | `true`. |
| `scroll_modifier` | `"ctrl + alt"`; `"off"` disables modifier scrolling. |

## Bindings

Bindings map action names to a string or an array of alternative chords:

```toml
[bindings]
window_focus_west = ["ctrl + alt - leftarrow", "ctrl + alt - h"]
window_swap_9 = "ctrl + alt + shift - 9"
```

Use lowercase modifier and key names. Common modifiers are `ctrl`, `alt`, `cmd`,
and `shift`. The engine splits the binding name into command words. For example,
`window_focus_west` becomes `window focus west`. Unknown actions and key names
can produce warnings. Check the file with the real engine after editing.

Numbered focus and swap actions address columns 1–8. Focus selects the top member
of that column; swap moves the whole column. Number 9 means the last column,
even when there are more than nine. See [default shortcuts](../README.md#default-shortcuts).

## Window rules

Use explicit `[windows.<name>]` tables for rules you want the app to display and
edit. `bundle_id` matches an exact application ID. `title` is a Rust regular
expression, defaulting to all titles. When both are present, both must match.
Do not depend on an order between overlapping rules with conflicting values.

```toml
[windows.example]
bundle_id = "com.example.App"
title = "^Preview"
floating = false
horizontal_padding = 4
vertical_padding = 4
```

| Key | Behavior |
| --- | --- |
| `floating` | Omit for normal heuristics; `true` floats, `false` requests tiling. |
| `manage` | Force management when `true`, including otherwise unobservable windows. |
| `index` | Preferred column position, zero-based in the file. |
| `horizontal_padding`, `vertical_padding` | Signed integer points on each side of a tiled window. Parsing accepts negative values, but the engine clamps applied padding to 0–64. Omitted values use normal inner-gap padding. These are file-only controls. |
| `dont_focus` | Request that admission does not take focus. |
| `width` | Positive initial display-width ratio, or `"complement_focused"`. Ratios above 1 can create an oversized column. |
| `grid` | Floating placement string `"cols:rows:x:y:w:h"`. |
| `border_radius` | Per-window active-border radius override. |
| `bindings_passthrough` | Array of chords passed through to this app. |

Some file-only rule fields and dotted/inline TOML forms have no equivalent editor
control. The editor is not a complete view of all accepted engine rules. Verify
hand edits with `check-config` and check the real result in an isolated session.
OpenYourMac's own windows and attached sheets have special handling; a rule is
not a promise to tile those windows.

## Additional file-only options

These `[options]` keys are accepted beyond the main template:

| Keys | Effective default or role |
| --- | --- |
| `animation_duration_ms`, `animation_speed` | Explicit duration, then legacy duration alias, then mode. Smooth = 222 ms, fast = 140 ms, instant = 0 ms; clamp 0–2000. |
| `animation_damping` | `1.0`, clamp 0.4–1.5. Multiplies exponential movement decay rate; it is not spring damping. |
| `pinned_color` | `"#4C9AFF"`; pin indicator color. |
| `tab_bar_clicks`, `tab_bar_titles` | Both `true`. |
| `float_recheck` | `true`; recheck automatic floating policy. |
| `detailed_logging` | `false`; logs can include window titles. |
| `continuous_swipe` | `false`; `true` extends scroll edge limits instead of the normal edge-window clamp. `[swipe].continuous` takes priority. |
| `swipe_sensitivity` | `1.6`, clamp 0.2–5.0. |
| `swipe_deceleration` | `4.0`, clamp 1–10. |
| `preset_stack_heights` | `[0.25, 0.33333, 0.5, 0.66667, 0.75]` for vertical preset resizing. |
| `window_resize_cycle` | `true`; preset grow/shrink wraps at the ends. |
| `window_hidden_ratio` | `0.0`, clamp 0–1; tolerated hidden fraction before revealing focus. |
| `auto_center` | `false`; retained centering behavior that can override the flat centering mode. |
| `sliver_height`, `sliver_width` | `1.0` of display height and `5` points for offscreen slivers. |
| `exit_native_fullscreen`, `use_skylight` | Accepted compatibility fields without an active product toggle implementation. Do not rely on them to change fullscreen or platform access. |

Color strings for `focus_border_color` and `pinned_color` are hex RGB
(`#RRGGBB`) or RGBA (`#RRGGBBAA`). An omitted color uses its default. A
malformed color makes the whole file invalid: the engine refuses to start with
it, and a hot reload keeps the previous config.

## Compatibility tables and priority

The engine retains additional Paneru fields. Prefer the main OpenYourMac keys
for new files. The app's flat controls may not reflect a nested or legacy
override, so inspect the file when a saved control has no visible effect.

| Higher-priority field | Lower-priority field or default |
| --- | --- |
| `[restore].enabled` | `[options].session_restore`, then `true`. |
| `[options].disable_native_tabs` | Inverse of `[options].native_tabs`, then enabled. |
| `[padding].top/right/bottom/left` | Corresponding `[options].padding_*`, then `gap_outer`. |
| `[swipe.gesture].fingers_count` | `swipe_gesture_fingers`, then `4`. |
| `[swipe.gesture].direction` | `swipe_gesture_direction` (`"Natural"`/`"Reversed"`), then `swipe_natural`. |
| `[swipe].continuous/sensitivity/deceleration` | Corresponding flat swipe option. |
| `[swipe.scroll].modifier` | `scroll_modifier`, then `"ctrl + alt"`. |
| `[decorations.active.border]` fields | Legacy `border_*` fields, then `focus_border*` values. |
| `[decorations.inactive.dim]` fields | Legacy `dim_inactive_*` color/opacity fields, then flat dim controls, as selected by the dimming mode. |

Screen-edge padding fields are unsigned integers; per-window padding is signed.
`[restore].startup_grace_ms` defaults to `2000` and `missing_windows` accepts
`"ignore"`. `[swipe.scroll].window_step` defaults to `true`. Product gestures
remain horizontal; retained `vertical` and `vertical_modifier` fields do not
enable gesture-based workspace-row changes.

Further retained fields include mouse warp/resize modifiers, menubar geometry,
virtual-workspace behavior, and upstream decoration/menu tables. Accepted fields
can be inactive in the supervised product. The parser structs and effective
accessors in [src/config.rs](src/config.rs),
[src/config/chain.rs](src/config/chain.rs), and [src/config/](src/config/) are the
source of truth for that compatibility surface. Parsing a value alone does not
prove it changes window behavior.
