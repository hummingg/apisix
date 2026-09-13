# 文件索引

## 📚 阅读顺序

### 第一步：快速了解
👉 **[QUEUE_README.md](QUEUE_README.md)** - 从这里开始！
- 方案概述
- 文件清单
- 快速开始
- 使用场景

### 第二步：动手实践
👉 **[QUEUE_QUICKSTART.md](QUEUE_QUICKSTART.md)** - 5 分钟部署
- 安装步骤
- 配置路由
- 启动 Worker
- 测试验证
- 故障排查

### 第三步：深入理解
👉 **[QUEUE_ARCHITECTURE.md](QUEUE_ARCHITECTURE.md)** - 架构设计
- 系统架构图
- 数据流详解
- 设计决策
- 性能特性
- 扩展方向

### 第四步：完整参考
👉 **[QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md)** - 技术文档
- 核心组件详解
- Redis 数据结构
- 部署配置
- 性能优化
- 扩展功能

## 📁 文件分类

### 📖 文档文件

| 文件 | 用途 | 适合人群 |
|------|------|----------|
| QUEUE_README.md | 项目总览 | 所有人 |
| QUEUE_QUICKSTART.md | 快速开始 | 新手 |
| QUEUE_ARCHITECTURE.md | 架构设计 | 架构师、开发者 |
| QUEUE_REQUEST_DESIGN.md | 完整文档 | 开发者、运维 |
| QUEUE_INDEX.md | 文件索引 | 所有人 |

### 🔌 插件文件

| 文件 | 功能 | 位置 |
|------|------|------|
| queue-request.lua | 请求入队 | apisix/plugins/ |
| queue-result.lua | 结果查询 | apisix/plugins/ |

### ⚙️ Worker 文件

| 文件 | 语言 | 推荐度 |
|------|------|--------|
| queue-worker.py | Python | ⭐⭐⭐⭐⭐ 推荐 |
| queue-worker.lua | Lua | ⭐⭐⭐ 可选 |

### 🧪 测试文件

| 文件 | 用途 |
|------|------|
| test-queue-plugin.sh | 自动化测试脚本 |

## 🎯 按场景查找

### 我想快速部署
1. 阅读 [QUEUE_QUICKSTART.md](QUEUE_QUICKSTART.md)
2. 运行 `test-queue-plugin.sh`

### 我想了解原理
1. 阅读 [QUEUE_ARCHITECTURE.md](QUEUE_ARCHITECTURE.md)
2. 查看架构图和数据流

### 我想自定义配置
1. 阅读 [QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md)
2. 查看配置参数章节

### 我想扩展功能
1. 阅读 [QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md)
2. 查看扩展功能章节

### 我遇到了问题
1. 查看 [QUEUE_QUICKSTART.md](QUEUE_QUICKSTART.md) 的故障排查
2. 查看 [QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md) 的故障处理

## 📊 文件统计

- **文档文件**: 5 个 (约 45 KB)
- **插件文件**: 2 个 (约 8.4 KB)
- **Worker 文件**: 2 个 (约 10.2 KB)
- **测试文件**: 1 个 (约 2.7 KB)
- **总计**: 10 个文件 (约 66.3 KB)

## 🔗 快速链接

### 核心文档
- [项目总览](QUEUE_README.md)
- [快速开始](QUEUE_QUICKSTART.md)
- [架构设计](QUEUE_ARCHITECTURE.md)
- [完整文档](QUEUE_REQUEST_DESIGN.md)

### 代码文件
- [请求入队插件](apisix/plugins/queue-request.lua)
- [结果查询插件](apisix/plugins/queue-result.lua)
- [Python Worker](queue-worker.py)
- [Lua Worker](queue-worker.lua)
- [测试脚本](test-queue-plugin.sh)

## 💡 使用建议

### 新手用户
```
QUEUE_README.md → QUEUE_QUICKSTART.md → 动手实践
```

### 开发人员
```
QUEUE_README.md → QUEUE_ARCHITECTURE.md → QUEUE_REQUEST_DESIGN.md → 代码实现
```

### 运维人员
```
QUEUE_QUICKSTART.md → 部署配置 → 监控告警
```

### 架构师
```
QUEUE_ARCHITECTURE.md → 设计决策 → 扩展方向
```

---

**开始使用**: 阅读 [QUEUE_README.md](QUEUE_README.md) 👉
