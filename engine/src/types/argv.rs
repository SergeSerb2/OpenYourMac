//! The argv encoding of a [`Command`]: `["window", "focus", "east"]`.
//!
//! This is the wire format of the `send-cmd` socket protocol and the shape the
//! TOML `[bindings]` keys are split into, so parsing and formatting live
//! together here and are checked against each other by round-trip tests.

use crate::types::commands::{
    Command, Direction, Edge, MouseMove, MoveFocus, Operation, ResizeDirection,
    parse_virtual_workspace_number,
};

/// Why an argv vector is not a command. Consumers wrap this in their own error
/// type; the message is already user-facing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError(String);

impl ParseError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }

    fn invalid(argv: &[&str]) -> Self {
        Self(format!("invalid command '{argv:?}'"))
    }
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ParseError {}

type Result<T> = std::result::Result<T, ParseError>;

/// Parses a command argument vector into a [`Command`] (e.g. `["window",
/// "focus", "east"]`).
///
/// # Errors
///
/// Returns [`ParseError`] if `argv` is not a recognized command encoding.
pub fn parse_command(argv: &[&str]) -> Result<Command> {
    Ok(match argv {
        ["printstate"] => Command::PrintState,
        ["window", operation @ ..] => Command::Window(parse_operation(operation)?),
        ["mouse", operation @ ..] => Command::Mouse(parse_mouse_move(operation)?),
        ["quit"] => Command::Quit,
        ["strip", "show"] => Command::ShowStrip,
        ["bindings", "pause"] => Command::PauseBindings(true),
        ["bindings", "resume"] => Command::PauseBindings(false),
        _ => {
            return Err(ParseError::new(format!(
                "invalid command or unexpected arguments '{argv:?}'"
            )));
        }
    })
}

/// Parses a window operation (e.g. `["focus", "east"]`).
fn parse_operation(argv: &[&str]) -> Result<Operation> {
    let command = *argv.first().unwrap_or(&"");
    if !valid_operation_arity(argv) {
        return Err(ParseError::new(format!(
            "invalid window command or unexpected arguments '{argv:?}'"
        )));
    }
    let err = || ParseError::invalid(argv);
    let argument = || argv.get(1).ok_or_else(err).copied();

    Ok(match command {
        // The bindings key splits on `_`, so `window_focus_unmanaged` arrives
        // here as ["focus", "unmanaged"] and the suffix tells us the variant.
        "focus" => match argument()? {
            "unmanaged" => Operation::FocusUnmanaged,
            "managed" => Operation::FocusManaged,
            direction => Operation::Focus(Direction::parse_positional(direction)?),
        },
        "raise" => match argument()? {
            "floating" => Operation::RaiseFloating,
            _ => return Err(err()),
        },
        "togglefloatlayer" => Operation::ToggleFloatingLayer,
        "swap" => Operation::Swap(Direction::parse_positional(argument()?)?),
        "consume" => Operation::Consume(Direction::parse_positional(argument()?)?),
        "expel" => Operation::Expel(Direction::parse_positional(argument()?)?),
        "pin" => Operation::Pin(match argv.get(1).copied() {
            None | Some("left" | "west") => Edge::Left,
            Some("right" | "east") => Edge::Right,
            _ => return Err(err()),
        }),
        "wider" => Operation::AdjustWidth(0.05),
        "narrower" => Operation::AdjustWidth(-0.05),
        "taller" => Operation::AdjustHeight(0.1),
        "shorter" => Operation::AdjustHeight(-0.1),
        "center" => Operation::Center,
        "resize" => Operation::Resize(
            argv.get(1)
                .map_or(Ok(ResizeDirection::Grow), |arg| ResizeDirection::parse(arg))?,
        ),
        "grow" => Operation::Resize(ResizeDirection::Grow),
        "shrink" => Operation::Resize(ResizeDirection::Shrink),
        // `window_vertical_resize` / `_grow` / `_shrink`, plus the explicit
        // `window_vertical_resize_shrink` mirroring `window_resize_shrink`.
        "vertical" => Operation::ResizeVertical(match argv.get(1).copied() {
            None | Some("resize") => argv
                .get(2)
                .map_or(Ok(ResizeDirection::Grow), |arg| ResizeDirection::parse(arg))?,
            Some(arg) => ResizeDirection::parse(arg)?,
        }),
        "fullwidth" => Operation::FullWidth,
        "manage" => Operation::Manage,
        "equalize" => Operation::Equalize,
        "balance" => Operation::Balance,
        "stack" => Operation::Stack(true),
        "unstack" => Operation::Stack(false),
        "tabbed" | "tabbeddisplay" => Operation::ToggleTabbedDisplay,
        "nextdisplay" => Operation::ToNextDisplay(MoveFocus::Follow),
        "nextdisplaysend" => Operation::ToNextDisplay(MoveFocus::Stay),
        "snap" => Operation::Snap,
        "copyrule" => Operation::CopyRule,
        // The `virtual*` verbs take either a direction or a workspace number,
        // and `num` variants that only take a number.
        "virtual" => virtual_target(argument()?, Operation::Virtual, Operation::VirtualNumber)?,
        // No numeric form: "focus a stack neighbor, else switch" only makes
        // sense paired with a direction.
        "virtualfocus" => Operation::FocusOrVirtual(Direction::parse(argument()?)?),
        "virtualnum" => Operation::VirtualNumber(parse_virtual_workspace_number(argument()?)?),
        "virtualadd" => Operation::VirtualAdd,
        "virtualmove" => virtual_target(
            argument()?,
            |direction| Operation::VirtualMove(direction, MoveFocus::Follow),
            |index| Operation::VirtualMoveNumber(index, MoveFocus::Follow),
        )?,
        "virtualmovenum" => Operation::VirtualMoveNumber(
            parse_virtual_workspace_number(argument()?)?,
            MoveFocus::Follow,
        ),
        "virtualsend" => virtual_target(
            argument()?,
            |direction| Operation::VirtualMove(direction, MoveFocus::Stay),
            |index| Operation::VirtualMoveNumber(index, MoveFocus::Stay),
        )?,
        "virtualsendnum" => Operation::VirtualMoveNumber(
            parse_virtual_workspace_number(argument()?)?,
            MoveFocus::Stay,
        ),
        _ => return Err(err()),
    })
}

fn valid_operation_arity(argv: &[&str]) -> bool {
    matches!(
        argv,
        [
            "focus"
                | "raise"
                | "swap"
                | "consume"
                | "expel"
                | "virtual"
                | "virtualfocus"
                | "virtualnum"
                | "virtualmove"
                | "virtualmovenum"
                | "virtualsend"
                | "virtualsendnum"
                | "pin"
                | "resize"
                | "vertical",
            _
        ] | ["vertical", "resize", _]
            | ["togglefloatlayer"
                | "wider"
                | "narrower"
                | "taller"
                | "shorter"
                | "center"
                | "grow"
                | "shrink"
                | "fullwidth"
                | "manage"
                | "equalize"
                | "balance"
                | "stack"
                | "unstack"
                | "tabbed"
                | "tabbeddisplay"
                | "nextdisplay"
                | "nextdisplaysend"
                | "snap"
                | "copyrule"
                | "virtualadd"
                | "pin"
                | "resize"
                | "vertical"]
    )
}

/// Resolves a `virtual*` argument that may be a direction or a 1-based number.
fn virtual_target(
    target: &str,
    directional: impl Fn(Direction) -> Operation,
    numbered: impl Fn(u32) -> Operation,
) -> Result<Operation> {
    if target.starts_with(|c: char| c.is_ascii_digit() || c == '+' || c == '-') {
        Ok(numbered(parse_virtual_workspace_number(target)?))
    } else {
        Ok(directional(Direction::parse(target)?))
    }
}

/// Parses a mouse command (e.g. `["nextdisplay"]`).
fn parse_mouse_move(argv: &[&str]) -> Result<MouseMove> {
    match argv {
        ["nextdisplay"] => Ok(MouseMove::ToNextDisplay),
        _ => Err(ParseError::new(format!("invalid mouse command '{argv:?}'"))),
    }
}

impl Command {
    /// The argv encoding of this command, as understood by [`parse_command`].
    ///
    /// [`Command::Lua`] and [`Command::Layout`] have no encoding — they are
    /// only ever issued in-process — and yield `None`.
    #[must_use]
    pub fn to_argv(&self) -> Option<Vec<String>> {
        let argv = match self {
            Command::Window(operation) => {
                let mut argv = vec!["window".to_string()];
                argv.extend(operation.to_argv());
                argv
            }
            Command::Mouse(MouseMove::ToNextDisplay) => {
                vec!["mouse".to_string(), "nextdisplay".to_string()]
            }
            Command::Quit => vec!["quit".to_string()],
            Command::ShowStrip => vec!["strip".to_string(), "show".to_string()],
            Command::PauseBindings(paused) => vec![
                "bindings".to_string(),
                if *paused { "pause" } else { "resume" }.to_string(),
            ],
            Command::PrintState => vec!["printstate".to_string()],
            Command::Lua(_) | Command::Layout(_) => return None,
        };
        Some(argv)
    }
}

impl Operation {
    /// The argv tail following `window`, e.g. `["focus", "east"]`.
    fn to_argv(&self) -> Vec<String> {
        let owned = |args: &[&str]| args.iter().map(|arg| (*arg).to_string()).collect();
        match self {
            Operation::Focus(direction) => vec!["focus".to_string(), direction.token()],
            Operation::Swap(direction) => vec!["swap".to_string(), direction.token()],
            Operation::Pin(edge) => owned(&[
                "pin",
                match edge {
                    Edge::Left => "left",
                    Edge::Right => "right",
                },
            ]),
            Operation::Consume(direction) => vec!["consume".to_string(), direction.token()],
            Operation::Expel(direction) => vec!["expel".to_string(), direction.token()],
            Operation::AdjustWidth(delta) => {
                owned(&[if *delta >= 0.0 { "wider" } else { "narrower" }])
            }
            Operation::AdjustHeight(delta) => {
                owned(&[if *delta >= 0.0 { "taller" } else { "shorter" }])
            }
            Operation::Center => owned(&["center"]),
            Operation::Resize(direction) => owned(&["resize", direction.token()]),
            Operation::ResizeVertical(direction) => {
                owned(&["vertical", "resize", direction.token()])
            }
            // `SetWidth` comes from window rules, not from a command line; it has
            // no argv verb, so encode it as the equivalent full-width toggle.
            Operation::SetWidth(_) | Operation::FullWidth => owned(&["fullwidth"]),
            Operation::ToNextDisplay(MoveFocus::Follow) => owned(&["nextdisplay"]),
            Operation::ToNextDisplay(MoveFocus::Stay) => owned(&["nextdisplaysend"]),
            Operation::Equalize => owned(&["equalize"]),
            Operation::Balance => owned(&["balance"]),
            Operation::Manage => owned(&["manage"]),
            Operation::Stack(true) => owned(&["stack"]),
            Operation::Stack(false) => owned(&["unstack"]),
            Operation::ToggleTabbedDisplay => owned(&["tabbeddisplay"]),
            Operation::Snap => owned(&["snap"]),
            Operation::Virtual(direction) => vec!["virtual".to_string(), direction.token()],
            Operation::FocusOrVirtual(direction) => {
                vec!["virtualfocus".to_string(), direction.token()]
            }
            Operation::VirtualNumber(index) => {
                vec![
                    "virtualnum".to_string(),
                    (u64::from(*index) + 1).to_string(),
                ]
            }
            Operation::VirtualAdd => owned(&["virtualadd"]),
            Operation::VirtualMove(direction, MoveFocus::Follow) => {
                vec!["virtualmove".to_string(), direction.token()]
            }
            Operation::VirtualMove(direction, MoveFocus::Stay) => {
                vec!["virtualsend".to_string(), direction.token()]
            }
            Operation::VirtualMoveNumber(index, MoveFocus::Follow) => {
                vec![
                    "virtualmovenum".to_string(),
                    (u64::from(*index) + 1).to_string(),
                ]
            }
            Operation::VirtualMoveNumber(index, MoveFocus::Stay) => {
                vec![
                    "virtualsendnum".to_string(),
                    (u64::from(*index) + 1).to_string(),
                ]
            }
            Operation::FocusUnmanaged => owned(&["focus", "unmanaged"]),
            Operation::FocusManaged => owned(&["focus", "managed"]),
            Operation::RaiseFloating => owned(&["raise", "floating"]),
            Operation::ToggleFloatingLayer => owned(&["togglefloatlayer"]),
            Operation::CopyRule => owned(&["copyrule"]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(command: &Command) -> Command {
        let argv = command.to_argv().expect("command should encode to argv");
        let borrowed: Vec<&str> = argv.iter().map(String::as_str).collect();
        parse_command(&borrowed).unwrap_or_else(|err| panic!("re-parsing {argv:?}: {err}"))
    }

    #[test]
    fn every_operation_round_trips_through_argv() {
        let operations = [
            Operation::Focus(Direction::East),
            Operation::Focus(Direction::Nth(2)),
            Operation::Swap(Direction::West),
            Operation::Center,
            Operation::Resize(ResizeDirection::Shrink),
            Operation::ResizeVertical(ResizeDirection::Grow),
            Operation::ResizeVertical(ResizeDirection::Shrink),
            Operation::FullWidth,
            Operation::ToNextDisplay(MoveFocus::Follow),
            Operation::ToNextDisplay(MoveFocus::Stay),
            Operation::Equalize,
            Operation::Balance,
            Operation::Manage,
            Operation::Stack(true),
            Operation::Stack(false),
            Operation::ToggleTabbedDisplay,
            Operation::Snap,
            Operation::Virtual(Direction::First),
            Operation::FocusOrVirtual(Direction::North),
            Operation::FocusOrVirtual(Direction::South),
            Operation::VirtualNumber(2),
            Operation::VirtualMove(Direction::East, MoveFocus::Follow),
            Operation::VirtualMove(Direction::East, MoveFocus::Stay),
            Operation::VirtualMoveNumber(0, MoveFocus::Follow),
            Operation::VirtualMoveNumber(0, MoveFocus::Stay),
            Operation::FocusUnmanaged,
            Operation::FocusManaged,
            Operation::RaiseFloating,
            Operation::ToggleFloatingLayer,
            Operation::CopyRule,
        ];

        for operation in operations {
            let command = Command::Window(operation.clone());
            let reparsed = round_trip(&command);
            assert_eq!(
                format!("{reparsed:?}"),
                format!("{command:?}"),
                "argv round-trip changed {operation:?}"
            );
        }
    }

    #[test]
    fn global_commands_round_trip() {
        for command in [
            Command::Quit,
            Command::ShowStrip,
            Command::PrintState,
            Command::Mouse(MouseMove::ToNextDisplay),
        ] {
            assert_eq!(
                format!("{:?}", round_trip(&command)),
                format!("{command:?}")
            );
        }
    }

    #[test]
    fn lua_commands_have_no_argv_encoding() {
        assert!(Command::Lua(1).to_argv().is_none());
    }

    #[test]
    fn window_numbers_are_one_based() {
        assert_eq!(
            Direction::parse_positional("1"),
            Ok(Direction::Nth(0)),
            "the first window is number 1"
        );
        assert!(Direction::parse_positional("0").is_err());
    }

    #[test]
    fn invalid_commands_are_rejected() {
        assert!(parse_command(&["definitely", "not", "a", "command"]).is_err());
        assert!(parse_command(&["window", "focus"]).is_err());
        assert!(parse_command(&["window", "swap", "3"]).is_ok());
    }
}
