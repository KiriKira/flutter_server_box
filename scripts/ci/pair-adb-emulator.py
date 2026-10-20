#!/usr/bin/env python3
"""Drive the emulator's real Settings pairing dialog without logging its code."""
import json
import os
import re
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = 'tech.kirikira.kiribox.debug'


def adb(*args, data=None, required=True):
    result = subprocess.run(['adb', *args], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=20)
    if required and result.returncode:
        raise RuntimeError('ADB harness command failed: ' + result.stderr.decode(errors='replace'))
    return result


def exists(name):
    return adb('shell', 'run-as', PACKAGE, 'test', '-f', f'files/kiribox-adb-{name}', required=False).returncode == 0


def wait(name, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if exists(name):
            return
        time.sleep(1)
    raise TimeoutError('Integration app did not reach stage ' + name)


def write(name, data):
    # Only fixed harness filenames enter shell source; payload stays on stdin.
    assert re.fullmatch(r'[a-z.]+', name)
    adb('shell', f"run-as {PACKAGE} sh -c 'cat > files/kiribox-adb-{name}'", data=data)


def hierarchy():
    adb('shell', 'uiautomator', 'dump', '/data/local/tmp/kiribox-window.xml')
    raw = adb('exec-out', 'cat', '/data/local/tmp/kiribox-window.xml').stdout
    return list(ET.fromstring(raw).iter('node'))


def tap(node):
    match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
    if not match:
        raise RuntimeError('Missing bounds in Settings UI')
    x1, y1, x2, y2 = map(int, match.groups())
    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))


def main():
    wait('ready')
    adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
    with open(os.environ['KIRIBOX_E2E_FIXTURE'], 'rb') as fixture:
        write('fixture.apk', fixture.read())
    write('permission', b'granted')
    wait('foreground')
    adb('shell', "am start -n 'com.android.settings/.Settings$WirelessDebuggingActivity'")
    deadline = time.monotonic() + 90
    pairing = None
    while time.monotonic() < deadline:
        nodes = hierarchy()
        texts = [node.get('text', '') for node in nodes]
        code = next((re.sub(r'\s', '', text) for text in texts
                     if re.fullmatch(r'\d{3}\s*\d{3}', text)), None)
        endpoint = next((re.search(r'((?:\d{1,3}\.){3}\d{1,3}):(\d{2,5})', text)
                         for text in texts if re.search(r'(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}', text)), None)
        if code and endpoint:
            pairing = {'host': endpoint.group(1), 'port': int(endpoint.group(2)), 'code': code}
            break
        allow = next((node for node in nodes if node.get('text', '').lower() in ('allow', 'allow wireless debugging')), None)
        pair = next((node for node in nodes if 'pair device with pairing code' in node.get('text', '').lower()), None)
        toggle = next((node for node in nodes if node.get('class') == 'android.widget.Switch'
                       and node.get('checked') == 'false'), None)
        if allow is not None:
            tap(allow)
        elif pair is not None:
            tap(pair)
        elif toggle is not None:
            tap(toggle)
        time.sleep(1)
    if pairing is None:
        raise TimeoutError('Wireless debugging Settings did not expose a pairing endpoint')
    write('pair.json', json.dumps(pairing).encode())
    wait('paired')
    adb('shell', 'am', 'start', '-n', PACKAGE + '/tech.kirikira.kiribox.MainActivity')
    write('resumed', b'resumed')
    print('Real Android Wireless debugging paired using the app native ADB client.')


if __name__ == '__main__':
    main()
