# APISIX 队列插件文档索引

本目录包含 APISIX 队列请求处理插件的完整文档。

## 📚 文档列表

### 快速开始
- **[QUEUE_README.md](QUEUE_README.md)** - 主要说明文档，包含功能概述、快速开始和使用指南
- **[QUEUE_QUICKSTART.md](QUEUE_QUICKSTART.md)** - 5 分钟快速部署指南

### 深入理解
- **[QUEUE_ARCHITECTURE.md](QUEUE_ARCHITECTURE.md)** - 系统架构设计和数据流详解
- **[QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md)** - 完整的技术设计文档

### 索引
- **[QUEUE_INDEX.md](QUEUE_INDEX.md)** - 文档导航索引

## 🚀 核心功能

这是一个基于 APISIX 和 Redis 的非实时 API 请求处理解决方案，用于实现请求排队限流。

### 主要特性
- ✅ 请求异步化：客户端提交请求后立即返回
- ✅ 队列缓冲：使用 Redis 队列缓冲请求
- ✅ 状态查询：客户端通过轮询查询处理状态和结果
- ✅ 限流保护：防止队列过长，保护系统稳定性

## 📁 相关文件

### 插件代码
- `apisix/plugins/queue-request.lua` - 请求入队插件
- `apisix/plugins/queue-result.lua` - 结果查询插件

### Worker 实现
- `examples/queue/queue-worker.py` - Python 版本 Worker（推荐）
- `examples/queue/queue-worker.lua` - Lua 版本 Worker（可选）

### 测试工具
- `t/queue/test-queue-plugin.sh` - 自动化测试脚本
- `t/queue/test-e2e.sh` - 端到端测试
- `t/queue/test-queue-demo.sh` - 完整演示脚本
- `t/queue/check-status.sh` - 系统状态检查
- `examples/queue/test-backend-server.py` - 测试后端服务

## 🎯 使用场景

### ✅ 适合使用
- 批量数据处理：大文件上传、数据导入导出
- 耗时任务异步化：视频转码、图片处理、报表生成
- 流量削峰填谷：秒杀活动、促销活动
- 后端服务保护：限制并发、防止过载

### ❌ 不适合使用
- 实时性要求高：在线支付、实时通信
- 简单快速请求：查询操作、简单 CRUD
- 需要事务保证：金融交易、库存扣减

## 📖 推荐阅读顺序

1. 新手入门：[QUEUE_README.md](QUEUE_README.md) → [QUEUE_QUICKSTART.md](QUEUE_QUICKSTART.md)
2. 深入理解：[QUEUE_ARCHITECTURE.md](QUEUE_ARCHITECTURE.md) → [QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md)
3. 实践操作：运行测试脚本，查看实际效果

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

Apache License 2.0
