# APISIX 非实时 API 请求处理设计方案

## 概述

本方案实现了基于 Redis 队列的非实时 API 请求处理系统，用于保护后端服务免受流量冲击。客户端提交请求后立即获得 `request_id`，然后通过轮询查询处理结果。

## 架构设计

### 系统架构图

```
┌─────────────┐
│   客户端     │
└──────┬──────┘
       │ 1. POST /api/task
       │    (提交任务)
       ↓
┌─────────────────────────────────┐
│  APISIX Gateway                 │
│  ┌───────────────────────────┐  │
│  │ queue-request 插件        │  │
│  │ - 生成 request_id         │  │
│  │ - 请求入队到 Redis        │  │
│  │ - 返回 202 + request_id   │  │
│  └───────────────────────────┘  │
└──────────┬──────────────────────┘
           │
           ↓
┌─────────────────────────────────┐
│      Redis 队列存储              │
│  ┌───────────────────────────┐  │
│  │ queue:requests (List)     │  │
│  │ status:{id} (String)      │  │
│  │ result:{id} (String)      │  │
│  └───────────────────────────┘  │
└──────────┬──────────────────────┘
           │
           ↓
┌─────────────────────────────────┐
│    后台处理 Worker               │
│  - RPOP 从队列取任务             │
│  - 调用后端服务处理              │
│  - 更新状态和结果到 Redis        │
└──────────┬──────────────────────┘
           │
           ↓
┌─────────────────────────────────┐
│      后端业务服务                │
│  - 实际处理业务逻辑              │
│  - 返回处理结果                  │
└─────────────────────────────────┘
           ↑
           │ 2. GET /api/task/{id}
           │    (轮询查询结果)
┌──────────┴────���─┐
│   客户端         │
└─────────────────┘
```

### 数据流程

1. **请求提交阶段**
   - 客户端发送 POST 请求到 APISIX
   - `queue-request` 插件拦截请求
   - 生成唯一的 `request_id`
   - 将请求数据序列化后推入 Redis 队列
   - 设置初始状态为 `queued`
   - 立即返回 `202 Accepted` 和 `request_id`

2. **后台处理阶段**
   - Worker 从 Redis 队列取出请求
   - 更新状态为 `processing`
   - 调用后端服务处理请求
   - 根据处理结果更新状态为 `completed` 或 `failed`
   - 将结果存储到 Redis

3. **结果查询阶段**
   - 客户端使用 `request_id` 轮询查询
   - `queue-result` 插件从 Redis 读取状态和结果
   - 返回当前状态或最终结果

## 核心组件

### 1. queue-request 插件

**文件位置**: `apisix/plugins/queue-request.lua`

**功能**:
- 接收客户端请求
- 生成唯一请求 ID
- 将请求数据入队到 Redis
- 返回 202 状态码和请求 ID

**配置参数**:
```yaml
redis_host: "127.0.0.1"           # Redis 服务器地址
redis_port: 6379                  # Redis 端口
redis_password: "password"        # Redis 密码（可选）
redis_database: 0                 # Redis 数据库编号
redis_timeout: 1000               # 连接超时（毫秒）
queue_name: "apisix:queue:requests"  # 队列名称
result_ttl: 3600                  # 结果过期时间（秒）
max_queue_size: 10000             # 最大队列长度
```

**返回格式**:
```json
{
  "request_id": "1234567890",
  "status": "queued",
  "message": "request has been queued for processing",
  "poll_url": "/apisix/admin/queue/result/1234567890"
}
```

### 2. queue-result 插件

**文件位置**: `apisix/plugins/queue-result.lua`

**功能**:
- 根据 request_id 查询处理状态
- 返回处理结果（如果已完成）

**配置参数**:
```yaml
redis_host: "127.0.0.1"
redis_port: 6379
redis_password: "password"
redis_database: 0
```

**返回格式**:

处理中:
```json
{
  "request_id": "1234567890",
  "status": "processing",
  "message": "request is still being processed"
}
```

已完成:
```json
{
  "request_id": "1234567890",
  "status": "completed",
  "result": {
    "status_code": 200,
    "body": "..."
  },
  "timestamp": 1234567890
}
```

失败:
```json
{
  "request_id": "1234567890",
  "status": "failed",
  "error": "connection timeout",
  "timestamp": 1234567890
}
```

### 3. 后台 Worker

**文件位置**: `queue-worker.lua`

**功能**:
- 从 Redis 队列取出请求
- 调用后端服务处理
- 更新处理状态和结果

**运行方式**:
```bash
# 使用 OpenResty 运行
openresty -p /path/to/apisix -c conf/nginx.conf

# 或使用独立 Lua 脚本
lua queue-worker.lua
```

## Redis 数据结构

### 队列数据

**队列**: `apisix:queue:requests` (List)
```
LPUSH apisix:queue:requests '{"id":"123","method":"POST","uri":"/api/task","body":"..."}'
RPOP apisix:queue:requests
```

### 状态数据

**状态键**: `apisix:queue:status:{request_id}` (String, TTL: 3600s)
```
SET apisix:queue:status:123 "queued" EX 3600
SET apisix:queue:status:123 "processing" EX 3600
SET apisix:queue:status:123 "completed" EX 3600
SET apisix:queue:status:123 "failed" EX 3600
```

### 结果数据

**结果键**: `apisix:queue:result:{request_id}` (String, TTL: 3600s)
```json
{
  "request_id": "123",
  "status": "completed",
  "result": {
    "status_code": 200,
    "headers": {...},
    "body": "..."
  },
  "timestamp": 1234567890
}
```

## 部署配置

### 1. 启用插件

编辑 `conf/config.yaml`:

```yaml
plugins:
  - queue-request
  - queue-result
  # ... 其他插件
```

### 2. 配置路由

#### 提交任务路由

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "uri": "/api/task",
  "methods": ["POST"],
  "plugins": {
    "queue-request": {
      "redis_host": "127.0.0.1",
      "redis_port": 6379,
      "queue_name": "apisix:queue:requests",
      "result_ttl": 3600,
      "max_queue_size": 10000
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "127.0.0.1:8080": 1
    }
  }
}'
```

#### 查询结果路由

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/2 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "uri": "/api/task/:request_id",
  "methods": ["GET"],
  "plugins": {
    "queue-result": {
      "redis_host": "127.0.0.1",
      "redis_port": 6379
    }
  }
}'
```

### 3. 启动 Worker

```bash
# 方式 1: 使用 systemd 管理
sudo systemctl start apisix-queue-worker

# 方式 2: 直接运行
lua queue-worker.lua &

# 方式 3: 使用 supervisor
supervisorctl start apisix-queue-worker
```

## 使用示例

### 客户端代码示例

```javascript
// 1. 提交任务
async function submitTask(data) {
  const response = await fetch('http://localhost:9080/api/task', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(data)
  });

  const result = await response.json();
  return result.request_id;
}

// 2. 轮询查询结果
async function pollResult(requestId, maxAttempts = 30, interval = 2000) {
  for (let i = 0; i < maxAttempts; i++) {
    const response = await fetch(`http://localhost:9080/api/task/${requestId}`);
    const result = await response.json();

    if (result.status === 'completed') {
      return result.result;
    }

    if (result.status === 'failed') {
      throw new Error(result.error);
    }

    // 等待后重试
    await new Promise(resolve => setTimeout(resolve, interval));
  }

  throw new Error('Timeout waiting for result');
}

// 使用示例
async function main() {
  try {
    // 提交任务
    const requestId = await submitTask({ action: 'process', data: '...' });
    console.log('Task submitted:', requestId);

    // 轮询结果
    const result = await pollResult(requestId);
    console.log('Task completed:', result);
  } catch (error) {
    console.error('Error:', error);
  }
}
```

### Python 客户端示例

```python
import requests
import time

def submit_task(data):
    """提交任务"""
    response = requests.post(
        'http://localhost:9080/api/task',
        json=data
    )
    result = response.json()
    return result['request_id']

def poll_result(request_id, max_attempts=30, interval=2):
    """轮询查询结果"""
    for _ in range(max_attempts):
        response = requests.get(
            f'http://localhost:9080/api/task/{request_id}'
        )
        result = response.json()

        if result['status'] == 'completed':
            return result['result']

        if result['status'] == 'failed':
            raise Exception(result['error'])

        time.sleep(interval)

    raise TimeoutError('Timeout waiting for result')

# 使用示例
if __name__ == '__main__':
    # 提交任务
    request_id = submit_task({'action': 'process', 'data': '...'})
    print(f'Task submitted: {request_id}')

    # 轮询结果
    result = poll_result(request_id)
    print(f'Task completed: {result}')
```

## 性能优化建议

### 1. Redis 优化

- 使用 Redis Cluster 提高可用性
- 配置合适的内存淘汰策略
- 使用 Redis Pipeline 批量操作

### 2. Worker 优化

- 运行多个 Worker 实例并行处理
- 使用连接池复用 HTTP 连接
- 实现优雅关闭机制

### 3. 队列优化

- 设置合理的队列长度限制
- 实现优先级队列（使用 Sorted Set）
- 添加死信队列处理失败任务

### 4. 监控指标

- 队列长度
- 处理延迟
- 成功/失败率
- Worker 健康状态

## 扩展功能

### 1. 优先级队列

使用 Redis Sorted Set 实现:

```lua
-- 入队时指定优先级
red:zadd("apisix:queue:priority", priority, json_data)

-- Worker 取出最高优先级任务
red:zpopmax("apisix:queue:priority")
```

### 2. 任务超时处理

```lua
-- 设置任务超时时间
local timeout_key = "apisix:queue:timeout:" .. request_id
red:setex(timeout_key, timeout, "1")

-- Worker 检查超时
if red:exists(timeout_key) == 0 then
    -- 任务超时，标记为失败
end
```

### 3. 结果回调

```lua
-- 在请求数据中添加回调 URL
request_data.callback_url = "http://client.com/callback"

-- Worker 处理完成后调用回调
httpc:request_uri(request_data.callback_url, {
    method = "POST",
    body = result_json
})
```

## 故障处理

### 1. Redis 连接失败

- 返回 503 Service Unavailable
- 实现重试机制
- 使用 Redis Sentinel 或 Cluster

### 2. 队列满

- 返回 429 Too Many Requests
- 提示客户端稍后重试
- 考虑扩容或优化处理速度

### 3. Worker 崩溃

- 使用进程管理工具（systemd, supervisor）自动重启
- 实现健康检查
- 记录详细日志

### 4. 任务丢失

- 使用 Redis AOF 持久化
- 实现任务确认机制
- 定期备份队列数据

## 总结

本方案通过 APISIX 插件和 Redis 队列实现了非实时 API 请求处理，具有以下优势：

1. **保护后端**: 通过队列缓冲请求，避免流量冲击
2. **高可用**: 基于 Redis 的可靠存储
3. **可扩展**: 可以水平扩展 Worker 数量
4. **易监控**: 所有状态都存储在 Redis 中
5. **灵活配置**: 支持多种参数调整

适用场景：
- 批量数据处理
- 耗时任务异步化
- 流量削峰填谷
- 后端服务保护
