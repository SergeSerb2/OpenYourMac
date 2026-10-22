# OpenYourMac engine

This directory is OpenYourMac's fork of
[Paneru v0.5.2](https://github.com/karinushka/paneru), by Karinushka. It keeps
Paneru's Rust window-management base and MIT license. The Cargo package and
library still use the name `paneru`.

The fork adds app supervision, OpenYourMac config and service paths, a shared
command parser, and the product's layout, pin, minimap, and settings behavior.
It runs as a child of the SwiftUI app rather than as a separately installed
Paneru service. Do not install upstream Paneru to run this app.

## Build and runtime

From the repository root:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --no-default-features --manifest-path engine/Cargo.toml
```

This produces `engine/target/debug/openyourmac-engine`. The app bundle script
builds the selected profile and copies the executable to
`OpenYourMac.app/Contents/Resources/OpenYourMacEngine`. The app starts it with
`launch` and sends window commands with `send-cmd`.

The shipped build has no Lua runtime. Cargo's default features include optional
upstream Lua support; always use `--no-default-features` for the product profile.
See [SCRIPTING.md](SCRIPTING.md) for that distinction.

Do not launch a window-managing engine on your everyday desktop for a test.
Read [the safety rules](AGENTS.md) and the
[manual test guide](../docs/manual-testing.md) first. For a safe config check:

```sh
engine/target/debug/openyourmac-engine check-config resources/default-config.toml
```

## Documentation

- [App install, permissions, shortcuts, and uninstall](../README.md)
- [Contributing and existing checks](../CONTRIBUTING.md)
- [App and engine architecture](../docs/architecture.md)
- [Engine architecture](ARCHITECTURE.md)
- [Configuration](CONFIGURATION.md)
- [Queries, subscriptions, and IPC](QUERY_AND_SUBSCRIBE_FORMAT.md)

## License

Paneru is MIT-licensed. Its original notice is in [LICENSE.txt](LICENSE.txt).
The project license is in [../LICENSE](../LICENSE), with bundled dependency
notices in [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
