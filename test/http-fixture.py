"""Exercise Emacs commands against a real local MCP HTTP fixture.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

calls = []
errors = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        try:
            assert self.path == '/mcp'
            assert self.headers.get('Authorization') == 'Bearer fixture-token'
            data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            method = data['method']
            if method != 'initialize':
                assert self.headers.get('Mcp-Session-Id') == 'fixture-mcp-session'
            if method == 'notifications/initialized':
                self.send_response(202)
                self.end_headers()
                return
            if method == 'initialize':
                result = {'protocolVersion': data['params']['protocolVersion'],
                          'serverInfo': {'name': 'fixture', 'version': '1.0'},
                          'capabilities': {'tools': {}}}
            elif method == 'tools/list':
                result = {'tools': [{'name': name, 'inputSchema': {'type': 'object'}}
                                    for name in ('session', 'navigate', 'read', 'output')]}
            elif method == 'tools/call':
                tool = data['params']['name']
                args = data['params']['arguments']
                calls.append((tool, args))
                op = args['operation']
                if op == 'create':
                    assert 'session_id' not in args
                    structured = {'session_id': 'fixture-browser', 'status': 'active'}
                else:
                    assert args['session_id'] == 'fixture-browser'
                    structured = {'session_id': 'fixture-browser'}
                if tool == 'navigate':
                    assert args['url'] == 'https://example.com'
                    structured['title'] = 'Example Domain'
                if tool == 'read':
                    assert args['selector'] == 'body'
                    structured['text'] = 'Example Domain'
                if op == 'close':
                    structured['ok'] = True
                result = {'structuredContent': structured,
                          'content': [{'type': 'text', 'text': json.dumps(structured)}]}
                if tool == 'output':
                    result['content'].append({'type': 'image', 'mimeType': 'image/png',
                                              'data': 'UE5H'})
            else:
                raise AssertionError(method)
            raw = json.dumps({'jsonrpc': '2.0', 'id': data['id'], 'result': result}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Mcp-Session-Id', 'fixture-mcp-session')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        except Exception as error:
            errors.append(repr(error))
            self.send_error(500)


with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(os.environ, LEXMOUNT_FIXTURE_PORT=str(server.server_port))
    try:
        subprocess.run([os.environ.get('EMACS', 'emacs'), '-Q', '--batch',
                        '-l', 'test/http-test.el'], check=True, env=env, timeout=40)
        assert not errors, errors
        assert [args['operation'] for _, args in calls] == [
            'create', 'open_url', 'get_text', 'screenshot', 'close'], calls
        print('MCP HTTP command journey passed; 5 tool calls, no retries.')
    finally:
        server.shutdown()
