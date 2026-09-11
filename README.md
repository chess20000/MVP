# 投机输入法

基于鼠须管 Squirrel 1.1.2 的 macOS 输入法改造，当前版本 **1.1.2.10**。中文候选由 Rime 负责，幽灵续写由本机专用 MLX 服务运行 `mlx-community/MiniCPM5-1B-4bit`。项目名称为“投机输入法”，支持上屏后续写与选词期间的编码预测。

## 安装（中国大陆）

需要 **苹果芯片 Mac**（M1 / M2 / M3 / M4）。打开「终端」，把下面一行完整粘贴进去，按回车。弹出密码时输入 **开机密码**（输入过程中看不见字，属正常）。

```sh
curl -fsSL https://ghfast.top/https://github.com/chess20000/MVP/releases/latest/download/install.sh | bash
```

如果这一行连不上，换备用镜像：

```sh
curl -fsSL https://gh-proxy.com/https://github.com/chess20000/MVP/releases/latest/download/install.sh | bash
```

脚本会走国内 GitHub / Hugging Face / PyPI 镜像。装好后：菜单栏选「鼠须管」，并在系统设置 → 隐私与安全性 → **辅助功能**（如有则再加上 **输入监控**）里打开鼠须管。灰色字是续写，Tab 接受。

## 当前行为

- 输入字母选词时，发送当前正文（最多 256 token）和原始编码，使用 `请续写以下内容：正文shur这个词可能是：` 预测最多 2 token。完成后显示 `shur输入`，Tab 一次提交预测词；继续输入会替换旧请求。
- 上屏后启动一次请求，无额外防抖等待；同一请求完成分词并流式输出 7 个真实模型 token。
- Tab 接受一个 token，保留原流与剩余预测，随后只补足到 7 个。UTF-8 字节尚未组成完整字符时暂存，避免乱码。
- 提示固定为 `请续写以下内容：` 加当前输入框光标前最近最多 256 token，不加入历史选词。保留 7 个预测 token，总预算上限 512，未使用空间留空。
- 空前缀仍可续写；光标后还有可见文字则不启动续写。网页框读不到后缀时，会看同一行下一个字的位置和辅助功能文本。仅换行或空白的尾巴不拦截。保留系统安全输入、当前输入框与旧结果失效校验；焦点变化不启动模型；选词预测由正在输入的字母触发。
- `1` 展开紧凑的 5×5 候选网格，先列后行：`134` 选第 3 列第 4 行，即第 18 项；`155` 选第 25 项。普通 `/` 直接上屏。
- 万象候选调频的 10 次上下文、10 秒超时独立于幽灵续写，相关配置放在 `config/rime/`。

## 目录

| 路径 | 内容 |
| --- | --- |
| `frontend/` | Squirrel 上游源码与当前 Swift 改动，保留上游资源和许可证 |
| `native/include/` | 构建所需 Rime、X11、Sparkle 头文件 |
| `backend/` | MLX 服务、锁定依赖、准备与服务安装脚本、后端测试 |
| `scripts/` | 前端构建、安装包生成与手动安装脚本 |
| `tests/frontend/` | 对当前源码执行的缓冲、候选坐标、异步提交和历史撤回测试 |
| `config/` | 默认参数及可选 Rime 配置示例 |
| `docs/` | 结构、来源与验证说明 |
| `vendor/` | 本地应用模板，未纳入 Git |
| `dist/` | 本地安装包，未纳入 Git |
| `.build/` | 构建与测试产物，未纳入 Git |

## 构建与检查

本机已验证环境为 Apple Silicon、macOS 26 和 Xcode Command Line Tools。当前前端构建目标为 arm64/macOS 13；后端依赖的要求见 [backend/README.md](backend/README.md)。

```sh
bash scripts/build-frontend.sh --check
bash scripts/build-frontend.sh
bash scripts/package-frontend.sh
bash tests/frontend/run.sh
```

本地目录附带 `vendor/Squirrel.app`，用于提供框架运行库和应用资源；它不进入 Git。Git 克隆不包含此目录时，构建脚本可使用系统已安装的 `/Library/Input Methods/Squirrel.app` 作为模板，具体选项见脚本 `--help`。Sparkle 开发头文件和 Rime 桥接头文件已纳入仓库。

推荐使用上述脚本构建当前改造版；`frontend/` 中保留的上游 Makefile 和 Xcode 工程不是本仓库验证的构建入口。

## 安装与运行

MLX 环境、模型准备和 LaunchAgent 安装见 [backend/README.md](backend/README.md)。模型 revision 已固定；模型权重和 Python 虚拟环境单独准备，不纳入 Git。

前端安装需要手动执行：

```sh
bash scripts/install-frontend.sh
```

该脚本先备份再调用 macOS 标准安装程序，随后重载鼠须管。管理员验证由系统安装程序负责。构建、打包和默认测试都不会安装输入法，也不会替你在应用中打字。

`config/rime/` 是按需合并的示例，不自动覆盖现有方案。完整万象词库、用户词库、个人短语、输入诊断记录和机器运行状态均未复制。

本机目录的 `dist/Squirrel-Ghost-1.1.2.10.pkg` 已附带整理时的安装包。今后运行打包脚本可以从当前源码重新生成。

## 验证与边界

已进行编译、签名检查、前端隔离测试和后端接口测试。真实输入框体验由使用者验证；模型计算仍有耗时，无额外防抖等待并不等于零计算延迟。

继续输入、删除、移动光标等使已有预测失效时，会清理旧结果；下一次实际上屏触发新流。Tab 接受当前预测则延续原流。服务只监听本机 `127.0.0.1:18081`。

## 来源与许可

鼠须管源码保留 GPLv3 许可证，见 [LICENSE](LICENSE)；第三方头文件和框架遵循各自许可证，见 [docs/PROVENANCE.md](docs/PROVENANCE.md)。模型来自其 Hugging Face 原仓库，权重遵循模型自己的许可。此仓库从当前工作版本创建独立初始提交，不包含上游完整 Git 历史。
