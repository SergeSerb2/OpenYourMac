use std::fs;
use std::path::Path;

use std::process::Command;

use cfg_if::cfg_if;

macro_rules! lua_version_cfg_if {
    ( $( $feat:literal => $ver:literal ),+ $(,)? ) => {
        cfg_if! {
            $(
                if #[cfg(feature = $feat)] {
                    pub(crate) const LUA_VERSION: &'static str = $ver;
                } else
            )+
            {
                pub(crate) const LUA_VERSION: &'static str = "unknown";
            }
        }
    };
}

lua_version_cfg_if!(
    "lua54" => "Lua 5.4",
    "lua53" => "Lua 5.3",
    "lua55" => "Lua 5.5",
    "lua52" => "Lua 5.2",
    "luajit" => "LuaJIT",
);

fn main() {
    println!("cargo:rerun-if-changed=../VERSION");
    let version = fs::read_to_string("../VERSION").expect("OpenYourMac VERSION");
    let version = version.trim();
    assert!(
        version.split('.').count() == 3
            && version
                .split('.')
                .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())),
        "VERSION must contain a three-part version, such as 1.0.0"
    );
    println!("cargo:rustc-env=OPENYOURMAC_VERSION={version}");
    println!("cargo:rerun-if-changed=assets/Info.plist");
    let plist = fs::read_to_string("assets/Info.plist").expect("engine Info.plist template");
    let plist = plist.replace("@OPENYOURMAC_VERSION@", version);
    fs::write(
        Path::new(&std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("Info.plist"),
        plist,
    )
    .expect("generated engine Info.plist");
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    println!("cargo:rerun-if-env-changed=SDKROOT");
    let sdk = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        .unwrap_or_else(|err| sdk_error(&err.to_string()));
    if !sdk.status.success() {
        sdk_error(String::from_utf8_lossy(&sdk.stderr).trim());
    }
    let base = String::from_utf8(sdk.stdout).unwrap_or_else(|err| sdk_error(&err.to_string()));
    let base = base.trim();
    if !Path::new(base).is_dir() {
        sdk_error("xcrun did not return an SDK directory");
    }
    for suffix in [
        "System/Library/PrivateFrameworks",
        "System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks",
    ] {
        let path = Path::new(base).join(suffix);
        if path.exists() {
            println!("cargo:rustc-link-search=framework={}", path.display());
        }
    }

    if cfg!(feature = "lua") || cfg!(feature = "module") {
        println!("cargo:rustc-env=PANERU_LUA_VERSION={LUA_VERSION}");
    }

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-cdylib-link-arg=-undefined");
        println!("cargo:rustc-cdylib-link-arg=dynamic_lookup");
    }
}

fn sdk_error(detail: &str) -> ! {
    eprintln!(
        "error: cannot locate the macOS SDK: {detail}. Install Xcode or Command Line Tools and check DEVELOPER_DIR or xcode-select."
    );
    std::process::exit(1);
}
