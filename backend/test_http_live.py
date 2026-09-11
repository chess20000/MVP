#!/usr/bin/env python3
"""Synthetic protocol checks; never read input-method history or user text."""
import argparse
import http.client
import json
import time
from pathlib import Path
from server import TokenBytes

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=18082)
parser.add_argument('--model', type=Path, required=True, help='local MiniCPM5-1B-4bit directory')
args = parser.parse_args()
config = json.loads((args.model / 'config.json').read_text())
pieces = TokenBytes.from_json(json.loads((args.model / 'tokenizer.json').read_text()), config['vocab_size'])

def connection():
    return http.client.HTTPConnection('127.0.0.1', args.port, timeout=5)

def post(path, body, expected=200):
    c = connection()
    c.request('POST', path, json.dumps(body), {'Content-Type': 'application/json'})
    r = c.getresponse()
    assert r.status == expected, (path, r.status)
    result = json.loads(r.read())
    c.close()
    return result

def complete(prompt, count=7, cancel=False):
    c = connection()
    started = time.perf_counter()
    c.request('POST', '/completion', json.dumps({'prompt': prompt, 'n_predict': count, 'stream': True}), {'Content-Type': 'application/json'})
    r = c.getresponse()
    assert r.status == 200
    events, arrived = [], []
    final = None
    for line in r:
        if not line.startswith(b'data: '):
            continue
        event = json.loads(line[6:])
        assert 'error' not in event, event
        if event.get('stop'):
            final = event
            continue
        for item in event['completion_probabilities']:
            token, raw = item['id'], bytes(item['bytes'])
            assert raw == pieces.pieces[token]
            assert token not in pieces.blocked
            assert event['tokens'] == [token]
            events.append(token)
            arrived.append(time.perf_counter() - started)
        if cancel:
            break
    r.close()
    c.close()
    if not cancel:
        assert len(events) == count and final['tokens_predicted'] == count
    return events, {'first_ms': round(arrived[0] * 1000), 'last_ms': round(arrived[-1] * 1000), 'tokens': len(events)}

c = connection()
c.request('GET', '/health')
health = json.loads(c.getresponse().read())
c.close()
assert health['backend'] == 'mlx' and health['context_size'] == 512
short = post('/tokenize', {'content': '今天下午我们一起去', 'add_special': False})['tokens']
assert post('/tokenize', {'content': ''})['tokens'] == []
long_ids = post('/tokenize', {'content': '我希望输入法能够根据正在书写的内容提供自然准确的中文续写。' * 100})['tokens']
initial, short_metrics = complete(short)
tail, refill_metrics = complete(short + initial, 1)
assert len(initial[1:] + tail) == 7
_, full_metrics = complete(long_ids[-505:])
_, repeated_metrics = complete(long_ids[-505:])
post('/completion', {'prompt': long_ids[-506:], 'n_predict': 7}, 400)
post('/completion', {'prompt': short, 'n_predict': 8}, 400)
post('/completion', {'prompt': [True], 'n_predict': 1}, 400)
complete(long_ids[-256:], cancel=True)
_, after_cancel = complete(short)
assert after_cancel['last_ms'] < 3000
print(json.dumps({'status': 'passed', 'short': short_metrics, 'one_token_refill': refill_metrics, '505_input': full_metrics, '505_repeated': repeated_metrics, 'after_cancel': after_cancel}, ensure_ascii=False))
