# Optional upstream Lua support

Lua is not included in the OpenYourMac app or its shipped engine.
`scripts/build-app.sh` uses `--no-default-features`. Use
[OpenYourMac TOML](CONFIGURATION.md), the
[CLI and URL actions](../README.md#automation), or
[query/subscription interfaces](QUERY_AND_SUBSCRIBE_FORMAT.md) for the product.

This source tree retains Paneru's optional Lua implementation under `src/lua/`.
Cargo's default feature set enables it. That build can discover `PANERU_LUA`,
`~/.paneru.lua`, or XDG `paneru/init.lua`; a discovered script replaces TOML
configuration in that optional profile. These are not OpenYourMac app settings
or supported bundled scripting entry points.

Contributors retain a default-feature compile check for upstream source
compatibility. Do not distribute that build as the no-Lua product or assume its
startup/config behavior matches the app. Read [AGENTS.md](AGENTS.md) before running
any binary. The same Accessibility and real-window safety rules apply.
