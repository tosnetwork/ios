"""Bounded loopback relay for disposable Quantum balance UI acceptance.

Reads public enrollment only. Optional funding uses the isolated genesis test
account, never simulator custody. It is not mobile signing acceptance.
"""
import argparse
import threading
import os
import base64
import hashlib
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
    p.add_argument('--funding-control', required=True)
    a = p.parse_args()
    endpoint = urllib.parse.urlsplit(a.upstream)
    if endpoint.scheme != 'http' or endpoint.hostname not in ('127.0.0.1', 'localhost') or endpoint.query or endpoint.fragment:
        raise ValueError('requires loopback native test node')
    a.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    sys.path.insert(0, str(a.tos_root / 'test/auth-extensions'))
    from cells import Cell, from_boc
    control = urllib.parse.urlsplit(a.funding_control)
    if (control.scheme != 'http' or control.hostname not in ('127.0.0.1', 'localhost')
            or control.username or control.password or control.query or control.fragment
            or control.path not in ('', '/')):
        raise ValueError('requires a loopback localnet faucet')
    faucet_attempts = set()
    poisoned = False
    corrupt_history = False
    counts = {'proofs': 0, 'ordinary': 0, 'transactions': 0, 'legacy_history': 0}
    traffic = []
    funded = None
    funded_boc = None
    funding_ledger = {}
    submissions = []
    submission_events = []
    state_lock = threading.RLock()
    fund_lock = threading.Lock()
    submission_mode = {'mode':'normal', 'delay_ms':12000}
    def write_json(name, value):
        with state_lock:
            target = a.out / name
            temporary = a.out / (name + '.tmp')
            temporary.write_text(json.dumps(value, indent=2) + '\n')
            os.replace(temporary, target)

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
                'identity_sha256': hashlib.sha256(record['identity'].encode()).hexdigest(),
                'identity_cell_hash': identity.hash.hex()}

    def pending():
        current = snapshot()
        raw = subprocess.check_output(['xcrun','simctl','get_app_container',a.device,a.bundle_id,'data'], text=True, timeout=15)
        container = Path(raw.strip()).resolve(strict=True)
        if a.device.upper() not in str(container).upper(): raise ValueError('unexpected container')
        path = container / 'Library/Application Support/quantum-outbox' / (current['identity_cell_hash'] + '.json')
        if not path.exists(): return dict(current, phase=None, has_signed_boc=False)
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 2097152:
            raise ValueError('invalid public journal file')
        value = json.loads(path.read_bytes())
        message = base64.b64decode(value['signedBOC'],validate=True) if value.get('signedBOC') else None
        return dict(current, operation_id=value['id'], phase=value['phase'],
            has_signed_boc=message is not None,
            signed_boc_sha256=hashlib.sha256(message).hexdigest() if message else None,
            request_hash_b64=value['requestHash'], fee_confirmed=value.get('feeApproval') is not None,
            intent=value.get('paymentIntent'))

    def fund_inner():
        current = snapshot()
        address = current['address']
        if address in funding_ledger:
            return funding_ledger[address]
        if address in faucet_attempts:
            raise ValueError('unknown previous faucet result; refusing another transfer')
        if len(faucet_attempts) >= 8:
            raise ValueError('bounded fixture account limit')
        faucet_attempts.add(address)
        write_json('faucet-attempts.json', sorted(faucet_attempts))
        request = urllib.request.Request(a.funding_control.rstrip('/') + '/transfer',
            data=json.dumps({'address': address, 'amount': 10}).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=65) as response:
            reply = json.loads(response.read(65537))
        if int(reply['after']) - int(reply['before']) != 10_000_000_000:
            raise ValueError('unexpected funding delta')
        funded = dict(current, nanos='10000000000', status='funded')
        funding_ledger[address] = funded
        write_json('fund.json', funded)
        write_json('funding-ledger.json', list(funding_ledger.values()))
        return funded

    def fund():
        with fund_lock: return fund_inner()

    class BoundedServer(ThreadingHTTPServer):
        daemon_threads = True
        request_queue_size = 4
        slots = threading.BoundedSemaphore(4)
        def process_request(self, request, address):
            if not self.slots.acquire(blocking=False):
                try: request.sendall(b'HTTP/1.0 503 Busy\r\nContent-Length: 0\r\n\r\n')
                finally: self.shutdown_request(request)
                return
            try: super().process_request(request, address)
            except BaseException:
                self.slots.release(); raise
        def process_request_thread(self, request, address):
            try: super().process_request_thread(request,address)
            finally: self.slots.release()

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
                if self.path.startswith('/__quantum_payment/'):
                    if raw != b'{}': raise ValueError('control requires empty object')
                    action = self.path.rsplit('/',1)[-1]
                    if action == 'pending': value = pending()
                    elif action in ('normal','accept-delay-error'):
                        with state_lock:
                            submission_mode['mode'] = action
                            value = dict(submission_mode)
                    elif action == 'status':
                        with state_lock:
                            value = dict(submission_mode, events=list(submission_events), submissions=list(submissions))
                    else: raise ValueError('unknown payment control')
                    write_json('payment-' + action + '.json',value)
                    self.send(200,value); return
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
                if method == 'sendBocReturnHash':
                    encoded = query.get('params', {}).get('boc')
                    if not isinstance(encoded, str):
                        raise ValueError('missing App public submission')
                    data = base64.b64decode(encoded, validate=True)
                    if not 1 <= len(data) <= 1048576:
                        raise ValueError('App submission limit')
                    cell = from_boc(data)
                    digest = hashlib.sha256(data).hexdigest()
                    journal = pending()
                    if journal.get('phase') != 'submitting' or journal.get('signed_boc_sha256') != digest or not journal.get('fee_confirmed'):
                        raise ValueError('App dispatched before exact journal/fee confirmation publication')
                    with state_lock:
                        if len(submission_events) >= 32: raise ValueError('submission event limit')
                        event = {'bytes_sha256':digest,'phase_before_dispatch':journal['phase'],
                            'operation_id':journal['operation_id'],'upstream_returned':False,
                            'mode':submission_mode['mode'],'delay_ms':submission_mode['delay_ms']}
                        submission_events.append(event)
                        write_json('submission-events.json',submission_events)

                    name = 'app-submit-' + digest + '.boc'
                    if digest not in [entry['bytes_sha256'] for entry in submissions]:
                        if len(submissions) >= 32:
                            raise ValueError('App submission count limit')
                        (a.out / name).write_bytes(data)
                        submissions.append({'file':name,'bytes':len(data),'bytes_sha256':digest,
                            'external_root':cell.hash.hex(),'scope':'Public signed BOC forwarded by the App; no secret custody material read'})
                        (a.out / 'app-submissions.json').write_text(json.dumps(submissions,indent=2)+'\n')
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
                if method == 'sendBocReturnHash':
                    with state_lock:
                        event['upstream_returned'] = True
                        event['upstream_response_sha256'] = hashlib.sha256(raw).hexdigest()
                        write_json('upstream-submit-response.json', json.loads(raw))
                        write_json('submission-events.json',submission_events)
                    if event['mode'] == 'accept-delay-error':
                        time.sleep(event['delay_ms']/1000)
                        self.send(503, {'jsonrpc':'2.0','id':query.get('id'),
                            'error':{'code':-32000,'message':'Injected lost response after upstream returned; inclusion is not inferred'}})
                        return
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
            except (BrokenPipeError, ConnectionResetError):
                return
            except Exception as error:
                value = {'error': type(error).__name__ + ': ' + str(error)}
                (a.out / 'last-error.json').write_text(json.dumps(value, indent=2) + '\n')
                self.send(500, value)

    server = BoundedServer(('127.0.0.1', a.port), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
