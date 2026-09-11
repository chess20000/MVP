# 前端逻辑测试

在 macOS 安装 Xcode Command Line Tools 后运行：

```sh
./tests/frontend/run.sh
```

入口不依赖当前工作目录。只需要系统 Swift 和 Python 3，不需要安装鼠须管、下载模型或运行后端。生成的 Swift、二进制和编译缓存均写入仓库的 `.build/tests/`，测试用配置目录在结束时删除。

六组测试均读取 `frontend/sources/` 的当前实现，不包含旧版本源码副本：

- `CompositionTests.swift`：选词请求正文、两 token 整词接受、请求去重、过期结果、取消、正文变化和 UTF-8 边界。
- `BufferTests.swift`：UTF-8 跨 token 字符、一次接受一个 token、滚动保留七个预测，以及 256/505/512 token 边界。
- `HistoryTests.swift`：最近 128 次选词、淘汰后的 receipt、部分撤回、重复词隔离及 Unicode。
- `DocumentHistoryTests.swift`：真实编辑范围、选区替换、连续删除、滑动读取窗口和来源不确定时的保守处理。
- `GridTests.swift`：当前的先列后行规则；`134` 对应第 3 列第 4 行、候选索引 17，`155` 对应索引 24，以及空单元格、无效数字和返回操作。
- `AsyncCompletionTests.swift`：延迟提交与布局、精确删除记录、Tab 保留原预测并仅补一个 token、一次提交仅一次首次请求、焦点变化不请求及 metadata 顺序。

历史模块直接与测试一起编译。buffer 和 grid 声明从当前源码提取。异步测试仅在生成副本中开放私有状态，并使用 `FakeInputClient.swift` 替换 IMK、焦点、配置、网络和面板依赖；核心状态机和文本处理方法保持当前源码原样。测试不会发送键盘事件、创建候选窗口、读取真实输入框、修改输入法或访问 GPU。真实应用中的 IMK/AX 行为、网络传输和面板布局仍需单独验证。
