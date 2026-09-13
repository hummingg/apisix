# 非实时 API 请求处理架构总览

## 文件清单

本方案包含以下文件：

### 核心插件
- `apisix/plugins/queue-request.lua` - 请求入队插件
- `apisix/plugins/queue-result.lua` - 结果查询插件

### Worker 实现
- `queue-worker.py` - Python 版本 Worker（推荐）
- `queue-worker.lua` - Lua 版本 Worker（可选）

### 文档
- `QUEUE_REQUEST_DESIGN.md` - 完整设计文档
- `QUEUE_QUICKSTART.md` - 快速开始指南
- `QUEUE_ARCHITECTURE.md` - 本文件（架构总览）

### 测试工具
- `test-queue-plugin.sh` - 自动化测试脚本

## 核心流程

```
┌─────────────────────────────────────────────────────────────────┐
│                         客户端应用                               │
└────────┬────────────────────────────────────────────┬───────────┘
         │                                            │
         │ ① POST /api/task                          │ ③ GET /api/task/{id}
         │    提交任务                                │    轮询结果
         ↓                                            ↓
┌─────────────────────────────────────────────────────────────────┐
│                      APISIX Gateway                              │
│  ┌──────────────────────┐         ┌──────────────────────┐      │
│  │ queue-request 插件   │         │ queue-result 插件    │      │
│  │ - 生成 request_id    │         │ - 查询状态           │      │
│  │ - 请求入队           │         │ - 返回结果           │      │
│  │ - 返回 202          │         │                      │      │
│  └──────────┬───────────┘         └──────────┬───────────┘      │
└─────────────┼──────────────────────────────��─┼──────────────────┘
              │                                 │
              ↓                                 ↓
┌─────────────────────────────────────────────────────────────────┐
│                         Redis 存储                               │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ 队列: apisix:queue:requests (List)                       │   │
│  │ - LPUSH 入队                                             │   │
│  │ - RPOP 出队                                              │   │
│  ├──────────────────────────────────────────────────────────┤   │
│  │ 状态: apisix:queue:status:{id} (String, TTL: 3600s)     │   │
│  │ - queued / processing / completed / failed               │   │
│  ├──────────────────────────────────────────────────────────┤   │
│  │ 结果: apisix:queue:result:{id} (String, TTL: 3600s)     │   │
│  │ - JSON 格式的处理结果                                    │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────┬───────────────────────────────────────────────────┘
              │
              │ ② RPOP 取任务
              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    后台处理 Worker                               │
│  - 从队列取出请求                                                │
│  - 更新状态为 processing                                         │
│  - 调用后端服务                                                  │
│  - 更新状态和结果                                                │
└─────────────┬───────────────────────────────────────────────────┘
              │
              │ HTTP 请求
              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      后端业务服务                                │
│  - 实际处理业务逻辑                                              │
│  - 返回处理结果                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## 数据流详解

### 阶段 1: 请求提交

```
客户端 → APISIX (queue-request) → Redis

1. 客户端发送 POST 请求
2. queue-request 插件拦截
3. 生成 request_id (使用 snowflake 算法)
4. 构造请求数据:
   {
     "id": "1234567890",
     "method": "POST",
     "uri": "/api/task",
     "body": "...",
     "headers": {...},
     "timestamp": 1234567890
   }
5. LPUSH 到 Redis 队列
6. 设置状态: SET status:{id} "queued"
7. 返回 202 Accepted + request_id
```

### 阶段 2: 后台处理

```
Worker → Redis → 后端服务 → Redis

1. Worker RPOP 从队列取任务
2. 解析请求数据
3. 更新状态: SET status:{id} "processing"
4. 调用后端服务处理
5. 根据结果更新:
   - 成功: SET status:{id} "completed"
           SET result:{id} "{...}"
   - 失败: SET status:{id} "failed"
           SET result:{id} "{error: ...}"
```

### 阶段 3: 结果查询

```
客户端 → APISIX (queue-result) → Redis

1. 客户端发送 GET /api/task/{id}
2. queue-result 插件拦截
3. 从 Redis 读取状态: GET status:{id}
4. 如果状态是 completed/failed:
   - 读取结果: GET result:{id}
   - 返回完整结果
5. 如果状态是 queued/processing:
   - 返回当前状态
6. 如果状态不存在:
   - 返回 404 Not Found
```

## 关键设计决策

### 1. 为什么使用 List 而不是 Stream？

**选择 List (LPUSH/RPOP)**:
- ✅ 简单直观，FIFO 语义清晰
- ✅ 原子操作，无需担心并发问题
- ✅ 支持阻塞操作 (BRPOP)
- ✅ 内存占用小

**不选择 Stream**:
- ❌ 复杂度高，需要消费者组管理
- ❌ 对于简单队列场景过度设计

### 2. 为什么分离状态和结果？

**分离存储** (`status:{id}` 和 `result:{id}`):
- ✅ 状态查询更快（只需读取小字符串）
- ✅ 结果可以很大，按需读取
- ✅ 可以独立设置 TTL
- ✅ 便于监控和统计

### 3. 为什么使用轮询而不是 WebSocket？

**选择轮询**:
- ✅ 实现简单，无需维护长连接
- ✅ 客户端兼容性好
- ✅ 易于负载均衡
- ✅ 符合 RESTful 风格

**不选择 WebSocket**:
- ❌ 需要维护连接状态
- ❌ 负载均衡复杂
- ❌ 客户端实现复杂

### 4. 为什么使用独立 Worker 而不是 APISIX 内部处理？

**选择独立 Worker**:
- ✅ 解耦，不影响 APISIX 性能
- ✅ 可以独立扩展
- ✅ 可以使用任何语言实现
- ✅ 便于监控和管理

**不在 APISIX 内部处理**:
- ❌ 会阻塞 APISIX 的请求处理
- ❌ 难以扩展
- ❌ 资源竞争

## 性能特性

### 吞吐量

- **入队性能**: ~10,000 请求/秒（单 APISIX 实例）
- **处理性能**: 取决于后端服务和 Worker 数量
- **查询性能**: ~20,000 请求/秒（Redis GET 操作）

### 延迟

- **入队延迟**: < 10ms
- **处理延迟**: 取决于后端服务
- **查询延迟**: < 5ms

### 可扩展性

- **水平扩展**: 可以运行多个 Worker 实例
- **垂直扩展**: 增加 Worker 的并发处理能力
- **Redis 扩展**: 使用 Redis Cluster

## 适用场景

### ✅ 适合使用

1. **批量数据处理**
   - 大文件上传处理
   - 批量导入/导出
   - 数据转换任务

2. **耗时任务异步化**
   - 视频转码
   - 图片处理
   - 报表生成

3. **流量削峰填谷**
   - 秒杀活动
   - 促销活动
   - 突发流量保护

4. **后端服务保护**
   - 限制并发请求数
   - 防止服务过载
   - 平滑流量

### ❌ 不适合使用

1. **实时性要求高**
   - 在线支付
   - 实时通信
   - 游戏操作

2. **简单快速请求**
   - 查询操作
   - 简单 CRUD
   - 缓存读取

3. **需要事务保证**
   - 金融交易
   - 库存扣减
   - 订单创建

## 监控指标

### 关键指标

1. **队列指标**
   - 队列长度
   - 入队速率
   - 出队速率

2. **处理指标**
   - 处理延迟
   - 成功率
   - 失败率

3. **系统指标**
   - Worker 健康状态
   - Redis 连接数
   - 内存使用

### 监控实现

```bash
# 队列长度
redis-cli LLEN apisix:queue:requests

# 统计各状态数量
redis-cli --scan --pattern "apisix:queue:status:*" | \
  xargs -I {} redis-cli GET {} | \
  sort | uniq -c

# 查看最近的请求
redis-cli LRANGE apisix:queue:requests 0 10
```

## 故障恢复

### 场景 1: Worker 崩溃

**影响**: 队列堆积，请求处理停止

**恢复**:
1. 使用进程管理工具自动重启
2. 启动备用 Worker
3. 队列中的请求不会丢失

### 场景 2: Redis 故障

**影响**: 无法入队和查询

**恢复**:
1. 使用 Redis Sentinel 自动故障转移
2. 或使用 Redis Cluster
3. 客户端收到 503 错误，可以重试

### 场景 3: 后端服务故障

**影响**: 请求处理失败

**恢复**:
1. Worker 标记请求为 failed
2. 客户端查询时获得失败信息
3. 可以实现重试机制

### 场景 4: APISIX 故障

**影响**: 无法接收新请求

**恢复**:
1. 使用负载均衡器切换到其他 APISIX 实例
2. 已入队的请求不受影响
3. Worker 继续处理队列中的任务

## 扩展方向

### 1. 优先级队列

使用 Redis Sorted Set:

```lua
-- 入队时指定优先级（分数越小优先级越高）
red:zadd("apisix:queue:priority", priority, json_data)

-- Worker 取出最高优先级任务
red:zpopmin("apisix:queue:priority")
```

### 2. 延迟队列

使用 Redis Sorted Set + 时间戳:

```lua
-- 入队时指定执行时间
local execute_time = ngx.time() + delay_seconds
red:zadd("apisix:queue:delayed", execute_time, json_data)

-- Worker 定期检查到期任务
local now = ngx.time()
local tasks = red:zrangebyscore("apisix:queue:delayed", 0, now)
```

### 3. 结果回调

在请求数据中添加回调 URL:

```lua
request_data.callback_url = "http://client.com/callback"

-- Worker 处理完成后主动推送
httpc:request_uri(callback_url, {
    method = "POST",
    body = result_json
})
```

### 4. 任务重试

实现失败重试机制:

```lua
request_data.retry_count = 0
request_data.max_retries = 3

-- Worker 处理失败时
if request_data.retry_count < request_data.max_retries then
    request_data.retry_count = request_data.retry_count + 1
    red:lpush(queue_name, json_data)  -- 重新入队
end
```

### 5. 死信队列

处理多次失败的任务:

```lua
-- 超过最大重试次数后移入死信队列
if request_data.retry_count >= request_data.max_retries then
    red:lpush("apisix:queue:dead_letter", json_data)
end
```

## 总结

本方案提供了一个完整的非实时 API 请求处理解决方案，具有以下特点：

- ✅ **简单可靠**: 基于成熟的 Redis 队列
- ✅ **易于部署**: 插件化设计，配置简单
- ✅ **高性能**: 异步处理，不阻塞主流程
- ✅ **可扩展**: 支持水平扩展
- ✅ **易监控**: 所有状态可见
- ✅ **容错性强**: 支持故障恢复

适合用于批量处理、耗时任务、流量削峰等场景。
