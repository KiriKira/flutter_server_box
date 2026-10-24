---
title: Android over ADB
description: Pair, monitor and manage an Android phone with Wireless ADB
---

Enable **ADB** under **Add / Edit server → Connection**. The ADB section appears
below the connection methods, with **Pair device** below the address and
connection port fields. Wireless debugging (TLS)
requires an Android 11+ target. Android clients include the ADB client;
Windows, Linux and macOS clients require `adb` from Android platform-tools on
PATH. Active ADB connections use the Android shell environment, independently
of any saved SSH or Monitor configuration.

## Pairing

For another phone, enable Wireless debugging in its developer options and open
**Pair device with pairing code**. Tap **Pair device** in KiriBox and enter the
pairing dialog's **address:port** and six-digit code. The pairing form does not
reuse the connection port. QR pairing is not supported.
After pairing, set the **connection port** from the main Wireless debugging
screen; it is different from the pairing port. Test the connection before saving.
Android clients can discover advertised connection endpoints.

On an Android client, select **Manage this Android device**, then **Pair this
device from notification**. Allow notifications, open the Wireless debugging
pairing-code dialog and enter the code directly in the notification. Return to
ServerBox and test the connection. Port `0` enables automatic local discovery.
If notifications are unavailable, use the manual pairing form, optionally in
split-screen. Pairing itself expires after two minutes.

ADB host keys stay on the client and are not included in ServerBox sharing,
backup or sync. A restored device entry may need pairing again. A changed
connection port can be rediscovered on Android. Traditional TCP ADB is an
explicit advanced mode; Wireless debugging never deliberately falls back to it.

## Monitoring and terminal

The device page shows Android version, model, patch level, execution identity,
battery, CPU, memory, storage and available network readings. Android versions
and manufacturers restrict different metrics; unavailable readings are not zero.
The battery's temperature is labelled separately from CPU temperature.

The terminal opens the phone's interactive ADB shell. Type commands such as
`pm list packages`, without prefixing them with `adb shell`. It supports PTY
resizing, Ctrl-C and separate command channels. Exiting a terminal closes that
shell, while monitoring can continue. Android devices do not offer the Linux
systemd, Docker, firewall or user-management pages.

Root enhancement is optional. Request it in **Android tools** and answer the
phone's existing root manager. Rejected or unavailable root leaves ordinary
monitoring working. The enhancement affects collection; an ordinary terminal
still opens as shell. Turn enhancement off in the same page. Reconnecting clears
its in-memory grant. ServerBox does not install root or restart adbd as root.

## Android tools

- Install a normal APK selected from local files. Upload is streamed, then package
  manager installs it. Android clients verify the installed package/version using
  the APK's metadata. Interrupted installs are not automatically replayed.
- Search installed packages, inspect them, launch or force-stop an app, uninstall
  it or clear its data. Installation and package management target Android user 0.
- Browse accessible files, upload, or download with the file shortcut. Downloads
  through this shortcut are limited to 32 MiB; APK uploads are streamed.
- Read a bounded recent logcat snapshot and export its output; save a screenshot;
  reboot the target phone.

Split APK bundles, AAB installation, USB and root-only file
browsing are not included. Desktop clients use the installed adb server; ServerBox
closes its own service streams and does not kill that shared server.

## Screen control (Android client)

For another phone, open **Android tools → Screen control**. The pinned scrcpy 5.0.1
server is built from source into KiriBox, uploaded temporarily and run through
`app_process` over the existing ADB connection. No target app installation, root,
WebRTC or relay server is needed. Users can provide their own VPN connectivity.

The screen supports taps, long presses, drags, multiple fingers and remote
Back/Home/Recent apps buttons. Type by tapping the target phone's own on-screen
keyboard and candidates. The controller's keyboard is not opened. Audio,
desktop/browser viewers and mirroring the controller itself are not included.

Plain-text clipboard syncs both ways while the screen is open: text copied on the
target appears on the controller, and text copied on the controller (including
before opening the page) is placed on the target, ready to paste with a long press.
Clips a password manager marks as sensitive are not sent to the target.

Video is H.264. **Picture quality** in the top-right menu picks a preset: High
(1280 px, 60 fps, 8 Mbps), Balanced (1024 px, 30 fps, 2.5 Mbps), Smooth (720 px,
30 fps, 1 Mbps) or Data saver (540 px, 20 fps, 0.5 Mbps). Automatic, the default,
uses High for a LAN address and Balanced for anything else — a Tailscale address
(`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`), another VPN, a public address
or a bare host name — and steps one preset down when video stays more than a second
behind, remembering that for the rest of the app session. The viewer fits the
picture without forwarding touches from letterboxing and follows target rotation.

Over a remote link (Tailscale, especially through a DERP relay):

- The line under the picture shows the control round trip, how far video is behind
  (when it is), throughput and frame rate; it turns orange when the network stalls.
- Each control write waits for the previous one's ADB acknowledgement, so touches
  queued during a round trip are sent together, each finger at its latest position.
  A circle under each finger appears at once, before the target answers.
- After a stall the backlog is decoded and only the newest frame shown, and when it
  has to be dropped a fresh key frame is requested instead of waiting up to 10 s.
- With no ADB acknowledgement for 15 s the link counts as lost. A session that had
  shown video then reconnects by itself up to five times (1–8 s apart), redialling
  ADB if the old connection no longer answers.
- Momentum scrolling (flings) is unreliable with a round trip above about 40 ms: the
  target timestamps touches when they arrive, and Android drops a fling whose samples
  are that far apart. Drag to scroll, or use shorter swipes.

The controller's screen stays on while the page is open. Backgrounding stops the
screen session; returning recreates it. Errors offer retry. Exiting cleans up only this session, leaving terminal and monitoring
connections alive. Some manufacturers require an additional debugging security
setting to permit shell input injection.

On the lock screen, use **Wake / show unlock screen**, then swipe or enter the
existing device credential. Home and Recent apps cannot dismiss a secure keyguard.
If ADB shell already has `su` authorization, choose **Root control (restart)**
from the top-right menu. This runs the screen server and wake request as root;
it does not clear credentials or enable the separate monitoring root enhancement.
Returning to standard control or reopening the page restores the default shell mode.

**Control diagnostics** shows input requests, native queue acceptances and server
logs. Native queue acceptance is not an acknowledgement that the target executed
the event. Permission-denial and stale-coordinate errors are also shown on screen.

## AI agent

The app-wide agent identifies phones as **Android (ADB)**. It can inspect their
status, run shell commands, read/write accessible files and use `android_device`
for application management, logs, screenshots and root requests. The agent in an
ADB terminal stays bound to that phone's ADB connection. Review of changes follows
the existing agent settings. Pairing codes belong in ServerBox's pairing UI,
never in the conversation.
