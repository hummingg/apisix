# APISIX 队列插件 - 文件组织说明

本文档说明队列插件相关文件的组织结构和位置。

## 📁 目录结构

```
/workspace/
├── apisix/
│   └── plugins/                      # 插件源代码
│       ├── queue-request.lua         # 请求入队插件（4.8KB）
│       └── queue-result.lua          # 结果查询插件（3.6KB）
│
├── docs/                             # 项目文档
│   ├── README.md                     # 文档索引
│   ├── queue/                        # 队列插件文档
│   │   ├── README.md                 # 队列文档索引
│   │   ├── QUEUE_README.md           # 主要说明文档
│   │   ├── QUEUE_QUICKSTART.md       # 快速开始指南
│   │   ├── QUEUE_ARCHITECTURE.md     # 架构设计
│   │   ├── QUEUE_REQUEST_DESIGN.md   # 技术设计文档
│   │   └── QUEUE_INDEX.md            # 文档导航
│   ├── plugins/                      # 插件设计文档
│   │   ├── ai-proxy-plugin.md
│   │   ├── apisix-custom-plugin-design.md
│   │   ├── apisix-plugin-system-design.md
│   │   ├── serverless-function-parameters.md
│   │   └── serverless-plugin-call-flow.md
│   ├── devcontainer/                 # DevContainer 文档
│   │   └── DEVCONTAINER_SETUP.md
│   ├── PROJECT_STRUCTURE.md
│   └── SOLUTION_2_GUIDE.md
│
├── examples/                         # 示例和工具
│   └── queue/                        # 队列插件示例
│       ├── README.md                 # 示例说明文档
│       ├── queue-worker.py           # Python Worker（5.5KB）
│       ├── queue-worker.lua          # Lua Worker（4.7KB）
│       └── test-backend-server.py    # 测试后端服务
│
└── t/                                # 测试目录
    └── queue/                        # 队列插件测试
        ├── README.md                 # 测试说明文档
        ├── test-queue-plugin.sh      # 自动化测试脚本
        ├── test-queue-logic.sh       # 逻辑测试（Bash）
        ├── test-queue-logic.py       # 逻辑测试（Python）
        ├── test-queue-demo.sh        # 完整演示脚本
        ├── test-e2e.sh               # 端到端测试
        └── check-status.sh           # 状态检查脚本
```

## 📊 文件统计

### 核心插件（8.4 KB）
- `apisix/plugins/queue-request.lua` - 4.8KB
- `apisix/plugins/queue-result.lua` - 3.6KB

### Worker 实现（10.2 KB）
- `examples/queue/queue-worker.py` - 5.5KB（推荐）
- `examples/queue/queue-worker.lua` - 4.7KB（可选）

### 文档（约 35 KB）
- `docs/queue/` - 5 个文档文件
- `docs/plugins/` - 5 个插件设计文档
- `docs/devcontainer/` - 1 个环境配置文档
- 其他文档 - 2 个

### 测试工具（约 10 KB）
- `t/queue/` - 6 个测试脚本
- `examples/queue/test-backend-server.py` - 测试服务器

**总计**: 约 25 个文件，约 63.6 KB

## 🎯 文件用途

### 核心功能
| 文件 | 用途 | 位置 |
|------|------|------|
| queue-request.lua | 接收请求并入队 | apisix/plugins/ |
| queue-result.lua | 查询处理结果 | apisix/plugins/ |
| queue-worker.py | 处理队列中的请求 | examples/queue/ |

### 文档
| 文件 | 用途 | 位置 |
|------|------|------|
| QUEUE_README.md | 主要说明文档 | docs/queue/ |
| QUEUE_QUICKSTART.md | 快速开始指南 | docs/queue/ |
| QUEUE_ARCHITECTURE.md | 架构设计 | docs/queue/ |
| QUEUE_REQUEST_DESIGN.md | 技术设计 | docs/queue/ |

### 测试
| 文件 | 用途 | 位置 |
|------|------|------|
| test-queue-plugin.sh | 完整自动化测试 | t/queue/ |
| test-e2e.sh | 端到端测试 | t/queue/ |
| test-queue-demo.sh | 功能演示 | t/queue/ |
| check-status.sh | 状态检查 | t/queue/ |

## 🚀 快速访问

### 开始使用
```bash
# 查看主文档
cat docs/queue/QUEUE_README.md

# 快速开始
cat docs/queue/QUEUE_QUICKSTART.md

# 运行测试
cd t/queue
./test-e2e.sh
```

### 开发调试
```bash
# 查看插件代码
cat apisix/plugins/queue-request.lua
cat apisix/plugins/queue-result.lua

# 启动 Worker
cd examples/queue
python3 queue-worker.py

# 检查状态
cd t/queue
./check-status.sh
```

### 查看文档
```bash
# 文档索引
cat docs/README.md

# 队列插件文档
cat docs/queue/README.md

# 示例说明
cat examples/queue/README.md

# 测试说明
cat t/queue/README.md
```

## 📝 文件移动记录

### 从根目录移动到 docs/queue/
- QUEUE_README.md
- QUEUE_QUICKSTART.md
- QUEUE_ARCHITECTURE.md
- QUEUE_REQUEST_DESIGN.md
- QUEUE_INDEX.md

### 从根目录移动到 docs/plugins/
- ai-proxy-plugin.md
- apisix-custom-plugin-design.md
- apisix-plugin-system-design.md
- serverless-function-parameters.md
- serverless-plugin-call-flow.md

### 从根目录移动到 docs/devcontainer/
- DEVCONTAINER_SETUP.md

### 从根目录移动到 docs/
- PROJECT_STRUCTURE.md
- SOLUTION_2_GUIDE.md

### 从根目录移动到 examples/queue/
- queue-worker.py
- queue-worker.lua
- test-backend-server.py

### 从根目录移动到 t/queue/
- test-queue-plugin.sh
- test-queue-logic.sh
- test-queue-logic.py
- test-queue-demo.sh
- test-e2e.sh
- check-status.sh

## 🔄 更新路径引用

如果你的代码或文档中引用了这些文件，请更新路径：

### 旧路径 → 新路径
```
/workspace/QUEUE_README.md → /workspace/docs/queue/QUEUE_README.md
/workspace/queue-worker.py → /workspace/examples/queue/queue-worker.py
/workspace/test-queue-plugin.sh → /workspace/t/queue/test-queue-plugin.sh
```

### 相对路径示例
```bash
# 从项目根目录
docs/queue/QUEUE_README.md
examples/queue/queue-worker.py
t/queue/test-queue-plugin.sh

# 从 docs/queue/ 目录
../../examples/queue/queue-worker.py
../../t/queue/test-queue-plugin.sh
../../apisix/plugins/queue-request.lua

# 从 examples/queue/ 目录
../../docs/queue/QUEUE_README.md
../../t/queue/test-queue-plugin.sh
../../apisix/plugins/queue-request.lua

# 从 t/queue/ 目录
../../docs/queue/QUEUE_README.md
../../examples/queue/queue-worker.py
../../apisix/plugins/queue-request.lua
```

## 🎨 组织原则

1. **按功能分类**: 文档、示例、测试分别放在不同目录
2. **层次清晰**: 每个目录都有 README.md 说明
3. **易于查找**: 相关文件集中在一起
4. **符合规范**: 遵循 APISIX 项目的目录结构约定

## 📖 相关文档

- [文档索引](docs/README.md)
- [队列插件文档](docs/queue/README.md)
- [示例说明](examples/queue/README.md)
- [测试说明](t/queue/README.md)

## 🤝 贡献

如果需要添加新文件，请遵循以下规则：
- 文档放在 `docs/` 目录
- 示例和工具放在 `examples/` 目录
- 测试脚本放在 `t/` 目录
- 插件代码放在 `apisix/plugins/` 目录

---

**整理完成时间**: 2026-03-08
**整理人**: Claude Code
