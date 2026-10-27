"""Bounded loopback relay for disposable Quantum balance UI acceptance.

Reads public enrollment only. Optional funding uses the isolated genesis test
account, never simulator custody. It is not mobile signing acceptance.
"""
import argparse
import base64
import hashlib
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--history', action='store_true', help='Falsify transaction metadata and enable raw-cell corruption controls')
    p.add_argument('--device', required=True)
    p.add_argument('--bundle-id', required=True)
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--upstream', required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--tos-root', type=Path, required=True)
    p.add_argument('--fixture', type=Path, required=True)
    p.add_argument('--signer', type=Path, required=True)
    a = p.parse_args()
    endpoint = urllib.parse.urlsplit(a.upstream)
    if endpoint.scheme != 'http' or endpoint.hostname not in ('127.0.0.1', 'localhost') or endpoint.query or endpoint.fragment:
        raise ValueError('requires loopback native test node')
    a.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    sys.path.insert(0, str(a.tos_root / 'test/auth-extensions'))
    from cells import Cell, from_boc
    fixture = json.loads(a.fixture.read_text())
    if fixture['global_id'] != 1 or fixture['namespace'] != '42' * 32:
        raise ValueError('requires isolated public self-pay genesis')
    source = fixture['accounts']['active']
    poisoned = False
    corrupt_history = False
    counts = {'proofs': 0, 'ordinary': 0, 'transactions': 0, 'legacy_history': 0}
    traffic = []
    funded = None
    funded_boc = None

    def rpc(method, params):
        payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
        request = urllib.request.Request(a.upstream.rstrip('/') + '/jsonRPC', data=payload,
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=35) as response:
            raw = response.read(16 * 1024 * 1024 + 1)
        if len(raw) > 16 * 1024 * 1024:
            raise ValueError('response limit')
        result = json.loads(raw)
        if 'error' in result:
            raise ValueError('native RPC rejected ' + method + ': ' + str(result['error']))
        return result['result']

    def snapshot():
        raw = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', a.device, a.bundle_id, 'data'],
                                      text=True, timeout=15)
        container = Path(raw.strip()).resolve(strict=True)
        if a.device.upper() not in str(container).upper():
            raise ValueError('unexpected container')
        files = list((container / 'Library/Application Support/quantum-creation').glob('*.json'))
        if len(files) != 1 or files[0].stat().st_size > 32768:
            raise ValueError('requires one bounded fresh public enrollment')
        record = json.loads(files[0].read_text())
        identity = from_boc(base64.b64decode(record['identity'], validate=True))
        if len(identity.bits) != 288 or int(identity.bits[:32], 2) != 0x51534931 or len(identity.refs) != 1:
            raise ValueError('invalid QSI1 public identity')
        address = '0:' + f'{int(identity.bits[32:], 2):064x}'
        if identity.refs[0].hash.hex() != address[2:]:
            raise ValueError('birth identity address mismatch')
        return {'id': record['id'], 'address': address,
                'profile_sha256': hashlib.sha256(json.dumps(record['profile'], sort_keys=True).encode()).hexdigest(),
                'identity_sha256': hashlib.sha256(record['identity'].encode()).hexdigest()}

    def fund():
        nonlocal funded, funded_boc
        current = snapshot()
        if funded is not None:
            if funded['address'] != current['address']:
                raise ValueError('recipient changed after funding')
            rpc('sendBocReturnHash', {'boc': funded_boc})
            return funded
        # This seed is already public in the canonical regression vector.
        private = a.out / 'private-public-test-signer'
        private.mkdir(mode=0o700)
        pk, sk, digest, sig = [private / n for n in ('public.bin', 'secret.bin', 'digest.bin', 'signature.bin')]
        subprocess.run([str(a.signer), 'keygen', '11' * 32, str(pk), str(sk)],
                       check=True, capture_output=True, timeout=30)
        if pk.read_bytes().hex() != fixture['primary_key']:
            raise ValueError('public fixture signer mismatch')
        sender = (0, int(source['address'][2:], 16))
        recipient = (0, int(current['address'][2:], 16))
        authority = from_boc(base64.b64decode(source['data_boc'])).refs[0]
        message = (Cell().uint(4, 4).addr(sender).addr(recipient).coins(10_000_000_000).uint(0, 1)
                   .coins(0).coins(0).uint(0, 64).uint(int(time.time()), 32).uint(0, 1).uint(1, 1).ref(Cell()))
        actions = Cell().uint(0x0EC3C86D, 32).uint(3, 8).ref(Cell()).ref(message)
        request = (Cell().uint(0x51535031, 32).sint(1, 32).uint(int('42' * 32, 16), 256).addr(sender)
                   .raw(authority.hash).uint(1, 8).uint(0, 64).uint(0, 64).uint(int(time.time()) + 180, 32)
                   .uint(0, 8).ref(Cell().uint(0x45584543, 32).ref(actions)))
        digest.write_bytes(request.hash)
        subprocess.run([str(a.signer), 'sign', str(sk), b'TOS-QSP-MLDSA44-v1'.hex(), str(digest), str(sig)],
                       check=True, capture_output=True, timeout=30)
        signature = sig.read_bytes()
        if len(signature) != 2420:
            raise ValueError('signature length')
        tail = None
        for offset in reversed(range(0, len(signature), 127)):
            cell = Cell().raw(signature[offset:offset + 127])
            if tail is not None:
                cell.ref(tail)
            tail = cell
        external = Cell().uint(8, 4).addr(sender).coins(0).uint(0, 1).uint(1, 1).ref(Cell().ref(request).ref(tail))
        funded_boc = base64.b64encode(external.boc()).decode()
        # Store the exact message before first delivery: retries never re-sign nonce 0.
        (private / 'message.boc').write_bytes(external.boc())
        funded = dict(current, nanos='10000000000', message_hash=external.hash.hex(), status='submitted')
        (a.out / 'fund.json').write_text(json.dumps(funded, indent=2) + '\n')
        rpc('sendBocReturnHash', {'boc': funded_boc})
        return funded

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, code, value):
            raw = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            nonlocal poisoned, corrupt_history
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 <= length <= 2 * 1024 * 1024:
                    raise ValueError('request limit')
                raw = self.rfile.read(length)
                if self.path.startswith('/__quantum_balance/'):
                    if raw != b'{}':
                        raise ValueError('control requires empty object')
                    action = self.path.rsplit('/', 1)[-1]
                    if action in ('poison', 'normal'):
                        poisoned = action == 'poison'
                        value = {'status': action}
                    elif a.history and action in ('history-corrupt', 'history-normal'):
                        corrupt_history = action == 'history-corrupt'
                        value = {'status': action}
                    elif action == 'snapshot':
                        value = snapshot()
                    elif action == 'fund':
                        value = fund()
                    elif action == 'status':
                        value = {key: str(value) for key, value in counts.items()}
                    else:
                        raise ValueError('unknown control')
                    (a.out / (action + '.json')).write_text(json.dumps(value, indent=2) + '\n')
                    self.send(200, value)
                    return
                query = json.loads(raw)
                method = query.get('method', self.path.lstrip('/'))
                if len(traffic) < 128:
                    traffic.append({'method': method, 'poisoned': poisoned})
                (a.out / 'traffic.json').write_text(json.dumps({'counts': counts, 'requests': traffic}, indent=2) + '\n')
                if method == 'getTransactions':
                    counts['transactions'] += 1
                elif method == 'getAccountEvents':
                    counts['legacy_history'] += 1
                if method == 'getProofQuery':
                    counts['proofs'] += 1
                    if poisoned:
                        self.send(200, {'jsonrpc': '2.0', 'id': query.get('id'), 'result': {'reply': 'AA=='}})
                        return
                elif method in ('getAddressInformation', 'getAccountInfo'):
                    counts['ordinary'] += 1
                    if poisoned:
                        self.send(200, {'jsonrpc': '2.0', 'id': query.get('id'), 'result':
                                       {'balance': '999999999000000000', 'state': 'uninitialized', 'status': 'uninit'}})
                        return
                request = urllib.request.Request(a.upstream.rstrip('/') + self.path, data=raw,
                                                 headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=35) as response:
                    raw = response.read(16 * 1024 * 1024 + 1)
                if len(raw) > 16 * 1024 * 1024:
                    raise ValueError('response limit')
                if a.history and method == 'getTransactions':
                    value = json.loads(raw)
                    for transaction in value.get('result', []):
                        transaction.update(fee='999999999999', utime=0, aborted=True,
                            transaction_id={'lt': '0', 'hash': 'AA=='})
                        if corrupt_history:
                            cell = from_boc(base64.b64decode(transaction['data'], validate=True))
                            # Flip one timestamp bit without changing the typed layout.
                            # Only the proof-anchored transaction hash can detect this.
                            if len(cell.bits) < 676:
                                raise ValueError('short transaction header')
                            cell.bits = cell.bits[:675] + str(1 - int(cell.bits[675])) + cell.bits[676:]
                            transaction['data'] = base64.b64encode(cell.boc()).decode()
                    raw = json.dumps(value).encode()
                self.send(200, raw)
            except Exception as error:
                value = {'error': type(error).__name__ + ': ' + str(error)}
                (a.out / 'last-error.json').write_text(json.dumps(value, indent=2) + '\n')
                self.send(500, value)

    server = HTTPServer(('127.0.0.1', a.port), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
