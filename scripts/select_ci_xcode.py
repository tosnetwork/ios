#!/usr/bin/env python3
"""Select an installed supported Xcode and an available iPhone simulator."""
import glob
import json
import os
import re
import subprocess

candidates = []
for path in glob.glob('/Applications/Xcode*.app'):
    developer = path + '/Contents/Developer'
    environment = dict(os.environ, DEVELOPER_DIR=developer)
    result = subprocess.run(['xcodebuild', '-version'], env=environment, capture_output=True, text=True)
    version = re.search(r'Xcode (\d+)(?:\.(\d+))?', result.stdout)
    if result.returncode == 0 and version and int(version[1]) >= 26:
        candidates.append(((int(version[1]), int(version[2] or 0)), developer))
if not candidates:
    raise SystemExit('No supported Xcode 26 or newer is installed')
_, developer = max(candidates)
subprocess.run(['sudo', 'xcode-select', '-s', developer], check=True)
subprocess.run(['xcodebuild', '-version'], check=True)
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
phones = []
for runtime, values in devices.items():
    version = re.search(r'iOS-(\d+(?:-\d+)*)$', runtime)
    if version:
        runtime_version = tuple(int(value) for value in version[1].split('-'))
        phones.extend((runtime_version, device) for device in values if device['name'].startswith('iPhone'))
if not phones:
    raise SystemExit('No available iPhone simulator runtime is installed')
runtime_version, phone = max(phones, key=lambda item: (item[0], item[1]['name']))
destination = 'platform=iOS Simulator,id=' + phone['udid']
print('Selected simulator: ' + phone['name'] + ', iOS ' + '.'.join(map(str, runtime_version)) + ' (' + phone['udid'] + ')')
with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as target:
    target.write('TEST_DESTINATION=' + destination + '\n')
