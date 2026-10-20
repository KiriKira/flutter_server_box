---
title: Android over ADB
description: Pair, monitor and manage an Android phone with Wireless ADB
---

Enable **ADB** under a device's connection methods. Wireless debugging (TLS)
requires an Android 11+ target. Android clients include the ADB client;
Windows, Linux and macOS clients require `adb` from Android platform-tools on
PATH. Active ADB connections use the Android shell environment, independently
of any saved SSH or Monitor configuration.

## Pairing

For another phone, enable Wireless debugging in its developer options and open
**Pair device with pairing code**. Enter its address, pairing port and six-digit
code in ServerBox. Set the **connection port** from the main Wireless debugging
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

Split APK bundles, AAB installation, USB, screen control and root-only file
browsing are not included. Desktop clients use the installed adb server; ServerBox
closes its own service streams and does not kill that shared server.

## AI agent

The app-wide agent identifies phones as **Android (ADB)**. It can inspect their
status, run shell commands, read/write accessible files and use `android_device`
for application management, logs, screenshots and root requests. The agent in an
ADB terminal stays bound to that phone's ADB connection. Review of changes follows
the existing agent settings. Pairing codes belong in ServerBox's pairing UI,
never in the conversation.
