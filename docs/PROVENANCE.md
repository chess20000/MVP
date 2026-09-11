# 来源与打包说明

- 前端基于 `rime/squirrel` 1.1.2 发布源码，保留上游 `frontend/LICENSE.txt`、资源和署名。当前修改版版本为 1.1.2.10；Swift 源码与整理时正在运行的安装版本一致。
- Squirrel 上游：https://github.com/rime/squirrel
- Rime 桥接头来自当前构建依赖，保留文件中的 RIME/BSD 许可说明。上游：https://github.com/rime/librime
- `native/include/X11/` 的 keysym 头保留原始版权和许可文本。
- Sparkle 的 Headers/Modules 与本机构建使用的 SDK 一致，许可保存在 `licenses/Sparkle-LICENSE.txt`。上游：https://github.com/sparkle-project/Sparkle
- MLX 服务是此项目的专用适配层；依赖精确版本保存在 `backend/requirements.lock.txt`。
- 模型：https://huggingface.co/mlx-community/MiniCPM5-1B-4bit
- 固定模型 revision：`36447e84d28c57588a6e91907675e44afe54ab00`；权重 SHA-256：`a23e0c5c79944a0b2cc92cb9ab79376b4dce41e2312383727e21ee43fe19cb4f`。模型权重单独下载，未纳入 Git。
- `config/rime/` 仅保存相关代码和配置示例，不包含万象的大词库、用户学习数据库、个人短语、诊断输入记录。

`vendor/Squirrel.app` 和 `dist/` 供这个本地副本构建与恢复使用，已被 Git 忽略。推送仓库只会包含源码、头文件、脚本、配置示例、测试和文档；模型、虚拟环境、安装包和本机状态不会随之推送。
