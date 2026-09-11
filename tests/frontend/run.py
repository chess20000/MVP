#!/usr/bin/env python3
"""Compile current frontend logic with isolated dependencies; never launch an IME."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent.parent
SOURCES = ROOT / "frontend" / "sources"
BUILD = ROOT / ".build" / "tests"


def swift_block(source: str, declaration: str) -> str:
    """Extract these small, brace-balanced declarations from the current source."""
    if source.count(declaration) != 1:
        raise ValueError(f"Expected one current Swift declaration: {declaration}")
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[start : end + 1]
    raise ValueError(f"Unclosed Swift declaration: {declaration}")


def generate_sources() -> dict[str, Path]:
    completion = (SOURCES / "GhostCompletion.swift").read_text(encoding="utf-8")
    grid = (SOURCES / "CandidateGrid.swift").read_text(encoding="utf-8")

    buffer_path = BUILD / "BufferUnderTest.swift"
    buffer_path.write_text(
        "import Foundation\n"
        + swift_block(completion, "struct GhostToken {")
        + "\n"
        + swift_block(completion, "struct GhostBuffer {")
        + "\n",
        encoding="utf-8",
    )

    grid_path = BUILD / "GridUnderTest.swift"
    grid_path.write_text(
        swift_block(grid, "struct GridSelection {")
        + "\n\nfinal class GridBackHarness {\n"
        + "  var selection = GridSelection()\n"
        + "  var renderCount = 0\n"
        + "  func render() { renderCount += 1 }\n  "
        + swift_block(grid, "func back() {")
        + "\n}\n",
        encoding="utf-8",
    )

    # Expose private state only in the generated test copy. The real state machine,
    # capture, confirmation, history and token handling remain the source under test.
    isolated = completion.replace("import InputMethodKit", "").replace("import Carbon", "")
    isolated = isolated.replace("private ", "")
    isolated = isolated.replace(
        swift_block(isolated, "  func postStream("),
        """  func postStream(body: [String: Any], ticket: UUID,
                  completion: @escaping ([String: Any]) -> Void) {
    Probe.requests.append(body["n_predict"] as! Int)
    Probe.bodies.append(body)
    streamInFlight = true
    streamedTokens = 0
    streamExpected = body["n_predict"] as! Int
    Probe.complete = completion
  }""",
    )
    isolated = isolated.replace(
        swift_block(isolated, "  func show(client:"),
        """  func show(client: IMKTextInput) {
    guard pendingTab == nil else { return }
    Probe.shows += 1
    visible = !buffer.preview.isEmpty
  }""",
    )
    async_path = BUILD / "AsyncCompletionUnderTest.swift"
    async_path.write_text(isolated, encoding="utf-8")
    return {"buffer": buffer_path, "grid": grid_path, "async": async_path}


def main() -> int:
    if sys.platform != "darwin":
        raise SystemExit("Frontend tests require macOS and the Swift command-line tools.")
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise SystemExit("swiftc was not found. Install the Xcode command-line tools first.")
    BUILD.mkdir(parents=True, exist_ok=True)
    generated = generate_sources()
    history = SOURCES / "GhostHistory.swift"
    suites = [
        ("buffer", [generated["buffer"], TESTS / "BufferTests.swift"]),
        ("history", [history, TESTS / "HistoryTests.swift"]),
        ("document-history", [history, TESTS / "DocumentHistoryTests.swift"]),
        ("grid", [generated["grid"], TESTS / "GridTests.swift"]),
        (
            "async-completion",
            [history, TESTS / "FakeInputClient.swift", generated["async"], TESTS / "AsyncCompletionTests.swift"],
        ),
    ]
    with tempfile.TemporaryDirectory(prefix="mock-user-", dir=BUILD) as mock_user:
        environment = dict(os.environ, GHOST_TEST_USER_DIR=mock_user)
        for name, inputs in suites:
            executable = BUILD / name
            print(f"Running frontend/{name}", flush=True)
            subprocess.run(
                [
                    swiftc,
                    "-Onone",
                    "-swift-version", "5",
                    "-module-cache-path", str(BUILD / "swift-module-cache"),
                    *map(str, inputs),
                    "-o", str(executable),
                ],
                cwd=ROOT,
                check=True,
            )
            subprocess.run([str(executable)], cwd=ROOT, env=environment, check=True)
    print("All 5 frontend suites passed.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Frontend tests failed: {error}", file=sys.stderr)
        raise SystemExit(1)
