"""Loopback controller for an explicitly disposable iOS cold-recovery simulator.

Never receives a mnemonic. Only compares public creation identity/profile hashes.
"""
import argparse
import base64
import sys
import hashlib
import json
import plistlib
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18845)
    parser.add_argument('--tos-root', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.tos_root / 'test/auth-extensions'))
    from cells import from_boc
    bundle = 'network.tos.wallet'
    app = args.app.resolve(strict=True)
    with (app / 'Info.plist').open('rb') as stream:
        if plistlib.load(stream)['CFBundleIdentifier'] != bundle:
            raise ValueError('Unexpected application bundle')

    def simctl(*parts):
        return subprocess.run(['xcrun', 'simctl', *parts], check=True,
                              capture_output=True, text=True, timeout=90).stdout.strip()

    devices = json.loads(simctl('list', 'devices', '-j'))['devices']
    selected = [d for group in devices.values() for d in group if d['udid'] == args.device]
    if len(selected) != 1 or not selected[0]['name'].startswith('TOS-Local-Quantum-'):
        raise ValueError('Only an explicitly named disposable Quantum simulator is allowed')

    def tree_hash(directory):
        files = [(str(path.relative_to(directory)), hashlib.sha256(path.read_bytes()).hexdigest())
                 for path in sorted(directory.rglob('*')) if path.is_file()]
        if not files:
            raise ValueError('Empty app bundle')
        return hashlib.sha256(json.dumps(files, separators=(',', ':')).encode()).hexdigest()

    original_app_hash = None

    def snapshot():
        nonlocal original_app_hash
        source_hash = tree_hash(app)
        installed_hash = tree_hash(Path(simctl('get_app_container', args.device, bundle, 'app')))
        if source_hash != installed_hash:
            raise ValueError('Installed app differs from the reinstall source')
        if original_app_hash is not None and source_hash != original_app_hash:
            raise ValueError('App bundle changed during cold recovery')
        original_app_hash = source_hash
        container = Path(simctl('get_app_container', args.device, bundle, 'data')).resolve(strict=True)
        if args.device.lower() not in str(container).lower():
            raise ValueError('Unexpected simulator data container')
        files = list((container / 'Library/Application Support/quantum-creation').glob('*.json'))
        if len(files) != 1 or files[0].stat().st_size > 32768:
            raise ValueError('Expected one bounded public creation record')
        record = json.loads(files[0].read_text())
        if record.get('published') is not True:
            raise ValueError('Wallet was not published')
        raw = base64.b64decode(record['identity'], validate=True)
        if len(raw) > 16384:
            raise ValueError('Public identity exceeds its bounded encoding')
        identity = from_boc(raw)
        if (len(identity.bits) != 288 or int(identity.bits[:32], 2) != 0x51534931
                or len(identity.refs) != 1
                or identity.refs[0].hash.hex() != f'{int(identity.bits[32:], 2):064x}'):
            raise ValueError('Invalid QSI1 identity or address binding')
        return {'app_tree_sha256': source_hash, 'identity_cell_hash': identity.hash.hex(),
                'identity_boc_sha256': hashlib.sha256(raw).hexdigest(),
                'profile_sha256': hashlib.sha256(json.dumps(record['profile'], sort_keys=True).encode()).hexdigest()}

    original = None
    reinstalled = False

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            nonlocal original, reinstalled
            try:
                if self.headers.get('Content-Length') != '2' or self.rfile.read(2) != b'{}':
                    raise ValueError('Control requires an empty JSON object')
                if self.path == '/snapshot' and original is None:
                    original = snapshot()
                    result = original
                elif self.path == '/reinstall' and original is not None and not reinstalled:
                    # The UI runner terminates the app first. Its separate runner
                    # bundle remains installed so its in-memory backup survives.
                    simctl('uninstall', args.device, bundle)
                    simctl('install', args.device, str(app))
                    reinstalled = True
                    result = {'reinstalled': True}
                elif self.path == '/verify' and reinstalled:
                    result = snapshot()
                    if any(result[key] != original[key] for key in ('identity_cell_hash', 'profile_sha256')):
                        raise ValueError('Restored public identity or network profile changed')
                else:
                    raise ValueError('Invalid cold-recovery stage')
                print(json.dumps({'stage': self.path, 'result': result}), flush=True)
                data = json.dumps(result).encode()
                self.send_response(200)
            except Exception as error:
                data = json.dumps({'error': str(error)}).encode()
                self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
