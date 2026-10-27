"""Loopback-only dishonest transaction metadata and raw-cell corruption fixture.

For disposable public test chains. Proof replies are forwarded unchanged. Only
getTransactions metadata is falsified; corrupt mode also changes one real fee
bit in its raw transaction while preserving a well-formed ordinary BOC.
"""
import argparse
import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True, type=int)
    p.add_argument('--upstream', required=True)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--tos-root', required=True, type=Path)
    a = p.parse_args()
    endpoint = urllib.parse.urlsplit(a.upstream)
    if (endpoint.scheme != 'http' or endpoint.hostname not in ('127.0.0.1', 'localhost')
            or endpoint.username or endpoint.password or endpoint.path or endpoint.query or endpoint.fragment):
        raise ValueError('requires a loopback native node')
    a.out.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(a.tos_root / 'test/auth-extensions'))
    from cells import from_boc
    mode = 'normal'
    traffic = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, status, value):
            raw = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            nonlocal mode
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 <= length <= 2 * 1024 * 1024:
                    raise ValueError('request limit')
                raw = self.rfile.read(length)
                query = json.loads(raw)
                if self.path == '/__history_mode':
                    if set(query) != {'mode'} or query['mode'] not in ('normal', 'corrupt'):
                        raise ValueError('invalid control')
                    mode = query['mode']
                    (a.out / 'mode.json').write_text(json.dumps({'mode': mode}) + '\n')
                    self.send(200, {'mode': mode})
                    return
                method = query.get('method', self.path.lstrip('/'))
                request = urllib.request.Request(a.upstream + self.path, data=raw, headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=35) as response:
                    reply = response.read(2 * 1024 * 1024 + 1)
                if len(reply) > 2 * 1024 * 1024:
                    raise ValueError('reply limit')
                if method == 'getTransactions':
                    value = json.loads(reply)
                    for tx in value.get('result', []):
                        tx.update(fee='999999999999', utime=0, aborted=True,
                                  compute={'success': False, 'exit_code': -1},
                                  action={'success': False, 'result_code': -1},
                                  transaction_id={'lt': '0', 'hash': 'AA=='})
                        if mode == 'corrupt':
                            cell = from_boc(base64.b64decode(tx['data'], validate=True))
                            # Transaction's fixed header is 695 bits; total_fees
                            # begins with VarUInteger16 after the messages ref.
                            size = int(cell.bits[695:699], 2)
                            if not 1 <= size <= 15:
                                raise ValueError('expected positive native test transaction fees')
                            offset = 699 + 8 * size - 1
                            cell.bits = cell.bits[:offset] + str(1 - int(cell.bits[offset])) + cell.bits[offset + 1:]
                            tx['data'] = base64.b64encode(cell.boc()).decode()
                    reply = json.dumps(value).encode()
                if len(traffic) < 128:
                    traffic.append({'method': method, 'mode': mode})
                (a.out / 'traffic.json').write_text(json.dumps(traffic, indent=2) + '\n')
                self.send(200, reply)
            except urllib.error.HTTPError as error:
                self.send(error.code, error.read(4096))
            except Exception as error:
                value = {'error': type(error).__name__ + ': ' + str(error)}
                (a.out / 'last-error.json').write_text(json.dumps(value) + '\n')
                self.send(500, value)

    server = HTTPServer(('127.0.0.1', a.port), Handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
