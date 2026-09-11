#!/usr/bin/env python3
"""Isolated, synthetic MLX cache regression checks; never opens a server or UI.

Run only after the other temporary MLX process has exited. This script loads one
model, runs deterministic requests, and exits to release its GPU allocations.
"""

from __future__ import annotations

import argparse
import gc
import importlib.util
import json
import os
from pathlib import Path
import sys
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--server", type=Path, default=Path(__file__).with_name("server.py"))
    parser.add_argument("--output", type=Path, help="optional JSON report path; no report file by default")
    args = parser.parse_args()
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"

    spec = importlib.util.spec_from_file_location("cache_test_adapter", args.server)
    adapter = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = adapter
    spec.loader.exec_module(adapter)
    load_started = time.perf_counter()
    engine = adapter.ModelEngine(args.model.resolve())
    engine.sampler = lambda logits: engine.mx.argmax(logits, axis=-1)
    results = []
    prepares = []
    original_prepare = engine._prepare_cache

    def observe_prepare(prompt):
        cache, uncached = original_prepare(prompt)
        prepares.append({"prompt_tokens": len(prompt), "uncached_tokens": len(uncached)})
        return cache, uncached

    engine._prepare_cache = observe_prepare

    def cache_state():
        assert not engine.generation_lock.locked(), "generation lock leaked"
        if engine.cache is None:
            assert engine.cache_tokens == ()
            return {"offset": 0, "cache_types": [], "cached_tokens": 0}
        offset = engine._offset(engine.cache)
        assert offset is not None and 0 < offset <= adapter.CONTEXT_SIZE, offset
        assert offset == len(engine.cache_tokens), (offset, len(engine.cache_tokens))
        return {
            "offset": offset,
            "cached_tokens": len(engine.cache_tokens),
            "cache_types": sorted({type(layer).__name__ for layer in engine.cache}),
        }

    def request(ids, count):
        return adapter.validate_completion(
            {"prompt": list(ids), "n_predict": count, "stream": True}, engine.vocab_size
        )

    def run(ids, count):
        before = len(prepares)
        started = time.perf_counter()
        output = list(engine.complete(request(ids, count), lambda: False))
        elapsed = time.perf_counter() - started
        assert len(output) == count, (len(output), count)
        assert all(token not in engine.blocked for token, raw in output)
        assert all(raw == engine.token_bytes.pieces[token] for token, raw in output)
        raw = b"".join(raw for _, raw in output)
        decoded = engine.tokenizer.decode([token for token, _ in output], skip_special_tokens=False)
        assert raw.decode("utf-8", errors="replace") == decoded
        state = cache_state()
        assert len(prepares) == before + 1
        return output, {**state, **prepares[-1], "seconds": elapsed}

    def compare(name, ids, count=7, require_reuse=True):
        cached, cached_info = run(ids, count)
        saved_cache, saved_tokens = engine.cache, engine.cache_tokens
        engine.cache, engine.cache_tokens = None, ()
        fresh, fresh_info = run(ids, count)
        assert cached == fresh, {
            "case": name,
            "cached_ids": [token for token, _ in cached],
            "fresh_ids": [token for token, _ in fresh],
        }
        if require_reuse:
            assert cached_info["uncached_tokens"] < len(ids), cached_info
        engine.cache, engine.cache_tokens = saved_cache, saved_tokens
        cache_state()
        row = {
            "case": name,
            "passed": True,
            "prompt_tokens": len(ids),
            "generated_tokens": len(cached),
            "output_ids": [token for token, _ in cached],
            "bytes_match_fresh": True,
            "cached": cached_info,
            "fresh": fresh_info,
        }
        results.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        return cached

    # Repeated and changed prefixes must match recomputation with the same sampler.
    prefix = tuple(engine.tokenize("今天天气很好，我想去公园里"))
    assert len(prefix) > 2
    run(prefix, 7)
    compare("same_prefix", prefix)
    changed = prefix[:-1] + tuple(engine.tokenize("慢慢散步，顺便"))
    compare("changed_suffix", changed)

    # Tab shifts only one queued token into input; the retained six are immutable.
    initial, _ = run(prefix, 7)
    retained = tuple(initial[1:])
    rolling_prompt = prefix + tuple(token for token, _ in initial)
    eighth = compare("seven_then_append_only_eighth", rolling_prompt, count=1)
    queue = retained + tuple(eighth)
    assert len(queue) == 7 and queue[:6] == retained

    # Exercise the exact 505-input + 7-output limit before both reuse and editing.
    long_text = "今天我们讨论输入法的续写功能，要求普通中文输入稳定，光标后面有字时不要续写。" * 40
    long_ids = tuple(engine.tokenize(long_text)[-505:])
    assert len(long_ids) == 505
    _, boundary_info = run(long_ids, 7)
    assert boundary_info["offset"] == 512, boundary_info
    compare("same_prefix_after_505_plus_7_boundary", long_ids)
    tail = tuple(engine.tokenize("现在"))
    changed_long = long_ids[:-len(tail)] + tail
    assert len(changed_long) == 505 and changed_long != long_ids
    compare("changed_suffix_after_505_plus_7_boundary", changed_long)

    # A disconnect after the first streamed token must release the lock, discard
    # any unknown prefetched state, and leave a subsequent request correct.
    state = {"disconnected": False}
    iterator = engine.complete(request(prefix, 7), lambda: state["disconnected"])
    first = next(iterator)
    assert first[0] not in engine.blocked
    state["disconnected"] = True
    try:
        next(iterator)
        raise AssertionError("disconnect did not stop generation")
    except adapter.ClientDisconnected:
        pass
    finally:
        iterator.close()
    after_disconnect = cache_state()
    compare("request_after_stream_disconnect", prefix, require_reuse=False)

    # Closing a partially consumed iterator is the HTTP broken-pipe cleanup path.
    iterator = engine.complete(request(prefix, 7), lambda: False)
    next(iterator)
    iterator.close()
    after_close = cache_state()
    compare("request_after_early_generator_close", prefix, require_reuse=False)

    # Cancellation before any model work must also leave its lock available.
    iterator = engine.complete(request(prefix, 7), lambda: True)
    try:
        next(iterator)
        raise AssertionError("already disconnected client was accepted")
    except adapter.ClientDisconnected:
        pass
    finally:
        iterator.close()
    cache_state()
    compare("request_after_prestart_disconnect", prefix)

    report = {
        "passed": True,
        "model": str(args.model.resolve()),
        "server": str(args.server.resolve()),
        "load_and_checks_seconds": time.perf_counter() - load_started,
        "cases": results,
        "cache_after_disconnect": after_disconnect,
        "cache_after_generator_close": after_close,
        "mlx_peak_mb": engine.mx.get_peak_memory() / 1e6,
    }
    if args.output:
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": True, "cases": len(results), "report": str(args.output) if args.output else None}, ensure_ascii=False), flush=True)
    engine.cache, engine.cache_tokens = None, ()
    engine.mx.synchronize()
    del engine
    gc.collect()


if __name__ == "__main__":
    main()
