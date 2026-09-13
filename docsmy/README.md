# APISIX 项目文档

本目录包含 APISIX 项目的各类文档。

## 📚 文档分类

### 队列插件 ([queue/](queue/))
APISIX 队列请求处理插件的完整文档。

- [README.md](queue/README.md) - 队列插件文档索引
- [QUEUE_README.md](queue/QUEUE_README.md) - 主要说明文档
- [QUEUE_QUICKSTART.md](queue/QUEUE_QUICKSTART.md) - 快速开始指南
- [QUEUE_ARCHITECTURE.md](queue/QUEUE_ARCHITECTURE.md) - 架构设计
- [QUEUE_REQUEST_DESIGN.md](queue/QUEUE_REQUEST_DESIGN.md) - 技术设计文档
- [QUEUE_INDEX.md](queue/QUEUE_INDEX.md) - 文档导航

### 插件开发 ([plugins/](plugins/))
APISIX 插件系统和各类插件的设计文档。

- [apisix-plugin-system-design.md](plugins/apisix-plugin-system-design.md) - 插件系统设计
- [apisix-custom-plugin-design.md](plugins/apisix-custom-plugin-design.md) - 自定义插件开发
- [ai-proxy-plugin.md](plugins/ai-proxy-plugin.md) - AI 代理插件
- [serverless-function-parameters.md](plugins/serverless-function-parameters.md) - Serverless 函数参数
- [serverless-plugin-call-flow.md](plugins/serverless-plugin-call-flow.md) - Serverless 插件调用流程

### 开发环境 ([devcontainer/](devcontainer/))
DevContainer 开发环境配置和使用指南。

- [DEVCONTAINER_SETUP.md](devcontainer/DEVCONTAINER_SETUP.md) - DevContainer 环境搭建指南

### 其他文档
- [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) - 项目结构说明
- [SOLUTION_2_GUIDE.md](SOLUTION_2_GUIDE.md) - 解决方案指南

## 🚀 快速导航

### 新手入门
1. [DevContainer 环境搭建](devcontainer/DEVCONTAINER_SETUP.md)
2. [项目结构说明](PROJECT_STRUCTURE.md)
3. [队列插件快速开始](queue/QUEUE_QUICKSTART.md)

### 插件开发
1. [插件系统设计](plugins/apisix-plugin-system-design.md)
2. [自定义插件开发](plugins/apisix-custom-plugin-design.md)
3. [队列插件架构](queue/QUEUE_ARCHITECTURE.md)

### 深入理解
1. [队列插件技术设计](queue/QUEUE_REQUEST_DESIGN.md)
2. [AI 代理插件](plugins/ai-proxy-plugin.md)
3. [Serverless 插件](plugins/serverless-plugin-call-flow.md)

## 📁 相关目录

- `/apisix/plugins/` - 插件源代码
- `/examples/queue/` - 队列插件示例和 Worker 实现
- `/t/queue/` - 队列插件测试脚本
- `/docs/` - 项目文档（当前目录）

## 🤝 贡献

欢迎贡献文档！请确保：
- 文档清晰易懂
- 包含实际示例
- 保持格式一致
- 及时更新

## 📄 许可证

Apache License 2.0
