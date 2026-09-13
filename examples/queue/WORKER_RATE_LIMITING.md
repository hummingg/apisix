# Worker 处理频率配置说明

## 📊 当前配置

Worker 现在支持两种处理模式：

### 1. 无限制模式（默认之前的行为）
```python
CONFIG = {
    'process_interval': 0,  # 设为 0 表示无限制
}
```
- 只要队列中有请求，就立即连续处理
- 适合高吞吐量场景

### 2. 限流模式（你需要的）
```python
CONFIG = {
    'process_interval': 30,  # 每30秒处理一个请求
}
```
- 每处理完一个请求后，等待指定的秒数
- 适合需要限制后端负载的场景

## 🔧 配置参数说明

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `poll_interval` | 队列为空时的等待时间 | 1秒 | 1 |
| `process_interval` | 处理请求的间隔时间 | 30秒 | 30 |
| `request_timeout` | 单个请求的超时时间 | 30秒 | 30 |

## 📝 配置示例

### 示例 1: 每30秒处理一个请求（你的需求）

```python
CONFIG = {
    'redis_host': '127.0.0.1',
    'redis_port': 6379,
    'redis_password': None,
    'redis_db': 0,
    'queue_name': 'apisix:queue:requests',
    'backend_url': 'http://127.0.0.1:8080/api/process',
    'poll_interval': 1,        # 队列为空时等待1秒
    'process_interval': 30,    # 每30秒处理一个请求 ⭐
    'request_timeout': 30,
    'result_ttl': 3600,
}
```

### 示例 2: 每分钟处理一个请求

```python
CONFIG = {
    'process_interval': 60,    # 每60秒处理一个请求
}
```

### 示例 3: 无限制（最快速度）

```python
CONFIG = {
    'process_interval': 0,     # 无限制，立即处理
}
```

## 🚀 使用方法

### 1. 修改配置

编辑 `examples/queue/queue-worker.py`，修改 `CONFIG` 中的 `process_interval`：

```python
'process_interval': 30,  # 改为你想要的秒数
```

### 2. 重启 Worker

```bash
# 停止旧的 Worker
pkill -f queue-worker.py

# 启动新的 Worker
cd examples/queue
python3 queue-worker.py
```

或使用启动脚本：

```bash
./stop-test-env.sh
./start-test-env.sh
```

### 3. 验证配置

启动 Worker 后，会看到日志：

```
[2026-03-08 15:30:00] [INFO] Starting queue worker...
[2026-03-08 15:30:00] [INFO] Redis: 127.0.0.1:6379
[2026-03-08 15:30:00] [INFO] Queue: apisix:queue:requests
[2026-03-08 15:30:00] [INFO] Backend: http://127.0.0.1:8080/api/process
[2026-03-08 15:30:00] [INFO] Process interval: 30s  ⭐ 这里显示间隔时间
[2026-03-08 15:30:00] [INFO] ==================================================
```

## 📊 工作原理

### 限流模式的处理流程

```
1. 从队列取出请求
2. 检查距离上次处理的时间
3. 如果时间不足 process_interval:
   - 将请求放回队列
   - 等待剩余时间
   - 重新开始
4. 如果时间已足够:
   - 处理请求
   - 记录处理时间
   - 继续下一个
```

### 日志示例

```
[15:30:00] Processing request: 123456
[15:30:01] Request completed: 123456
[15:30:01] Rate limiting: waiting 29.0s before next request
[15:30:30] Processing request: 123457
[15:30:31] Request completed: 123457
[15:30:31] Rate limiting: waiting 29.0s before next request
```

## 🎯 使用场景

### 适合使用限流模式的场景

1. **保护后端服务**
   - 后端服务处理能力有限
   - 避免过载

2. **控制成本**
   - 调用外部 API 有频率限制
   - 按调用次数计费

3. **平滑流量**
   - 避免突发流量
   - 均匀分布负载

### 适合使用无限制模式的场景

1. **高吞吐量需求**
   - 需要快速处理大量请求
   - 后端服务能力充足

2. **批量处理**
   - 一次性处理大量积压请求
   - 临时提高处理速度

## 🔍 监控和调试

### 查看处理速度

```bash
# 查看 Worker 日志
tail -f logs/worker.log

# 查看队列长度
redis-cli LLEN apisix:queue:requests

# 查看处理统计
redis-cli KEYS "apisix:queue:status:*" | wc -l
```

### 调整建议

| 队列长度 | 建议 |
|---------|------|
| 持续为 0 | 可以增加 process_interval（降低频率） |
| 持续增长 | 应该减少 process_interval（提高频率） |
| 稳定在某个值 | 当前配置合适 |

## ⚙️ 高级配置

### 使用环境变量

```bash
# 通过环境变量设置
export PROCESS_INTERVAL=30
python3 queue-worker.py
```

修改代码支持环境变量：

```python
import os

CONFIG = {
    'process_interval': int(os.getenv('PROCESS_INTERVAL', 30)),
}
```

### 动态调整

可以通过 Redis 动态调整（需要修改代码）：

```python
# 从 Redis 读取配置
process_interval = red.get('worker:config:process_interval') or 30
```

## 📖 相关文档

- [Worker 使用说明](README.md)
- [队列插件文档](../../docs/queue/README.md)
- [测试指南](../../t/queue/README.md)

---

**更新时间**: 2026-03-08
**配置版本**: v1.1
