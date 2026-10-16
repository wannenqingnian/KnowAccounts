#!/usr/bin/env python3
"""Read-only device/version/automation permission checks; never dumps receipts."""
import argparse
import json
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default=shutil.which('adb'))
parser.add_argument('--serial')
args = parser.parse_args()
if not args.adb:
    parser.error('Pass --adb /path/to/adb')

def run(*command):
    return subprocess.check_output([args.adb, *command], text=True, timeout=20).strip()

rows = [line.split() for line in run('devices').splitlines()[1:] if line.strip()]
connected = [row[0] for row in rows if len(row) >= 2 and row[1] == 'device']
if args.serial and args.serial not in connected:
    parser.error('Selected device is not connected/authorized')
if not connected:
    print(json.dumps({'device_connected': False, 'device_validation': 'blocked: no authorized device'}, indent=2))
    raise SystemExit(2)
if len(connected) > 1 and not args.serial:
    parser.error('Multiple devices: select --serial')
serial = args.serial or connected[0]

def shell(*command):
    return run('-s', serial, 'shell', *command)

package = 'com.smartledger.smart_ledger'
metadata = shell('dumpsys', 'package', package)
version = re.search(r'\bversionName=(\S+)', metadata)
notification = shell('settings', 'get', 'secure', 'enabled_notification_listeners')
accessibility = shell('settings', 'get', 'secure', 'enabled_accessibility_services')
print(json.dumps({
    'device_connected': True,
    'android': shell('getprop', 'ro.build.version.release'),
    'api': shell('getprop', 'ro.build.version.sdk'),
    'app_version': version.group(1) if version else None,
    'notification_permission': package in notification,
    'accessibility_permission': package in accessibility,
    'overlay_app_op': shell('appops', 'get', package, 'SYSTEM_ALERT_WINDOW'),
    'device_validation': 'permission checks only; manual payment/background cases still required',
}, ensure_ascii=False, indent=2))
