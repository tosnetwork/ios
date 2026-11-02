"""Exercise actual loopback fixture startup, protocol replies and bind refusal."""
import contextlib
import json
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import unittest
import urllib.request
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, HTTPServer

FIXTURE = Path(__file__).with_name('classic_recovery_fixture.py')
BOOTSTRAP = '''
import runpy, socket, sys
def deny_reverse_dns(*args, **kwargs):
    raise RuntimeError("INJECTED_REVERSE_DNS_REFUSAL")
socket.getfqdn = deny_reverse_dns
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
'''


@contextlib.contextmanager
def fixture(port):
    process = subprocess.Popen([sys.executable, '-u', '-c', BOOTSTRAP, str(FIXTURE), '--port', str(port)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=3)


def unused_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def ready_line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=5):
            raise AssertionError('Fixture did not report readiness within bounded startup')
        return process.stdout.readline().strip()


class ClassicRecoveryFixtureTests(unittest.TestCase):
    def test_positive_control_default_server_reaches_reverse_dns(self):
        with patch.object(socket, 'getfqdn', side_effect=RuntimeError('INJECTED_REVERSE_DNS_REFUSAL')):
            with self.assertRaisesRegex(RuntimeError, 'INJECTED_REVERSE_DNS_REFUSAL'):
                HTTPServer(('127.0.0.1', 0), BaseHTTPRequestHandler)

    def test_numeric_loopback_fixture_starts_and_serves_without_reverse_dns(self):
        port = unused_port()
        with fixture(port) as process:
            self.assertEqual('PUBLIC_CLASSIC_FIXTURE_READY', ready_line(process))
            self.assertIsNone(process.poll())
            def rpc(method, params):
                request = urllib.request.Request('http://127.0.0.1:' + str(port),
                    data=json.dumps({'jsonrpc': '2.0', 'id': 'fixture-control', 'method': method, 'params': params}).encode(),
                    headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=3) as response:
                    return json.load(response)
            config = rpc('getConfigParam', {'param': 19})
            self.assertEqual('fixture-control', config['id'])
            self.assertTrue(config['result']['config']['bytes'])
            account = rpc('getAddressInformation', {'address': 'public-test-address'})
            self.assertEqual('0', account['result']['balance'])
            self.assertEqual('active', account['result']['state'])
            self.assertEqual(-32601, rpc('unsupported', {})['error']['code'])

    def test_occupied_port_never_reports_ready(self):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0)); occupied.listen(1)
            with fixture(occupied.getsockname()[1]) as process:
                output, _ = process.communicate(timeout=5)
                self.assertNotEqual(0, process.returncode)
                self.assertNotIn('PUBLIC_CLASSIC_FIXTURE_READY', output)
                self.assertIn('OSError', output)


if __name__ == '__main__':
    unittest.main()
