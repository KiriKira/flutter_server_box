//! Android shell commands and parsers shared by the UI and AI tools.
//! No transport or platform IO: all untrusted arguments are quoted here.
use std::collections::HashMap;
use serde_json::{json, Value};

fn quote(value: &str) -> String { format!("'{}'", value.replace('\'', "'\\''")) }

pub fn exec_command(script: &str, entry: Option<&str>, env: &HashMap<String, String>) -> Result<String, String> {
    if script.contains('\0') { return Err("NUL in command".into()); }
    let mut prefix = String::new();
    for (key, value) in env {
        if key.is_empty() || !key.bytes().enumerate().all(|(i, c)| c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit())) {
            return Err("Invalid environment name".into());
        }
        prefix.push_str(&format!("export {key}={}; ", quote(value)));
    }
    Ok(match entry { Some(entry) => format!("{prefix}{entry}"), None => format!("{prefix}sh -c {}", quote(script)) })
}

const STATUS: &[(&str, &str)] = &[
    ("identity", "id"),
    ("props", "getprop"),
    ("cpu", "cat /proc/stat"),
    ("cpuinfo", "dumpsys cpuinfo | tail -n 1"),
    ("mem", "cat /proc/meminfo"),
    ("disk", "df -k /data"),
    ("net", "cat /proc/net/dev"),
    ("batteryInfo", "dumpsys battery"),
    ("uptime", "uptime"),
    ("kernel", "uname -r"),
    ("addresses", "ip -o addr show"),
];

const KEYGUARD_FIELDS: &str = "showing|secure|occluded|screenState|interactiveState";

/// Typed into an unlocked phone, a secret (and the Enter or drag after it) would land in
/// whatever app has focus; so unlocking stops unless the keyguard is showing.
const LOCKED_ONLY: &str = "dumpsys window policy | grep -qE '^ *showing=true' || { echo 'The target is not on its lock screen; nothing was entered.'; exit 3; }; ";

/// Screen-control quality presets: (max dimension, max fps, video bit rate).
/// Lower presets keep a remote link (VPN relay, mobile data) from queuing seconds of video.
pub fn scrcpy_quality(name: &str) -> Result<(u32, u32, u32), String> {
    Ok(match name {
        "high" => (1280, 60, 8_000_000),
        "balanced" => (1024, 30, 2_500_000),
        "smooth" => (720, 30, 1_000_000),
        "saver" => (540, 20, 500_000),
        _ => return Err("Unknown scrcpy quality".into()),
    })
}

pub fn command(action: &str, argument: &str, root: bool) -> Result<String, String> {
    if argument.contains('\0') { return Err("NUL in Android argument".into()); }
    let cmd = match action {
        "status" => STATUS.iter().map(|(key, cmd)| format!("printf '\\n__SB_ADB_{key}__\\n'; ({cmd}) 2>&1\n")).collect::<String>() + "\ntrue\n",
        "root_probe" => "if [ \"$(id -u)\" = 0 ]; then true; else su -c 'test \"$(id -u)\" = 0'; fi".into(),
        "apps" => "pm list packages --user 0 -f --show-versioncode".into(),
        "verify_install" => format!("pm list packages --user 0 --show-versioncode {}", quote(argument)),
        "screenshot" => "screencap -p".into(),
        "app_info" => format!("dumpsys package {}", quote(argument)),
        "launch" => format!("monkey -p {} -c android.intent.category.LAUNCHER 1", quote(argument)),
        "stop" => format!("am force-stop --user 0 {}", quote(argument)),
        "uninstall" => format!("pm uninstall --user 0 {}", quote(argument)),
        "clear" => format!("pm clear --user 0 {}", quote(argument)),
        "install" => format!("pm install --user 0 -r {}", quote(argument)),
        "remove_temp" => {
            if !argument.starts_with("/data/local/tmp/serverbox-") || argument[17..].contains('/') { return Err("Not a ServerBox temporary file".into()); }
            format!("rm -f {}", quote(argument))
        }
        "logcat" => "logcat -d -t 500 -v threadtime".into(),
        "reboot" => "reboot".into(),
        "identity" => "id".into(),
        "guid" => "getprop persist.adb.wifi.guid".into(),
        "screen_wake" => "input keyevent 224 && wm dismiss-keyguard".into(),
        // Shown as-is in screen control's diagnostics: is the target's display on, and locked?
        // KeyguardServiceDelegate's dump (`dumpsys window policy`) has carried these for years.
        "screen_state" => format!("dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+'; dumpsys window policy | grep -E '^ *({KEYGUARD_FIELDS})=' | sed 's/^ *//'; true"),
        // Types a lock-screen PIN or password over ADB, for a target nobody can reach by hand.
        // Only while the keyguard is showing: typed into an unlocked phone, the secret and the
        // Enter after it would land in whatever text field has focus.
        "unlock_secret" => {
            if argument.is_empty() || argument.len() > 64 || !argument.bytes().all(|b| b.is_ascii_graphic() && b != b'%') {
                return Err("The PIN or password must be 1-64 printable ASCII characters without spaces or %".into());
            }
            format!("{LOCKED_ONLY}input keyevent 224; wm dismiss-keyguard; sleep 1; input text {}; input keyevent 66", quote(argument))
        }
        // Draws a pattern given as keypad digits (1 top-left .. 9 bottom-right). The bouncer is a
        // secure window, black in the mirrored video, but uiautomator still reports where the
        // pattern view is, so the dots' centres follow from its bounds whatever the device.
        "unlock_pattern" => {
            let mut seen = [false; 10];
            let valid = (4..=9).contains(&argument.len()) && argument.bytes().all(|b| {
                let d = (b as char).to_digit(10).unwrap_or(0) as usize;
                (1..=9).contains(&d) && !std::mem::replace(&mut seen[d], true)
            });
            if !valid { return Err("A pattern is 4-9 different digits 1-9, numbered like a phone keypad".into()); }
            format!("{LOCKED_ONLY}input keyevent 224; wm dismiss-keyguard; sleep 1; \
f=${{TMPDIR:-/data/local/tmp}}/kiribox-keyguard.xml; b=; for i in 1 2 3; do uiautomator dump \"$f\" >/dev/null 2>&1; \
b=$(grep -oE 'resource-id=\"[^\"]*lockPatternView\"[^>]*bounds=\"\\[[0-9]+,[0-9]+\\]\\[[0-9]+,[0-9]+\\]\"' \"$f\" 2>/dev/null | grep -oE '\\[[0-9]+,[0-9]+\\]\\[[0-9]+,[0-9]+\\]' | head -n 1); \
rm -f \"$f\"; [ -n \"$b\" ] && break; sleep 1; done; \
[ -n \"$b\" ] || {{ echo 'No pattern view on the lock screen: is the lock a pattern?'; exit 4; }}; \
set -- $(echo \"$b\" | tr -c '0-9' ' '); x1=$1; y1=$2; x2=$3; y2=$4; a=DOWN; \
for d in {}; do c=$(( (d - 1) % 3 )); r=$(( (d - 1) / 3 )); \
x=$(( x1 + (2 * c + 1) * (x2 - x1) / 6 )); y=$(( y1 + (2 * r + 1) * (y2 - y1) / 6 )); \
input motionevent $a $x $y; a=MOVE; done; input motionevent UP $x $y",
                argument.chars().map(String::from).collect::<Vec<_>>().join(" "))
        }
        "scrcpy_start" | "scrcpy_stop" => {
            // `scrcpy_start` takes `<session>` or `<session>:<quality>`; stopping needs the session only.
            let (session, quality) = match argument.split_once(':') {
                Some((session, quality)) if action == "scrcpy_start" => (session, quality),
                Some(_) => return Err("Invalid scrcpy session ID".into()),
                None => (argument, "high"),
            };
            if session.len() != 8 || !session.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err("Invalid scrcpy session ID".into());
            }
            let scid = u32::from_str_radix(session, 16).map_err(|_| "Invalid scrcpy session ID")?;
            if scid == 0 || scid > i32::MAX as u32 { return Err("Invalid scrcpy session ID".into()); }
            let path = format!("/data/local/tmp/serverbox-scrcpy-{session}.jar");
            let name = format!("kiribox-scrcpy-{session}");
            if action == "scrcpy_start" {
                let (max_size, max_fps, bit_rate) = scrcpy_quality(quality)?;
                format!("CLASSPATH={} exec app_process / --nice-name={} com.genymobile.scrcpy.Server 5.0.1 scid={session} log_level=verbose tunnel_forward=true audio=false control=true video_codec=h264 max_size={max_size} max_fps={max_fps} video_bit_rate={bit_rate} clipboard_autosync=true cleanup=true power_on=true power_off_on_close=false", quote(&path), quote(&name))
            } else {
                format!("for p in $(pidof {}); do kill \"$p\" 2>/dev/null || true; done; rm -f -- {}", quote(&name), quote(&path))
            }
        }
        _ => return Err("Unknown Android action".into()),
    };
    Ok(if root { format!("if [ \"$(id -u)\" = 0 ]; then sh -c {}; else su -c {}; fi", quote(&cmd), quote(&cmd)) } else { cmd })
}

pub fn parse_status(raw: &str) -> Value {
    let mut sections = HashMap::<String, String>::new();
    let mut key: Option<String> = None;
    for line in raw.lines() {
        if let Some(name) = line.strip_prefix("__SB_ADB_").and_then(|s| s.strip_suffix("__"))
            && STATUS.iter().any(|(k, _)| *k == name) {
            key = Some(name.to_owned()); continue;
        }
        if let Some(key) = &key { sections.entry(key.clone()).or_default().push_str(&format!("{line}\n")); }
    }
    let props: HashMap<String, String> = sections.get("props").map(|s| s.lines().filter_map(|l| {
        let (k, v) = l.strip_prefix('[')?.split_once("]: [")?;
        Some((k.to_owned(), v.strip_suffix(']')?.to_owned()))
    }).collect()).unwrap_or_default();
    let prop = |key: &str| props.get(key).cloned().unwrap_or_default();
    let battery_raw = sections.get("batteryInfo").cloned().unwrap_or_default();
    let battery: HashMap<&str, &str> = Some(battery_raw.as_str()).map(|s| s.lines().filter_map(|l| {
        let (k, v) = l.trim().split_once(':')?; Some((k, v.trim()))
    }).collect()).unwrap_or_default();
    let number = |key: &str| battery.get(key).and_then(|s| s.parse::<f64>().ok());
    let percent = match (number("level"), number("scale")) { (Some(level), Some(scale)) if scale > 0.0 => Some((100.0 * level / scale).clamp(0.0, 100.0)), _ => None };
    let temperature = number("temperature").map(|v| v / 10.0).filter(|v| (-40.0..=150.0).contains(v));
    let battery_status = match battery.get("status").copied() { Some("2") => "Charging", Some("3") => "Discharging", Some("5") => "Full", _ => "Unknown" };
    if let Some(percent) = percent {
        sections.insert("battery".into(), format!("POWER_SUPPLY_NAME=Battery\nPOWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY={}\nPOWER_SUPPLY_STATUS={battery_status}\n", percent.round()));
    }
    let model = prop("ro.product.model");
    sections.insert("sys".into(), format!("Android {} · {}", prop("ro.build.version.release"), model));
    sections.insert("host".into(), model.clone());
    let cpu_percent = sections.get("cpuinfo").and_then(|s| s.lines().find(|l| l.contains("% TOTAL:")))
        .and_then(|s| s.trim().split('%').next()?.parse::<f64>().ok()).filter(|v| (0.0..=100.0).contains(v));
    let addresses: Vec<String> = sections.get("addresses").map(|s| s.lines().filter_map(|l| {
        let words: Vec<_> = l.split_whitespace().collect();
        let at = words.iter().position(|v| *v == "inet" || *v == "inet6")?;
        Some(words.get(at + 1)?.split('/').next()?.to_owned())
    }).collect()).unwrap_or_default();
    let available = json!({
        "cpu": !crate::linux::parse_cpu(sections.get("cpu").map(String::as_str).unwrap_or("")).is_empty(),
        "mem": crate::linux::parse_mem(sections.get("mem").map(String::as_str).unwrap_or("")).is_some(),
        "net": !crate::linux::parse_net(sections.get("net").map(String::as_str).unwrap_or("")).is_empty(),
    });
    json!({
        "available": available,
        "raw": sections,
        "device": {
            "model": model, "brand": prop("ro.product.brand"),
            "android": prop("ro.build.version.release"), "api": prop("ro.build.version.sdk"),
            "patch": prop("ro.build.version.security_patch"), "abi": prop("ro.product.cpu.abi"),
            "guid": prop("persist.adb.wifi.guid"),
            "identity": sections.get("identity").map(|s| s.trim()),
            "kernel": sections.get("kernel").map(|s| s.trim()),
            "battery_percent": percent, "battery_temperature": temperature,
            "battery_status": battery_status, "battery_voltage_mv": number("voltage"),
            "battery_health": number("health"), "cpu_percent": cpu_percent, "addresses": addresses,
        }
    })
}

pub fn parse_apps(raw: &str) -> Vec<Value> {
    raw.lines().filter_map(|line| {
        let line = line.strip_prefix("package:")?;
        let (path_package, version) = line.split_once(" versionCode:").unwrap_or((line, ""));
        let (path, package) = path_package.rsplit_once('=').unwrap_or(("", path_package));
        if package.is_empty() || !package.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.') { return None; }
        Some(json!({"package": package, "path": path, "version": version.trim()}))
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quotes_app_arguments_and_rejects_invalid_environments() {
        assert!(command("stop", "a'; reboot; '", false).unwrap().contains("'\\''"));
        assert!(exec_command("true", None, &HashMap::from([("A;reboot".into(), "x".into())])).is_err());
        assert!(command("remove_temp", "/data/local/tmp/other", false).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn denied_metrics_do_not_fail_the_collection() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        for name in ["id", "getprop", "cat", "dumpsys", "tail", "df", "uptime", "uname", "ip"] {
            let path = dir.path().join(name);
            std::fs::write(&path, "#!/bin/sh\nprintf 'Permission denied\\n'\nexit 1\n").unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let result = std::process::Command::new("/bin/sh").arg("-c")
            .arg(command("status", "", false).unwrap()).env("PATH", dir.path()).output().unwrap();
        assert!(result.status.success());
        let parsed = parse_status(&String::from_utf8(result.stdout).unwrap());
        assert!(parsed["raw"]["cpu"].as_str().unwrap().contains("Permission denied"));
        assert!(parsed["device"]["battery_percent"].is_null());
        assert_eq!(parsed["available"], json!({"cpu": false, "mem": false, "net": false}));
    }

    #[cfg(unix)]
    #[test]
    fn root_probe_requires_actual_uid_zero() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let write = |name: &str, script: &str| {
            let path = dir.path().join(name);
            std::fs::write(&path, script).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        };
        let run = || std::process::Command::new("/bin/sh").arg("-c")
            .arg(command("root_probe", "", false).unwrap()).env("PATH", dir.path()).status().unwrap().success();
        write("id", "#!/bin/sh\nprintf '2000\\n'\n");
        // A broken su can exit zero while leaving the shell unprivileged.
        write("su", "#!/bin/sh\n/bin/sh \"$@\"\n");
        assert!(!run());
        write("su", "#!/bin/sh\nexit 1\n");
        assert!(!run());
        write("id", "#!/bin/sh\nprintf '0\\n'\n");
        assert!(run());
    }

    #[test]
    fn battery_units_missing_metrics_and_package_paths() {
        let parsed = parse_status("__SB_ADB_props__\n[ro.product.model]: [Pixel]\n__SB_ADB_batteryInfo__\n level: 40\n scale: 80\n temperature: 315\n status: 2\n__SB_ADB_cpu__\nPermission denied\n");
        assert_eq!(parsed["device"]["battery_percent"], 50.0);
        assert_eq!(parsed["device"]["battery_temperature"], 31.5);
        assert!(parsed["device"]["cpu_percent"].is_null());
        assert_eq!(parsed["device"]["model"], "Pixel");
        assert_eq!(parse_apps("package:/data/app/a=b/base.apk=com.example.app versionCode:42\n")[0]["package"], "com.example.app");
        assert!(parse_status("")["device"]["battery_percent"].is_null());
    }

    #[test]
    fn scrcpy_commands_reject_untrusted_session_names() {
        for value in ["", "00000000", "80000000", "ffffffff", "1234", "12345678;id", "1234567'", "../file"] {
            assert!(command("scrcpy_start", value, false).is_err(), "{value}");
            assert!(command("scrcpy_stop", value, false).is_err(), "{value}");
        }
        let start = command("scrcpy_start", "01234567", false).unwrap();
        assert!(start.contains("com.genymobile.scrcpy.Server 5.0.1 scid=01234567"));
        assert!(start.contains("audio=false") && start.contains("clipboard_autosync=true"));
        assert!(start.contains("--nice-name='kiribox-scrcpy-01234567'"));
        let stop = command("scrcpy_stop", "01234567", false).unwrap();
        assert!(stop.contains("pidof 'kiribox-scrcpy-01234567'"));
        assert!(!stop.contains("pkill") && !stop.contains("killall"));
    }

    #[test]
    fn scrcpy_quality_presets_reach_the_server_arguments() {
        let default = command("scrcpy_start", "01234567", false).unwrap();
        assert!(default.contains("max_size=1280 max_fps=60 video_bit_rate=8000000"));
        let smooth = command("scrcpy_start", "01234567:smooth", false).unwrap();
        assert!(smooth.contains("scid=01234567 ") && smooth.contains("max_size=720 max_fps=30 video_bit_rate=1000000"));
        for name in ["high", "balanced", "smooth", "saver"] {
            assert!(command("scrcpy_start", &format!("01234567:{name}"), false).is_ok(), "{name}");
        }
        for bad in ["01234567:", "01234567:ultra", "01234567:smooth;id", "01234567:smooth:x", ":smooth"] {
            assert!(command("scrcpy_start", bad, false).is_err(), "{bad}");
        }
        assert!(command("scrcpy_stop", "01234567:smooth", false).is_err());
    }

    #[test]
    fn screen_root_and_wake_use_regular_keyguard_flow() {
        let wake = command("screen_wake", "", false).unwrap();
        assert_eq!(wake, "input keyevent 224 && wm dismiss-keyguard");
        assert!(!wake.contains("locksettings") && !wake.contains("rm "));
        let privileged_wake = command("screen_wake", "", true).unwrap();
        assert!(privileged_wake.contains("su -c ") && privileged_wake.contains("input keyevent 224"));
        let start = command("scrcpy_start", "01234567", true).unwrap();
        let stop = command("scrcpy_stop", "01234567", true).unwrap();
        assert!(start.contains("su -c ") && start.contains("scid=01234567"));
        assert!(stop.contains("su -c ") && stop.contains("kiribox-scrcpy-01234567"));
        assert!(!stop.contains("killall"));
    }

    #[test]
    fn unlock_secret_refuses_what_input_text_cannot_type() {
        for bad in ["", "12 34", "100%", "pässword", &"1".repeat(65), "12\n34"] {
            assert!(command("unlock_secret", bad, false).is_err(), "{bad:?}");
        }
        let unlock = command("unlock_secret", "it's;$(id)", false).unwrap();
        assert!(unlock.contains("input text 'it'\\''s;$(id)'"));
        assert!(command("unlock_secret", "1234", true).unwrap().contains("su -c "));
    }

    #[cfg(unix)]
    #[test]
    fn unlock_secret_types_only_on_the_lock_screen() {
        use std::os::unix::fs::PermissionsExt;
        let run = |showing: bool| {
            let dir = tempfile::tempdir().unwrap();
            let log = dir.path().join("typed");
            let tools = [
                ("dumpsys", format!("#!/bin/sh\nprintf '    KeyguardServiceDelegate\\n      showing={showing}\\n      secure=true\\n'\n")),
                ("input", format!("#!/bin/sh\necho \"$@\" >> '{}'\n", log.display())),
                ("wm", "#!/bin/sh\ntrue\n".into()),
                ("sleep", "#!/bin/sh\ntrue\n".into()),
            ];
            for (name, body) in tools {
                let path = dir.path().join(name);
                std::fs::write(&path, body).unwrap();
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let path = format!("{}:/usr/bin:/bin", dir.path().display());
            let status = std::process::Command::new("/bin/sh").arg("-c")
                .arg(command("unlock_secret", "4321", false).unwrap()).env("PATH", path).status().unwrap();
            (status.code(), std::fs::read_to_string(log).unwrap_or_default())
        };
        let (code, typed) = run(true);
        assert_eq!(code, Some(0));
        assert_eq!(typed, "keyevent 224\ntext 4321\nkeyevent 66\n");
        let (code, typed) = run(false);
        assert_eq!(code, Some(3));
        assert!(typed.is_empty(), "typed into an unlocked phone: {typed}");
    }

    #[test]
    fn unlock_pattern_takes_distinct_keypad_digits() {
        for bad in ["", "123", "1234567890", "1231", "0123", "12a4", "1 23", "12345;id"] {
            assert!(command("unlock_pattern", bad, false).is_err(), "{bad:?}");
        }
        assert!(command("unlock_pattern", "1478", false).unwrap().contains("for d in 1 4 7 8; do"));
    }

    #[cfg(unix)]
    #[test]
    fn unlock_pattern_draws_through_the_pattern_views_dot_centres() {
        use std::os::unix::fs::PermissionsExt;
        let run = |showing: bool| {
            let dir = tempfile::tempdir().unwrap();
            let log = dir.path().join("drawn");
            let xml = r#"<node resource-id="com.android.systemui:id/keyguard_bouncer" bounds="[0,0][1080,2400]"><node index="0" text="" resource-id="com.android.systemui:id/lockPatternView" class="android.view.View" bounds="[100,800][1000,1700]" /></node>"#;
            let tools = [
                ("dumpsys", format!("#!/bin/sh\nprintf '      showing={showing}\\n'\n")),
                ("uiautomator", format!("#!/bin/sh\nprintf '%s' '{xml}' > \"$2\"\n")),
                ("input", format!("#!/bin/sh\necho \"$@\" >> '{}'\n", log.display())),
                ("wm", "#!/bin/sh\ntrue\n".into()),
                ("sleep", "#!/bin/sh\ntrue\n".into()),
            ];
            for (name, body) in tools {
                let path = dir.path().join(name);
                std::fs::write(&path, body).unwrap();
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let status = std::process::Command::new("/bin/sh").arg("-c").arg(command("unlock_pattern", "1478", false).unwrap())
                .env("PATH", format!("{}:/usr/bin:/bin", dir.path().display())).env("TMPDIR", dir.path()).status().unwrap();
            assert!(!dir.path().join("kiribox-keyguard.xml").exists(), "the dump is removed");
            (status.code(), std::fs::read_to_string(log).unwrap_or_default())
        };
        let (code, drawn) = run(true);
        assert_eq!(code, Some(0));
        assert_eq!(drawn, "keyevent 224\nmotionevent DOWN 250 950\nmotionevent MOVE 250 1250\nmotionevent MOVE 250 1550\nmotionevent MOVE 550 1550\nmotionevent UP 550 1550\n");
        let (code, drawn) = run(false);
        assert_eq!(code, Some(3));
        assert!(drawn.is_empty(), "drew on an unlocked phone: {drawn}");
    }

    #[cfg(unix)]
    #[test]
    fn screen_state_reports_wakefulness_and_keyguard_lines() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let dumpsys = dir.path().join("dumpsys");
        std::fs::write(&dumpsys, "#!/bin/sh\ncase \"$1\" in\npower) echo '  mWakefulness=Asleep';;\n\
window) printf '    KeyguardServiceDelegate\\n      showing=true\\n      secure=true\\n      screenState=SCREEN_STATE_OFF\\n      currentUser=0\\n';;\nesac\n").unwrap();
        std::fs::set_permissions(&dumpsys, std::fs::Permissions::from_mode(0o755)).unwrap();
        let output = std::process::Command::new("/bin/sh").arg("-c").arg(command("screen_state", "", false).unwrap())
            .env("PATH", format!("{}:/usr/bin:/bin", dir.path().display())).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap(), "mWakefulness=Asleep\nshowing=true\nsecure=true\nscreenState=SCREEN_STATE_OFF\n");
    }

    #[cfg(unix)]
    #[test]
    fn scrcpy_launch_exports_classpath_and_passes_exact_arguments() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("app_process");
        std::fs::write(&path, "#!/bin/sh\nprintf '%s\\n' \"$CLASSPATH\" \"$@\"\n").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let output = std::process::Command::new("/bin/sh").arg("-c")
            .arg(command("scrcpy_start", "01234567", false).unwrap()).env("PATH", dir.path()).output().unwrap();
        assert!(output.status.success());
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.starts_with("/data/local/tmp/serverbox-scrcpy-01234567.jar\n/\n--nice-name=kiribox-scrcpy-01234567\ncom.genymobile.scrcpy.Server\n5.0.1\n"));
    }
}
