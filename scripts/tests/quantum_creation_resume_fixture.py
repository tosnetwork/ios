"""Loopback RPC shim and real file-I/O fault for a disposable iOS simulator.

Use only with a fresh dedicated simulator. Never returns mnemonic/keychain data.
The exclusive empty directory at KeeperInfo/KeeperInfo makes real registration
fail after custody. Release removes only that owned, empty fault directory.
"""
import argparse
import hashlib
import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.upstream)
    if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost') or parsed.query or parsed.fragment:
        raise ValueError('upstream must be a loopback HTTP node')
    args.out.mkdir(parents=True, exist_ok=False)
    armed = None

    def container(kind):
        result = subprocess.run(['xcrun', 'simctl', 'get_app_container', args.device, args.bundle_id, kind],
                                capture_output=True, text=True, check=True, timeout=15)
        path = Path(result.stdout.strip()).resolve(strict=True)
        if args.device.upper() not in str(path).upper() or not path.is_dir():
            raise ValueError('unexpected simulator container')
        return path

    def snapshot():
        support = container('data') / 'Library/Application Support/quantum-creation'
        files = list(support.glob('*.json'))
        if len(files) != 1 or files[0].stat().st_size > 32768:
            raise ValueError('fixture requires exactly one bounded fresh creation record')
        record = json.loads(files[0].read_text())
        return {'id': record['id'], 'published': str(record.get('published', False)).lower(), 'profile_sha256': hashlib.sha256(json.dumps(record['profile'], sort_keys=True).encode()).hexdigest(),
                'identity_sha256': hashlib.sha256(json.dumps(record['identity'], sort_keys=True).encode()).hexdigest()}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def send(self, status, raw):
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            nonlocal armed
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 <= length <= 2 * 1024 * 1024:
                    raise ValueError('request limit')
                raw = self.rfile.read(length)
                if self.path.startswith('/__quantum_creation/'):
                    if raw != b'{}':
                        raise ValueError('control takes an empty object only')
                    action = self.path.rsplit('/', 1)[-1]
                    if action == 'arm':
                        if armed is not None:
                            raise ValueError('already armed')
                        try:
                            base = container('group.' + args.bundle_id)
                        except subprocess.CalledProcessError:
                            base = container('data') / 'Documents'
                        target = base / 'KeeperInfo/KeeperInfo'
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.mkdir()  # Exclusive: refuse touching any existing registry.
                        armed = target
                        value = {'status': 'armed'}
                    elif action == 'release':
                        if armed is None:
                            raise ValueError('no owned fault')
                        value = snapshot()
                        armed.rmdir()  # Refuse a changed or non-empty path.
                        armed = None
                    elif action == 'snapshot':
                        value = snapshot()
                    elif action == 'damage':
                        public = container('data') / 'Library/Application Support/quantum-creation'
                        (public / '.qcreation-interrupted.tmp').write_bytes(b'PUBLIC TRUNCATED STAGING FILE')
                        value = {'status': 'damaged-public-staging-added'}
                    else:
                        raise ValueError('unknown control')
                    (args.out / (action + '.json')).write_text(json.dumps(value, indent=2) + '\n')
                    self.send(200, json.dumps(value).encode())
                    return
                request = urllib.request.Request(args.upstream.rstrip('/') + self.path, data=raw,
                                                 headers={'Content-Type': 'application/json'})
                try:
                    with urllib.request.urlopen(request, timeout=35) as reply:
                        raw = reply.read(16 * 1024 * 1024 + 1)
                        if len(raw) > 16 * 1024 * 1024:
                            raise ValueError('reply limit')
                        self.send(reply.status, raw)
                except urllib.error.HTTPError as error:
                    self.send(error.code, error.read(4096))
            except Exception as error:
                self.send(500, json.dumps({'error': type(error).__name__ + ': ' + str(error)}).encode())

    server = HTTPServer(('127.0.0.1', args.port), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if armed is not None:
            armed.rmdir()


if __name__ == '__main__':
    main()
