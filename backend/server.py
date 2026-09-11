#!/usr/bin/env python3
"""Loopback MLX continuation service for Squirrel's llama.cpp-shaped requests.

Tested API target: mlx-lm 0.31.3, mlx-community/MiniCPM5-1B-4bit.
No chat template, disk prompt cache, access log, or remote model code is used.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import select
import socket
import sys
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterator


CONTEXT_SIZE = 512
MAX_INPUT = 505
MAX_OUTPUT = 7
MAX_CURRENT_INPUT = 256
CONTINUATION_INSTRUCTION = "补全这段日常生活中的对话："
MAX_BODY_BYTES = 1_048_576


class InvalidRequest(ValueError):
    """An invalid request, with a fixed message that contains no input text."""


class ClientDisconnected(Exception):
    pass


@dataclass(frozen=True)
class CompletionRequest:
    prompt: tuple[int, ...]
    count: int


def validate_completion(body: Any, vocab_size: int) -> CompletionRequest:
    if not isinstance(body, dict):
        raise InvalidRequest("body must be an object")
    prompt = body.get("prompt")
    count = body.get("n_predict", MAX_OUTPUT)
    if not isinstance(prompt, list) or not 1 <= len(prompt) <= MAX_INPUT:
        raise InvalidRequest("prompt must contain 1 to 505 token IDs")
    if any(type(token) is not int or not 0 <= token < vocab_size for token in prompt):
        raise InvalidRequest("prompt contains an invalid token ID")
    if type(count) is not int or not 1 <= count <= MAX_OUTPUT:
        raise InvalidRequest("n_predict must be an integer from 1 to 7")
    if len(prompt) + count > CONTEXT_SIZE:
        raise InvalidRequest("context exceeds 512 tokens")
    if body.get("stream", True) is not True:
        raise InvalidRequest("only streaming completion is supported")
    return CompletionRequest(tuple(prompt), count)


def prepare_completion(body: Any, engine: Any) -> tuple[CompletionRequest, dict[str, Any] | None]:
    """Prefix up to 256 current-text tokens with a fixed continuation instruction."""
    if not isinstance(body, dict):
        raise InvalidRequest("body must be an object")
    if "prompt_text" not in body:
        if "composition_text" in body:
            raise InvalidRequest("composition prediction is no longer supported")
        if "history_texts" in body:
            raise InvalidRequest("history_texts requires prompt_text")
        return validate_completion(body, engine.vocab_size), None
    if "prompt" in body:
        raise InvalidRequest("prompt and prompt_text are mutually exclusive")
    prefix = body["prompt_text"]
    if not isinstance(prefix, str):
        raise InvalidRequest("prompt_text must be a string")
    if "history_texts" in body:
        raise InvalidRequest("selection history is no longer supported")
    if "composition_text" in body:
        raise InvalidRequest("composition prediction is no longer supported")
    count = body.get("n_predict", MAX_OUTPUT)
    if type(count) is not int or not 1 <= count <= MAX_OUTPUT:
        raise InvalidRequest("incorrect token count for text request mode")

    context_tokens = list(engine.tokenize(prefix))[-MAX_CURRENT_INPUT:]
    instruction_tokens = list(engine.tokenize(CONTINUATION_INSTRUCTION))
    if not instruction_tokens or len(instruction_tokens) > MAX_INPUT - MAX_CURRENT_INPUT:
        raise RuntimeError("continuation instruction exceeds reserved input budget")
    request = validate_completion({
        "prompt": instruction_tokens + context_tokens,
        "n_predict": count,
        "stream": body.get("stream", True),
    }, engine.vocab_size)
    return request, {
        "context_tokens": context_tokens,
        "instruction_tokens": instruction_tokens,
        "tokens_predicted": 0,
        "stop": False,
    }


def bytelevel_inverse() -> dict[str, int]:
    """The inverse of the reversible GPT-2 ByteLevel byte alphabet."""
    visible = list(range(ord("!"), ord("~") + 1))
    visible += list(range(0xA1, 0xAD)) + list(range(0xAE, 0x100))
    alphabet = list(visible)
    extra = 0
    for value in range(256):
        if value not in visible:
            visible.append(value)
            alphabet.append(256 + extra)
            extra += 1
    return {chr(character): value for value, character in zip(visible, alphabet)}


@dataclass(frozen=True)
class TokenBytes:
    pieces: tuple[bytes, ...]
    blocked: frozenset[int]

    @classmethod
    def from_json(cls, data: dict[str, Any], vocab_size: int) -> TokenBytes:
        # This exact model uses ByteLevel. Fail closed for other decoders instead of
        # guessing SentencePiece/Metaspace semantics or losing partial UTF-8 bytes.
        if data.get("decoder", {}).get("type") != "ByteLevel":
            raise ValueError("this adapter requires a ByteLevel tokenizer decoder")
        if data.get("model", {}).get("type") != "BPE":
            raise ValueError("this adapter requires a BPE vocabulary")
        inverse = bytelevel_inverse()
        pieces = [b""] * vocab_size
        blocked: set[int] = set()
        for piece, token in data["model"]["vocab"].items():
            if type(token) is not int or not 0 <= token < vocab_size:
                raise ValueError("tokenizer vocabulary does not match model vocabulary")
            try:
                pieces[token] = bytes(inverse[character] for character in piece)
            except KeyError as error:
                raise ValueError("unexpected non-ByteLevel vocabulary character") from error

        for added in data.get("added_tokens", []):
            token, text = added["id"], added["content"]
            if not 0 <= token < vocab_size:
                raise ValueError("added token is outside the model vocabulary")
            control = (
                added.get("special", False)
                or text in {"<think>", "</think>"}
                or re.fullmatch(r"<unused_token_\d+>", text) is not None
            )
            if control:
                blocked.add(token)
                # Control tokens remain tokenizable as input but cannot be sampled.
                pieces[token] = text.encode("utf-8")
            elif not pieces[token]:
                raise ValueError("unsupported ordinary added token")

        for token, raw in enumerate(pieces):
            # Do not filter on whether an individual token is valid UTF-8: normal
            # Chinese/emoji tokens can hold only part of a Unicode character.
            if not raw or any(value < 32 or value == 127 for value in raw):
                blocked.add(token)
        return cls(tuple(pieces), frozenset(blocked))


def common_prefix_length(left: tuple[int, ...], right: tuple[int, ...]) -> int:
    for index, (a, b) in enumerate(zip(left, right)):
        if a != b:
            return index
    return min(len(left), len(right))


class ModelEngine:
    def __init__(self, model_path: Path):
        import mlx.core as mx
        from mlx_lm import load, stream_generate
        from mlx_lm.models.cache import (
            can_trim_prompt_cache,
            make_prompt_cache,
            trim_prompt_cache,
        )
        from mlx_lm.sample_utils import make_logits_processors, make_sampler

        self.mx = mx
        self.stream_generate = stream_generate
        self.make_prompt_cache = make_prompt_cache
        self.can_trim = can_trim_prompt_cache
        self.trim_cache = trim_prompt_cache
        self.model, self.tokenizer, config = load(
            str(model_path),
            tokenizer_config={"trust_remote_code": False, "local_files_only": True},
            lazy=False,
            return_config=True,
        )
        # M1's BF16 execution can change near-tied token rankings when prefill
        # batch shapes differ. FP16 keeps the four-bit integer weights unchanged
        # and gives the cached/fresh paths consistent results in regression tests.
        from mlx.utils import tree_flatten

        integers_before = [
            (name, str(value.dtype), value.shape, value.nbytes)
            for name, value in tree_flatten(self.model.parameters())
            if not mx.issubdtype(value.dtype, mx.floating)
        ]
        self.model.set_dtype(mx.float16)
        mx.eval(self.model.parameters())
        integers_after = [
            (name, str(value.dtype), value.shape, value.nbytes)
            for name, value in tree_flatten(self.model.parameters())
            if not mx.issubdtype(value.dtype, mx.floating)
        ]
        if integers_before != integers_after:
            raise RuntimeError("floating dtype conversion changed integer weight metadata")
        self.model.eval()
        self.vocab_size = int(config["vocab_size"])
        with (model_path / "tokenizer.json").open(encoding="utf-8") as source:
            self.token_bytes = TokenBytes.from_json(json.load(source), self.vocab_size)
        blocked = set(self.token_bytes.blocked)
        blocked.update(int(token) for token in self.tokenizer.eos_token_ids)
        blocked.update(int(token) for token in self.tokenizer.all_special_ids)
        if any(not 0 <= token < self.vocab_size for token in blocked):
            raise ValueError("a special token is outside the model vocabulary")
        self.blocked = frozenset(blocked)
        self.blocked_mask = mx.array([index in blocked for index in range(self.vocab_size)])
        mx.eval(self.blocked_mask)
        self.sampler = make_sampler(temp=0.2, top_p=0.8, top_k=20)
        self.repetition_processors = make_logits_processors(
            repetition_penalty=1.1, repetition_context_size=64
        )
        self.generation_lock = threading.Lock()
        self.tokenizer_lock = threading.Lock()
        self.cache = None
        self.cache_tokens: tuple[int, ...] = ()
        # Compile Metal kernels before /health can report ready. Otherwise the first
        # real input may exceed the frontend's three-second request timeout.
        warm_text = "今天我们准备把这段文字继续写完。"
        warm_short = tuple(self.tokenize(warm_text))
        warm_long = tuple(self.tokenize(warm_text * 128))
        for warm_prompt in (warm_short, warm_long[-256:], warm_long[-505:]):
            self.cache = None
            self.cache_tokens = ()
            list(self.complete(CompletionRequest(warm_prompt, MAX_OUTPUT), lambda: False))
        self.cache = None
        self.cache_tokens = ()

    def tokenize(self, text: str) -> list[int]:
        with self.tokenizer_lock:
            return list(self.tokenizer.encode(text, add_special_tokens=False))

    def _offset(self, cache: Any) -> int | None:
        offsets = [getattr(layer, "offset", None) for layer in cache]
        if not offsets or any(type(offset) is not int for offset in offsets):
            return None
        if any(offset != offsets[0] for offset in offsets):
            return None
        return offsets[0]

    def _prepare_cache(self, prompt: tuple[int, ...]) -> tuple[Any, tuple[int, ...]]:
        if self.cache is not None and self._offset(self.cache) == len(self.cache_tokens):
            shared = min(common_prefix_length(self.cache_tokens, prompt), len(prompt) - 1)
            to_trim = len(self.cache_tokens) - shared
            if shared > 0 and (
                to_trim == 0
                or (self.can_trim(self.cache) and self.trim_cache(self.cache, to_trim) == to_trim)
            ):
                if self._offset(self.cache) == shared:
                    return self.cache, prompt[shared:]
        self.cache = self.make_prompt_cache(self.model, max_kv_size=CONTEXT_SIZE)
        self.cache_tokens = ()
        return self.cache, prompt

    def _save_cache(self, cache: Any, known_tokens: tuple[int, ...]) -> None:
        offset = self._offset(cache)
        # generate_step prefetches one token. Only retain state whose complete input
        # sequence is known, with equal offsets across all layers and no rotation.
        if offset is not None and 0 < offset <= min(CONTEXT_SIZE, len(known_tokens)):
            self.cache = cache
            self.cache_tokens = known_tokens[:offset]
        else:
            self.cache = None
            self.cache_tokens = ()

    def complete(
        self, request: CompletionRequest, disconnected: Callable[[], bool]
    ) -> Iterator[tuple[int, bytes]]:
        while not self.generation_lock.acquire(timeout=0.05):
            if disconnected():
                raise ClientDisconnected()
        generator = None
        cache = None
        generated: list[int] = []
        healthy = True
        try:
            if disconnected():
                raise ClientDisconnected()
            cache, uncached = self._prepare_cache(request.prompt)
            # generate_step pre-fills all but the final prompt token before its
            # processors run. Restore that history, including when a KV prefix is
            # reused, so the repetition penalty sees the same last 64 tokens.
            penalty_prefix = self.mx.array(request.prompt[:-1], dtype=self.mx.int32)

            def check_connection(*_args: Any) -> None:
                if disconnected():
                    raise ClientDisconnected()

            def mask_controls(_tokens: Any, logits: Any) -> Any:
                check_connection()
                history = self.mx.concatenate([penalty_prefix, _tokens])
                for processor in self.repetition_processors:
                    logits = processor(history, logits)
                return self.mx.where(self.blocked_mask, -float("inf"), logits)

            generator = self.stream_generate(
                self.model,
                self.tokenizer,
                prompt=list(uncached),
                max_tokens=request.count,
                sampler=self.sampler,
                logits_processors=[mask_controls],
                prompt_cache=cache,
                max_kv_size=CONTEXT_SIZE,
                prefill_step_size=128,
                prompt_progress_callback=check_connection,
            )
            for response in generator:
                check_connection()
                token = int(response.token)
                if token in self.blocked or not 0 <= token < self.vocab_size:
                    raise RuntimeError("model sampled a masked token")
                # The last `finish_reason=length` response still holds a real token.
                generated.append(token)
                if len(generated) > request.count:
                    raise RuntimeError("model exceeded requested output length")
                yield token, self.token_bytes.pieces[token]
            if len(generated) != request.count:
                raise RuntimeError("model ended before requested output length")
        except (ClientDisconnected, GeneratorExit):
            raise
        except Exception:
            healthy = False
            raise
        finally:
            try:
                if generator is not None:
                    generator.close()
                self.mx.synchronize()
                if not healthy:
                    self.cache = None
                    self.cache_tokens = ()
                elif cache is not None:
                    self._save_cache(cache, request.prompt + tuple(generated))
                # Cancellation before _prepare_cache has not touched the previous
                # cache; keep it available to the next real request.
            finally:
                self.generation_lock.release()


class AdapterServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], engine: ModelEngine):
        self.engine = engine
        super().__init__(address, AdapterHandler)

    def handle_error(self, request: Any, client_address: Any) -> None:
        # The base implementation prints tracebacks. Never include request content.
        print("request handler failed", file=sys.stderr, flush=True)


class AdapterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "RimeMLX/1"

    def log_message(self, _format: str, *_args: Any) -> None:
        pass

    def _json(self, status: int, body: dict[str, Any]) -> None:
        encoded = json.dumps(body, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(encoded)
        self.close_connection = True

    def _body(self) -> Any:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise InvalidRequest("invalid Content-Length") from error
        if not 0 < length <= MAX_BODY_BYTES:
            raise InvalidRequest("request body size is invalid")
        self.connection.settimeout(5)
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise InvalidRequest("incomplete request body")
        try:
            return json.loads(raw)
        except (ValueError, UnicodeError) as error:
            raise InvalidRequest("body must be valid JSON") from error

    def _disconnected(self) -> bool:
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return bool(readable) and self.connection.recv(
                1, socket.MSG_PEEK | socket.MSG_DONTWAIT
            ) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except OSError:
            return True

    def _event(self, body: dict[str, Any]) -> None:
        self.wfile.write(b"data: " + json.dumps(
            body, ensure_ascii=True, separators=(",", ":")
        ).encode("utf-8") + b"\n\n")
        self.wfile.flush()

    def do_GET(self) -> None:
        if self.path == "/health":
            self._json(200, {
                "status": "ok", "backend": "mlx", "context_size": CONTEXT_SIZE,
                "max_input_tokens": MAX_INPUT, "max_output_tokens": MAX_OUTPUT,
                "cached_tokens": len(self.server.engine.cache_tokens),
            })
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        started_stream = False
        iterator = None
        try:
            body = self._body()
            if self.path == "/tokenize":
                if not isinstance(body, dict) or not isinstance(body.get("content"), str):
                    raise InvalidRequest("content must be a string")
                tokens = self.server.engine.tokenize(body["content"])
                self._json(200, {"tokens": tokens})
                return
            if self.path != "/completion":
                self._json(404, {"error": "not_found"})
                return
            request, metadata = prepare_completion(body, self.server.engine)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            started_stream = True
            if metadata is not None:
                # This event must precede the first model token so an immediate
                # Tab acceptance can extend the exact same tokenized context.
                # It does not count toward the seven generated tokens.
                self._event(metadata)
            iterator = self.server.engine.complete(request, self._disconnected)
            count = 0
            for token, raw in iterator:
                count += 1
                self._event({
                    # The frontend assembles bytes across token boundaries. No
                    # lossy standalone token decoding or replacement characters.
                    "content": "",
                    "tokens": [token],
                    "completion_probabilities": [{"id": token, "bytes": list(raw)}],
                    "stop": False,
                    "tokens_predicted": count,
                })
            self._event({"stop": True, "stopped_limit": True, "tokens_predicted": count})
        except InvalidRequest as error:
            self._json(400, {"error": "invalid_request", "message": str(error)})
        except (BrokenPipeError, ConnectionResetError, TimeoutError, ClientDisconnected):
            pass
        except Exception as error:
            print("generation failed: " + type(error).__name__, file=sys.stderr, flush=True)
            try:
                if started_stream:
                    self._event({"error": "generation_failed", "stop": True})
                else:
                    self._json(500, {"error": "internal_error"})
            except OSError:
                pass
        finally:
            if iterator is not None:
                iterator.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True, help="local MLX model directory")
    parser.add_argument("--port", type=int, default=18082)
    args = parser.parse_args()
    if not args.model.is_dir():
        parser.error("--model must be an existing local directory")
    if not 1 <= args.port <= 65535:
        parser.error("--port must be from 1 to 65535")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    engine = ModelEngine(args.model.resolve())
    server = AdapterServer(("127.0.0.1", args.port), engine)
    print("MLX continuation ready on 127.0.0.1:" + str(args.port), flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
