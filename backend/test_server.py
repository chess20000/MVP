import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest

from server import (
    CONTINUATION_INSTRUCTION,
    InvalidRequest,
    TokenBytes,
    bytelevel_inverse,
    common_prefix_length,
    prepare_completion,
    validate_completion,
)


class TextRequestTests(unittest.TestCase):
    class Engine:
        vocab_size = 200000
        tokenizer = SimpleNamespace(bos_token_id=0)

        def __init__(self):
            self.calls = []

        def tokenize(self, text):
            self.calls.append(text)
            return [ord(char) + 1 for char in text]

    def test_instruction_and_current_text(self):
        engine = self.Engine()
        request, metadata = prepare_completion({"prompt_text": "你好"}, engine)
        self.assertEqual(engine.calls, ["你好", CONTINUATION_INSTRUCTION])
        self.assertEqual(request.prompt, tuple(ord(c) + 1 for c in CONTINUATION_INSTRUCTION + "你好"))
        self.assertEqual(request.prompt, tuple(metadata["instruction_tokens"] + metadata["context_tokens"]))
        self.assertEqual(metadata["tokens_predicted"], 0)
        self.assertEqual(request.count, 7)

    def test_text_context_budget(self):
        request, metadata = prepare_completion({"prompt_text": "甲" * 44 + "汉" * 256}, self.Engine())
        self.assertEqual(metadata["context_tokens"], [ord("汉") + 1] * 256)
        self.assertEqual(len(metadata["instruction_tokens"]), len(CONTINUATION_INSTRUCTION))
        self.assertLessEqual(len(request.prompt) + request.count, 512)

    def test_empty_current_text_is_supported(self):
        request, metadata = prepare_completion({"prompt_text": ""}, self.Engine())
        self.assertEqual(metadata["context_tokens"], [])
        self.assertEqual(request.prompt, tuple(metadata["instruction_tokens"]))
        self.assertTrue(request.prompt)

    def test_text_request_allows_one_to_seven_tokens(self):
        request, _ = prepare_completion({"prompt_text": "你好", "n_predict": 1}, self.Engine())
        self.assertEqual(request.count, 1)
        request, _ = prepare_completion({"prompt_text": "你好", "n_predict": 7}, self.Engine())
        self.assertEqual(request.count, 7)
        request, _ = prepare_completion({"prompt_text": "你好"}, self.Engine())
        self.assertEqual(request.count, 7)

    def test_composition_prediction_is_removed(self):
        for body in (
            {"prompt_text": "正文", "composition_text": "shur", "n_predict": 2},
            {"prompt_text": "汉" * 1000, "composition_text": "a" * 128},
            {"composition_text": "shur", "prompt": [1]},
            *({"prompt_text": "", "composition_text": value} for value in
              [None, "", "中文", "a\nb", "a" * 129]),
            {"prompt_text": "", "composition_text": "shur", "n_predict": 7},
        ):
            with self.subTest(body=body), self.assertRaises(InvalidRequest):
                prepare_completion(body, self.Engine())

    def test_refill_still_uses_exact_ids(self):
        request, metadata = prepare_completion(
            {"prompt": [4, 5, 6], "n_predict": 1}, self.Engine()
        )
        self.assertEqual(request.prompt, (4, 5, 6))
        self.assertEqual(request.count, 1)
        self.assertIsNone(metadata)

    def test_invalid_text_requests(self):
        for body in (
            {"prompt_text": None}, {"prompt_text": "x", "prompt": [1]},
            {"prompt_text": "x", "history_texts": ["过去"]},
            {"prompt_text": "x", "history_texts": ["x"] * 129},
            {"prompt_text": "x", "n_predict": 8}, {"prompt_text": "x", "stream": False},
        ):
            with self.subTest(body=body), self.assertRaises(InvalidRequest):
                prepare_completion(body, self.Engine())


class ValidationTests(unittest.TestCase):
    def test_limits(self):
        request = validate_completion({"prompt": [5] * 505, "n_predict": 7, "stream": True}, 10)
        self.assertEqual(len(request.prompt) + request.count, 512)
        self.assertEqual(validate_completion({"prompt": [0], "n_predict": 1}, 10).count, 1)

    def test_invalid_requests(self):
        cases = [
            {}, {"prompt": []}, {"prompt": [0] * 506}, {"prompt": [True]},
            {"prompt": [1.5]}, {"prompt": ["1"]}, {"prompt": [-1]}, {"prompt": [10]},
            {"prompt": [0], "n_predict": 0}, {"prompt": [0], "n_predict": 8},
            {"prompt": [0], "n_predict": True}, {"prompt": [0], "n_predict": 1.0},
            {"prompt": [0], "stream": False}, {"prompt": [0], "stream": "true"},
            [], None,
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(InvalidRequest):
                validate_completion(case, 10)

    def test_prefix_lengths(self):
        self.assertEqual(common_prefix_length((1, 2, 3), (1, 2, 4)), 2)
        self.assertEqual(common_prefix_length((1, 2), (1, 2, 3)), 2)
        self.assertEqual(common_prefix_length((), (1,)), 0)


class ByteTests(unittest.TestCase):
    def test_all_bytes_reversible(self):
        inverse = bytelevel_inverse()
        self.assertEqual(len(inverse), 256)
        self.assertEqual(set(inverse.values()), set(range(256)))
        forward = {value: char for char, value in inverse.items()}
        for source in [bytes(range(256)), "中文👍🏽 e\u0301 abc".encode("utf-8")]:
            encoded = "".join(forward[value] for value in source)
            self.assertEqual(bytes(inverse[char] for char in encoded), source)

    def test_partial_utf8_and_controls(self):
        forward = {value: char for char, value in bytelevel_inverse().items()}

        def piece(raw):
            return "".join(forward[value] for value in raw)

        data = {
            "decoder": {"type": "ByteLevel"},
            "model": {"type": "BPE", "vocab": {
                piece(b"\xe4\xb8"): 0, piece(b"\xad"): 1,
                piece("中文".encode("utf-8")): 2, piece(b"a\nb"): 3,
                "<think>": 4, "</think>": 5,
            }},
            "added_tokens": [
                {"id": 4, "content": "<think>", "special": False},
                {"id": 5, "content": "</think>", "special": False},
                {"id": 6, "content": "</s>", "special": True},
                {"id": 7, "content": "<unused_token_0>", "special": False},
            ],
        }
        table = TokenBytes.from_json(data, 8)
        self.assertEqual(table.pieces[0] + table.pieces[1], "中".encode("utf-8"))
        self.assertEqual(table.pieces[2], "中文".encode("utf-8"))
        self.assertEqual(table.blocked, frozenset({3, 4, 5, 6, 7}))
        data["decoder"]["type"] = "Metaspace"
        with self.assertRaises(ValueError):
            TokenBytes.from_json(data, 8)

    def test_actual_model_tokenizer(self):
        configured_model = os.environ.get("RIME_GHOST_MODEL")
        if not configured_model:
            self.skipTest("set RIME_GHOST_MODEL to test an existing model tokenizer")
        model = Path(configured_model).expanduser()
        if not (model / "tokenizer.json").exists():
            self.skipTest("downloaded model tokenizer is unavailable")
        from tokenizers import Tokenizer

        data = json.loads((model / "tokenizer.json").read_text())
        config = json.loads((model / "config.json").read_text())
        table = TokenBytes.from_json(data, config["vocab_size"])
        tokenizer = Tokenizer.from_file(str(model / "tokenizer.json"))
        for text in ["今天我们去公园散步。", "👨‍👩‍👧‍👦👍🏽", "英文 mixed 中文 e\u0301", "空格  保留"]:
            tokens = tokenizer.encode(text, add_special_tokens=False).ids
            self.assertEqual(b"".join(table.pieces[token] for token in tokens), text.encode("utf-8"))
            self.assertFalse(set(tokens) & table.blocked)
        self.assertIn(8, table.blocked)
        self.assertIn(9, table.blocked)
        newline = tokenizer.encode("\n", add_special_tokens=False).ids
        self.assertTrue(set(newline) <= table.blocked)


if __name__ == "__main__":
    unittest.main()
