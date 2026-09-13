# 测试后端服务说明

## 🤔 为什么不加入 DevContainer？

### test-backend-server.py 的定位
- **测试工具**，不是核心依赖
- 仅用于演示和测试队列插件
- 实际使用时，用户会有自己的后端服务

### DevContainer 设计原则
DevContainer 应该只包含**核心基础设施**：

| 服务 | 是否包含 | 原因 |
|------|---------|------|
| etcd | ✅ 是 | APISIX 配置中心，必需 |
| Redis | ✅ 是 | 队列插件依赖，必需 |
| test-backend-server | ❌ 否 | 测试工具，可选 |

### 灵活性考虑
用户可能需要：
- 使用自己的后端服务
- 使用不同的端口（非 8080）
- 使用不同的实现（Go、Java、Node.js 等）
- 完全不需要测试服务

## ✅ 推荐的使用方式

### 方式 1: 使用启动脚本（最简单）

```bash
# 一键启动完整测试环境
./start-test-env.sh

# 运行测试
cd t/queue && ./test-e2e.sh

# 停止所有服务
./stop-test-env.sh
```

### 方式 2: 手动启动（更灵活）

```bash
# 1. 启动 APISIX
make init && make run

# 2. 启动测试后端服务
cd examples/queue
python3 test-backend-server.py

# 3. 启动 Worker（新终端）
cd examples/queue
python3 queue-worker.py

# 4. 运行测试（新终端）
cd t/queue
./test-e2e.sh
```

### 方式 3: 后台运行

```bash
# 启动测试后端服务（后台）
cd examples/queue
nohup python3 test-backend-server.py > ../../logs/backend.log 2>&1 &

# 启动 Worker（后台）
nohup python3 queue-worker.py > ../../logs/worker.log 2>&1 &

# 查看日志
tail -f logs/backend.log
tail -f logs/worker.log
```

## 🔧 使用自己的后端服务

如果你有自己的后端服务，只需修改 Worker 配置：

### 修改 queue-worker.py

```python
CONFIG = {
    'backend_url': 'http://your-backend:8080/api/process',  # 修改这里
    # ... 其他配置
}
```

### 或使用环境变量

```bash
export BACKEND_URL="http://your-backend:8080/api/process"
python3 queue-worker.py
```

## 📊 服务端口总览

| 服务 | 端口 | 启动方式 | 必需性 |
|------|------|---------|--------|
| APISIX | 9080, 9180 | `make run` | ✅ 必需 |
| etcd | 2379 | DevContainer 自动启动 | ✅ 必需 |
| Redis | 6379 | DevContainer 自动启动 | ✅ 必需 |
| test-backend-server | 8080 | 手动启动 | ❌ 可选 |
| queue-worker | - | 手动启动 | ✅ 必需（使用队列插件时） |

## 🎯 不同场景的启动方式

### 场景 1: 快速测试队列插件
```bash
./start-test-env.sh
cd t/queue && ./test-e2e.sh
```

### 场景 2: 开发自己的后端服务
```bash
# 只启动 APISIX 和 Worker
make init && make run
cd examples/queue && python3 queue-worker.py

# 启动你自己的后端服务
cd /path/to/your/backend && ./start.sh
```

### 场景 3: 只开发 APISIX 插件
```bash
# 只启动 APISIX
make init && make run

# 不需要 Worker 和后端服务
```

## 📖 相关文档

- [启动脚本说明](start-test-env.sh) - 一键启动测试环境
- [停止脚本说明](stop-test-env.sh) - 一键停止所有服务
- [测试后端服务代码](examples/queue/test-backend-server.py)
- [Worker 配置说明](examples/queue/README.md)
- [队列插件文档](docs/queue/README.md)

## 💡 最佳实践

1. **开发阶段**: 使用 `start-test-env.sh` 快速启动完整环境
2. **测试阶段**: 使用测试脚本自动化测试
3. **生产环境**: 使用自己的后端服务，配置 Worker 连接

---

**总结**: test-backend-server.py 是一个可选的测试工具，不应该加入 DevContainer。使用提供的启动脚本可以方便地启动完整的测试环境。
