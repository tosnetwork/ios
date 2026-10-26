"""Bounded public RPC fixture for classic recovery UI, without chain-proof claims."""
import argparse
import base64
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def cell(payload):
    # One ordinary byte-aligned cell, one root, no index or CRC.
    body = bytes([0, len(payload) * 2]) + payload
    return base64.b64encode(bytes.fromhex('b5ee9c720101010100') +
                            bytes([len(body), 0]) + body).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18648)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise ValueError('invalid loopback fixture port')
    count = 0

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            nonlocal count
            count += 1
            self.connection.settimeout(3)
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 65536:
                    raise ValueError('request size')
                request = json.loads(self.rfile.read(size))
                method = request['method']
                params = request.get('params', {})
                result = None
                if method == 'getConfigParam' and params.get('param') in (8, 19):
                    payload = bytes.fromhex('00000003') if params['param'] == 19 else bytes.fromhex('c400000010' + '00' * 8)
                    result = {'config': {'bytes': cell(payload)}}
                elif method == 'getAddressInformation':
                    result = {'balance': '1000000000', 'state': 'uninitialized',
                              'code': '', 'data': '', 'sync_utime': int(time.time())}
                elif method in ('getAccountTokens', 'getAccountNfts'):
                    tokens = method == 'getAccountTokens'
                    result = {'@type': 'wallet.accountTokens' if tokens else 'wallet.accountNfts',
                              'tokens' if tokens else 'nfts': [], 'index_state': {'complete': True}}
                elif method == 'getTransactions':
                    result = []
                answer = {'jsonrpc': '2.0', 'id': request.get('id')}
                if result is None:
                    answer['error'] = {'code': -32601, 'message': 'Unsupported public fixture method'}
                else:
                    answer['result'] = result
                encoded = json.dumps(answer).encode()
                print(json.dumps({'method': method, 'address': params.get('address'), 'count': count}), flush=True)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except (ValueError, KeyError, OSError):
                self.close_connection = True

    with HTTPServer(('127.0.0.1', args.port), Handler) as server:
        server.timeout = 1
        deadline = time.monotonic() + 600
        print('PUBLIC_CLASSIC_FIXTURE_READY', flush=True)
        while count < 512 and time.monotonic() < deadline:
            server.handle_request()


if __name__ == '__main__':
    main()
