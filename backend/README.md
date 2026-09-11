# 本地续写后端

这是鼠须管前端使用的专用 MLX 服务，监听 `127.0.0.1:18081`。提示为`请续写以下内容：`加当前输入框光标前最近最多256个token，不加入历史选词，每次续写7个token，总上下文不超过512，剩余空间留空。Tab补充沿用原始token ID，每次只请求1个新token。

使用 `mlx-community/MiniCPM5-1B-4bit`，固定提交为 `36447e84d28c57588a6e91907675e44afe54ab00`。权重SHA-256为 `a23e0c5c79944a0b2cc92cb9ab79376b4dce41e2312383727e21ee43fe19cb4f`。仓库不包含模型权重、虚拟环境、运行日志或测试结果。

需要 Apple Silicon Mac。本机已验证 macOS 26、Python 3.14、MLX 0.32.2 和 mlx-lm 0.31.3；其他系统与Python版本能否安装这组锁定依赖，取决于对应发行包。`setup.sh`优先寻找`python3.14`，也可以通过`PYTHON_BIN`指定解释器。

## 准备与安装

以下命令在仓库根目录执行。查看路径不会修改系统：

```sh
python3 backend/install-service.py plan
```

如果原来已加载同名续写服务，先显式停止；准备和安装脚本会拒绝覆盖仍已加载的服务。

```sh
backend/control.sh off
backend/setup.sh
python3.14 backend/install-service.py install
```

`setup.sh`在`~/Library/Rime/ghost/mlx-runtime`创建专用环境、安装锁定依赖，并把指定版本的模型数据下载到`~/Library/Rime/ghost/models/MiniCPM5-1B-4bit`。它不加载模型或启动服务。已有模型时可使用`--model-dir /path/to/model`；仅准备依赖可加`--skip-model`。`install`仍会核对模型权重。

`install`复制服务文件、生成当前用户的LaunchAgent，并保持禁用。已有文件会先备份。随后明确启用：

```sh
"$HOME/Library/Rime/ghost/control.sh" on
"$HOME/Library/Rime/ghost/control.sh" status
"$HOME/Library/Rime/ghost/control.sh" off
```

服务使用`ProcessType=Interactive`，启动时先预热，再报告就绪。控制脚本通过`backend-generation`标记让前端丢弃旧模型的token，并在模型就绪前保持幽灵续写暂停。

`prepare`、`install`都接受`--base /path/to/ghost`。非默认位置需要前端使用同一目录；后端仍使用同一个LaunchAgent名称和18081端口，不会创建第二套并行服务。从仓库调用控制脚本时，可以设置`RIME_GHOST_BASE`；安装后的控制脚本会识别自身所在目录。

## 测试

默认单元测试不加载模型，也不读取用户输入：

```sh
cd backend
python3 -m unittest test_server.py test_install_service.py
```

可选的真实tokenizer检查只读取已经下载的模型数据：

```sh
RIME_GHOST_MODEL="$HOME/Library/Rime/ghost/models/MiniCPM5-1B-4bit" \
  "$HOME/Library/Rime/ghost/mlx-runtime/bin/python" -m unittest test_server.py
```

HTTP测试使用合成文字请求正在运行的服务：

```sh
"$HOME/Library/Rime/ghost/mlx-runtime/bin/python" test_http_live.py \
  --port 18081 --model "$HOME/Library/Rime/ghost/models/MiniCPM5-1B-4bit"
```

缓存回归测试会单独加载模型。先停服务，避免同时占用两份模型内存；测试结束会释放模型。默认不写结果文件，只有显式提供`--output`才保存JSON。

```sh
./control.sh off
"$HOME/Library/Rime/ghost/mlx-runtime/bin/python" test_cache_live.py \
  --model "$HOME/Library/Rime/ghost/models/MiniCPM5-1B-4bit"
./control.sh on
```

## 接口约定

`POST /completion`的首次请求使用`prompt_text`，`n_predict`为7。后端分别分词固定指令`请续写以下内容：`和当前文字，将正文截取为最近最多256个token，再拼接指令与正文。先以SSE返回`context_tokens`和`instruction_tokens`，再流式返回7个真实token及原始UTF-8字节。元数据不计入输出数量。空文字时仅使用固定指令；不再接受`history_texts`。前后端必须一起更新。

Tab补充使用`prompt: [token IDs]`和`n_predict: 1`。两种请求形式互斥。`GET /health`报告就绪状态；兼容的`POST /tokenize`仍可用。服务不执行模型仓库代码，不套用聊天模板，不保存输入文字或选词历史。

`server.py`中的FP16转换仅影响浮点参数；四位量化整数权重保持不变。有效缓存长度在每次请求后核对，不超过512；不要仅依靠MLX缓存工厂的`max_kv_size`参数判断有效上下文长度。

选词预测使用同一个 `/completion` 接口：`prompt_text` 为当前输入框已上屏正文，`composition_text` 为正在输入的 1–128 个字母（可含分词撇号），`n_predict` 为 2。提示为 `请续写以下内容：` + 最近最多 256 个正文 token + `shur这个词可能是：`。不发送首候选，不使用历史选词，完整提示和输出仍受 512 上限约束。
