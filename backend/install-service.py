#!/usr/bin/env python3
"""Prepare or install the dedicated local MLX backend; never starts a service."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
from urllib.parse import urlparse
import uuid
import venv


MODEL_ID = "mlx-community/MiniCPM5-1B-4bit"
MODEL_REVISION = "36447e84d28c57588a6e91907675e44afe54ab00"
MODEL_SHA256 = "a23e0c5c79944a0b2cc92cb9ab79376b4dce41e2312383727e21ee43fe19cb4f"
MODEL_FILES = (
    "config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
    "model.safetensors", "model.safetensors.index.json", "chat_template.jinja", "README.md",
)
LABEL = "local.rime.ghost.mlx"
PORT = 18081
SOURCE = Path(__file__).resolve().parent


def locations(base: Path, model: Path | None = None) -> dict[str, Path]:
    base = base.expanduser().resolve()
    return {
        "base": base,
        "runtime": base / "mlx-runtime",
        "python": base / "mlx-runtime/bin/python",
        "model": (model.expanduser().resolve() if model else base / "models/MiniCPM5-1B-4bit"),
        "server": base / "mlx/server.py",
        "agent": Path.home() / "Library/LaunchAgents" / (LABEL + ".plist"),
    }


def launch_agent(paths: dict[str, Path]) -> dict:
    return {
        "Label": LABEL,
        "ProgramArguments": [str(paths["python"]), str(paths["server"]),
                             "--model", str(paths["model"]), "--port", str(PORT)],
        "ProcessType": "Interactive",
        # Installation is inert. control.sh on explicitly enables and bootstraps.
        "Disabled": True,
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 15,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
        "EnvironmentVariables": {
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false", "PYTHONDONTWRITEBYTECODE": "1",
        },
    }


def check_environment() -> None:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("专用 MLX 服务需要 Apple Silicon Mac。")
    if sys.version_info < (3, 10):
        raise RuntimeError("请使用 Python 3.10 或更新版本；本机已验证 Python 3.14。")


def require_stopped() -> None:
    # A bootstrap entry can exist while its process is stopped. Conservatively
    # require explicit off before replacing a registered job's runtime or files.
    probe = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if probe.returncode == 0:
        raise RuntimeError("续写服务仍已加载。先运行 backend/control.sh off，再准备或安装。")


def verify_model(model: Path) -> None:
    missing = [name for name in MODEL_FILES if not (model / name).is_file()]
    if missing:
        raise RuntimeError("模型文件不完整，请先运行 setup.sh。")
    digest = hashlib.sha256()
    with (model / "model.safetensors").open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != MODEL_SHA256:
        raise RuntimeError("模型权重与指定的 MiniCPM5-1B-4bit 版本不一致。")
    config = json.loads((model / "config.json").read_text())
    if config.get("model_type") != "llama" or config.get("vocab_size") != 130560:
        raise RuntimeError("模型配置与指定版本不一致。")


def pip_install(python: Path, requirement: Path) -> None:
    indexes = []
    env_index = os.environ.get("PIP_INDEX_URL", "").strip()
    if env_index:
        indexes.append(env_index)
    for item in (
        "https://pypi.tuna.tsinghua.edu.cn/simple",
        "https://mirrors.aliyun.com/pypi/simple",
        "https://mirrors.cloud.tencent.com/pypi/simple",
    ):
        if item not in indexes:
            indexes.append(item)
    for index in indexes:
        host = urlparse(index).hostname or ""
        command = [str(python), "-m", "pip", "install", "-r", str(requirement), "-i", index]
        if host:
            command.extend(["--trusted-host", host])
        if subprocess.run(command).returncode == 0:
            return
    raise RuntimeError("依赖安装失败，请检查网络后重试。")


def download_model(paths: dict[str, Path]) -> None:
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
    from huggingface_hub import snapshot_download

    # Only data files are downloaded. No repository Python code is fetched or run.
    snapshot_download(
        MODEL_ID, revision=MODEL_REVISION, local_dir=str(paths["model"]),
        allow_patterns=list(MODEL_FILES),
    )
    verify_model(paths["model"])


def prepare(paths: dict[str, Path], skip_model: bool) -> None:
    require_stopped()
    venv.EnvBuilder(with_pip=True).create(paths["runtime"])
    pip_install(paths["python"], SOURCE / "requirements.lock.txt")
    if not skip_model:
        # Use the isolated runtime, which now contains huggingface_hub.
        subprocess.run(
            [str(paths["python"]), str(SOURCE / "install-service.py"), "download-model",
             "--base", str(paths["base"]), "--model-dir", str(paths["model"])],
            check=True,
        )
    print("依赖已准备；服务尚未安装或启动。")


def install(paths: dict[str, Path]) -> None:
    require_stopped()
    if not paths["python"].is_file():
        raise RuntimeError("找不到专用 Python 环境，请先运行 setup.sh。")
    verify_model(paths["model"])
    targets = {
        SOURCE / "server.py": paths["server"],
        SOURCE / "requirements.lock.txt": paths["base"] / "mlx/requirements.lock.txt",
        SOURCE / "control.sh": paths["base"] / "control.sh",
    }
    existing = [target for target in (*targets.values(), paths["agent"]) if target.exists()]
    if existing:
        backup = paths["base"] / "backups" / ("backend-package-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
        backup.mkdir(parents=True)
        for index, target in enumerate(existing):
            shutil.copy2(target, backup / (str(index) + "-" + target.name))
    for source, target in targets.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + ".new")
        shutil.copy2(source, temporary)
        temporary.replace(target)
    (paths["base"] / "control.sh").chmod(0o755)
    paths["agent"].parent.mkdir(parents=True, exist_ok=True)
    temporary = paths["agent"].with_suffix(".plist.new")
    temporary.write_bytes(plistlib.dumps(launch_agent(paths)))
    temporary.replace(paths["agent"])
    # The frontend must not reuse IDs from the prior model or tokenizer.
    (paths["base"] / "disabled").touch()
    marker = paths["base"] / "backend-generation.new"
    marker.write_text(str(uuid.uuid4()) + "\n")
    marker.replace(paths["base"] / "backend-generation")
    (paths["base"] / "backend").write_text("mlx\n")
    print("已安装，未启动。显式运行以下命令启用：")
    print(str(paths["base"] / "control.sh") + " on")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "prepare", "download-model", "install"))
    parser.add_argument("--base", type=Path, default=Path.home() / "Library/Rime/ghost")
    parser.add_argument("--model-dir", type=Path, help="现有或待下载的指定模型目录")
    parser.add_argument("--skip-model", action="store_true", help="prepare 只安装依赖，不下载模型")
    args = parser.parse_args()
    paths = locations(args.base, args.model_dir)
    if args.action == "plan":
        print(json.dumps({**{key: str(value) for key, value in paths.items()},
                          "model_id": MODEL_ID, "model_revision": MODEL_REVISION,
                          "weight_sha256": MODEL_SHA256}, ensure_ascii=False, indent=2))
        return
    try:
        check_environment()
        if args.action == "prepare":
            prepare(paths, args.skip_model)
        elif args.action == "download-model":
            require_stopped()
            download_model(paths)
        else:
            install(paths)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
