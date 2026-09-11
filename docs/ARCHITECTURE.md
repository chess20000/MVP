# 结构与修改入口

`frontend/sources/SquirrelInputController.swift` 在 Rime 完成提交时通知 `GhostCompletion`。`willCommit` 保存预期落点，`committed` 记录实际提交并安排一次流；获得焦点本身不会调用模型。

`GhostCompletion.swift` 负责前缀读取、上下文验证、请求生命周期和透明预览。首次 `/completion` 请求只发送当前输入框光标前的 `prompt_text`。后端使用固定指令 `请续写以下内容：` 加最近最多 256 个文本 token，不加入历史选词；先返回 `context_tokens`、`instruction_tokens`，再返回逐 token 的 ID 和原始 UTF-8 字节。该元数据不计入 7 个输出。

固定指令 token 始终保留，滚动正文最多 256 token，输出窗口为 7 token，总量不超过 512，剩余空间留空。Tab 将队首 token 移入已接受上下文，保持其余队列和原流；原流结束后按缺额发送 token ID 请求。因此接受第一个 token 后只补第八个，不重新生成第二到第七个。

`GhostHistory.swift` 中的 `GhostHistory` 保存 128 条带标识的选词记录；同文件的 `GhostDocumentHistory` 用实际文本范围验证编辑并撤回对应记录。无法确认的异步提交记录到期会撤回，不按同名词全局删除。

`GhostFocus.swift` 验证当前输入会话及 Spotlight 浮层；`GhostDiagnostics.swift` 仅记录应用标识、失败阶段、范围及耗时等元数据。运行状态文件不进 Git。

`CandidateGrid.swift` 实现紧凑 5×5 列号、行号选择。`backend/server.py` 负责分词预算、单机流式推理、前缀缓存、串行访问与断连取消。模型和词典相互独立，Rime 候选调频不依赖 MLX。

`config/rime/lua/wanxiang/context_reorder.lua` 是整理时使用的十次上下文调频实现，依赖已有万象方案的 `wanxiang/wanxiang` 和 `wanxiang/userdb` 模块；它不是一套完整方案。`*.custom.example.yaml` 需合并到已有配置，不要直接覆盖个人配置。

`GhostComposition.swift` 独立处理选词期间的两 token 预测。`rimeUpdate()` 获取 Rime 原始编码（不使用首候选），读取 marked range 之前的正文，向 `/completion` 发送 `prompt_text`、`composition_text` 和 `n_predict: 2`。后端拼接固定指令、最多 256 正文 token、编码和“这个词可能是：”。两 token 收齐且 UTF-8 完整后才展示预测，不请求补充。预测作为 marked text 显示在字母后，Tab 清除 Rime 组合并提交整个预测词，再启动常规上屏续写。改编码、提交、失焦或后端变化会使旧预测失效；候选顺序不变。
