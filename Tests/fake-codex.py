#!/usr/bin/python3
"""Local protocol fixture. It never accesses credentials or the network."""
import json
import os
import sys
import time

def send(value, split=False):
    encoded = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    if split:
        # Deliberately split UTF-8 characters and JSON tokens across reads.
        for i in range(0, len(encoded), 3):
            os.write(1, encoded[i:i + 3])
            time.sleep(0.001)
    else:
        os.write(1, encoded)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    ident = request.get('id')
    if method == 'initialize':
        send({'id': ident, 'result': {'userAgent': 'orbit-test'}}, split=True)
    elif method == 'initialized':
        send({'method': 'test/notification', 'params': {'message': '薄荷'}})
        send({'id': 'server-request', 'method': 'test/unsupportedAction', 'params': {}})
    elif method == 'test/chunks':
        send({'id': ident, 'result': {'unicode': '薄荷圆环', 'number': 7}}, split=True)
    elif method == 'test/error':
        send({'id': ident, 'error': {'code': -32001, 'message': 'upstream unavailable'}})
    elif method == 'test/timeout':
        pass
    elif method == 'test/exit':
        sys.exit(0)
    elif method == 'test/echo':
        send({'id': ident, 'result': request.get('params', {})})
    # The client's MethodNotFound reply intentionally has no method.
