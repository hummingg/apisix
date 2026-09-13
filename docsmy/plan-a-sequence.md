# 方案 A 时序图（Redis Cluster + 动态检查优化版本）

## 正常流程（请求成功 - 月初场景）

```mermaid
sequenceDiagram
    participant Client as 客户端
    participant APISIX as APISIX 网关
    participant SharedDict as shared_dict<br/>(检查标志)
    participant RedisCluster as Redis Cluster
    participant LLM as 大模型服务
    participant MySQL as MySQL
    participant Timer as 异步任务

    Client->>APISIX: 1. 发送请求

    Note over APISIX: access 阶段
    APISIX->>APISIX: 2. 预估 Token (estimate_tokens)
    APISIX->>SharedDict: 3. 读取月/年检查标志<br/>(6 次本地内存读取 < 0.1ms)

    Note over SharedDict: 月初场景：<br/>所有月/年标志 = 0 (不检查)

    APISIX->>RedisCluster: 4. Pipeline INCRBY 预扣减<br/>(仅 3 个 key：日维度)

    Note over RedisCluster: resty-redis-cluster 自动处理：<br/>- 计算 slot<br/>- 并行发送

    alt 日维度超限
        RedisCluster-->>APISIX: 返回新值 > 限额
        APISIX->>RedisCluster: 5a. Pipeline INCRBY 回退
        RedisCluster-->>APISIX: 回退完成
        APISIX-->>Client: 5b. 返回 429 Too Many Requests
    else 日维度未超限
        RedisCluster-->>APISIX: 返回新值 <= 限额

        Note over APISIX: 月/年维度异步更新（不检查限额）

        APISIX->>Timer: 6. 启动异步任务<br/>更新月/年计数
        APISIX->>LLM: 7. 转发请求

        Timer->>RedisCluster: 8. Pipeline INCRBY<br/>(6 个 key：月/年维度)
        RedisCluster-->>Timer: 完成

        LLM-->>APISIX: 9. 返回响应 (含实际 Token 数)

        Note over APISIX: log 阶段
        APISIX->>APISIX: 10. 提取实际 Token
        APISIX->>APISIX: 11. 计算差值 diff

        par 并行执行
            APISIX->>MySQL: 12a. 写入日志表
        and
            APISIX->>Timer: 12b. 异步调整差值
            Timer->>RedisCluster: 13. Pipeline INCRBY 差值
            RedisCluster-->>Timer: 完成
        end

        APISIX-->>Client: 14. 返回响应
    end
```

## 正常流程（请求成功 - 月底场景）

```mermaid
sequenceDiagram
    participant Client as 客户端
    participant APISIX as APISIX 网关
    participant SharedDict as shared_dict<br/>(检查标志)
    participant RedisCluster as Redis Cluster
    participant LLM as 大模型服务

    Client->>APISIX: 1. 发送请求

    Note over APISIX: access 阶段
    APISIX->>APISIX: 2. 预估 Token
    APISIX->>SharedDict: 3. 读取月/年检查标志

    Note over SharedDict: 月底场景：<br/>月标志 = 1 (需要检查)<br/>年标志 = 0 (不检查)

    APISIX->>RedisCluster: 4. Pipeline INCRBY 预扣减<br/>(6 个 key：日 + 月维度)

    alt 日或月维度超限
        RedisCluster-->>APISIX: 某个维度超限
        APISIX->>RedisCluster: 5a. Pipeline INCRBY 回退
        APISIX-->>Client: 5b. 返回 429
    else 未超限
        RedisCluster-->>APISIX: 所有维度通过
        APISIX->>LLM: 6. 转发请求
        LLM-->>APISIX: 7. 返回响应
        APISIX-->>Client: 8. 返回响应
    end
```

## Java 服务推送检查标志流程

```mermaid
sequenceDiagram
    participant Scheduler as 定时任务<br/>(每分钟)
    participant MySQL as MySQL
    participant Service as TokenMonitorService
    participant APISIX as APISIX Admin API
    participant SharedDict as shared_dict

    Note over Scheduler: 每分钟触发

    Scheduler->>MySQL: 1. 查询 token_usage_log<br/>聚合日/月/年消耗

    MySQL-->>Scheduler: 2. 返回聚合结果<br/>[{model_id, month_usage, month_limit, ...}]

    Scheduler->>Service: 3. 计算消耗百分比

    loop 遍历每个实体
        Service->>Service: 4. 判断月维度<br/>usage/limit >= 80% ?
        Service->>Service: 5. 判断年维度<br/>usage/limit >= 90% ?
    end

    Service->>Service: 6. 对比上次标志<br/>找出变化的部分

    alt 有标志变化
        Service->>APISIX: 7. PUT /apisix/admin/shared_dict/token_check_flags<br/>{<br/>  "check:model:m1:month:202604": 1,<br/>  "check:api:a1:year:2026": 0<br/>}

        APISIX->>SharedDict: 8. 批量更新标志<br/>(TTL 1 小时)

        SharedDict-->>APISIX: 9. 更新完成
        APISIX-->>Service: 10. 返回成功

        Note over Service: 记录日志：<br/>model:m1 月维度达到 85%，已启用检查
    else 无变化
        Note over Service: 跳过推送
    end
```

## 外部服务架构交互图

```mermaid
graph TB
    subgraph "APISIX 网关集群"
        A1[APISIX Worker 1]
        A2[APISIX Worker 2]
        A3[APISIX Worker N]
        SD[shared_dict<br/>token_check_flags]

        A1 -.读取标志.-> SD
        A2 -.读取标志.-> SD
        A3 -.读取标志.-> SD
    end

    subgraph "Java 监控服务"
        JS[TokenMonitorService<br/>定时任务]
        JR[TokenUsageRepository]
        AC[ApisixAdminClient]

        JS --> JR
        JS --> AC
    end

    subgraph "数据存储"
        RC[Redis Cluster<br/>实时计数]
        DB[(MySQL<br/>token_usage_log)]
    end

    A1 --> RC
    A2 --> RC
    A3 --> RC

    A1 -.写日志.-> DB
    A2 -.写日志.-> DB
    A3 -.写日志.-> DB

    JR -.查询聚合.-> DB
    AC -.HTTP API.-> SD

    style SD fill:#f9f,stroke:#333,stroke-width:2px
    style JS fill:#9cf,stroke:#333,stroke-width:2px
```

## 关键时间点（动态检查优化版本）

| 阶段 | 操作 | 月初耗时 | 月底耗时 | 说明 |
|---|---|---|---|---|
| access | 预估 Token | < 1ms | < 1ms | 本地计算 |
| access | 读取检查标志 | < 0.1ms | < 0.1ms | shared_dict 本地内存读取 |
| access | Pipeline INCRBY | **0.5-1ms** | 1-1.5ms | 月初 3 key，月底 6 key |
| access | 超限回退 | 0.5-1ms | 1-1.5ms | 仅超限时触发 |
| access | 异步更新月/年 | 异步 | - | 月初需要，月底不需要 |
| access | 转发上游 | 100-5000ms | 100-5000ms | 取决于模型响应速度 |
| log | 提取实际 Token | < 1ms | < 1ms | 解析 JSON |
| log | 写 MySQL | 5-20ms | 5-20ms | 异步，不阻塞响应 |
| log | 更新 Redis | 1-3ms | 1-3ms | 异步，不阻塞响应 |
| Java 服务 | 聚合查询 | 100-500ms | 100-500ms | 每分钟一次 |
| Java 服务 | 推送标志 | 10-50ms | 10-50ms | 仅推送变化的标志 |

**性能提升：**
- 月初场景：从 1-3ms 降低到 **0.5-1ms**（提升 50%）
- 月底场景：1-1.5ms（仅检查需要的维度）
- 年底场景：1.5-2ms（检查日+月+年）

## 性能对比

| 场景 | 原方案（检查 9 key） | 优化方案（动态检查） | 提升 |
|---|---|---|---|
| 月初/年初 | 1-3ms | **0.5-1ms** | 50-66% |
| 月中（月维度启用） | 1-3ms | 1-1.5ms | 25-50% |
| 月底/年底 | 1-3ms | 1.5-2ms | 16-33% |

## 标志推送示例

### 场景 1：月初（所有标志为 0）

```json
{
  "check:model:gpt-4:month:202604": 0,
  "check:model:gpt-4:year:2026": 0,
  "check:api:api_001:month:202604": 0,
  "check:api:api_001:year:2026": 0,
  "check:app:app_123:month:202604": 0,
  "check:app:app_123:year:2026": 0
}
```

**APISIX 行为：**
- 只检查 3 个 key（日维度）
- 月/年维度异步更新，不检查限额

### 场景 2：月底（月维度达到 85%）

```json
{
  "check:model:gpt-4:month:202604": 1,  // 变化：0 → 1
  "check:model:gpt-4:year:2026": 0,
  "check:api:api_001:month:202604": 1,  // 变化：0 → 1
  "check:api:api_001:year:2026": 0,
  "check:app:app_123:month:202604": 0,
  "check:app:app_123:year:2026": 0
}
```

**Java 服务只推送变化的 2 个标志：**
```json
{
  "check:model:gpt-4:month:202604": 1,
  "check:api:api_001:month:202604": 1
}
```

**APISIX 行为：**
- 检查 6 个 key（日 + 月维度）
- 年维度仍然异步更新

### 场景 3：年底（年维度达到 92%）

```json
{
  "check:model:gpt-4:month:202612": 1,
  "check:model:gpt-4:year:2026": 1,  // 变化：0 → 1
  "check:api:api_001:month:202612": 1,
  "check:api:api_001:year:2026": 1,  // 变化：0 → 1
  "check:app:app_123:month:202612": 0,
  "check:app:app_123:year:2026": 0
}
```

**APISIX 行为：**
- 检查 9 个 key（日 + 月 + 年维度）
- 全维度严格限流

## 故障容错

### Java 服务故障

```mermaid
sequenceDiagram
    participant APISIX as APISIX
    participant SharedDict as shared_dict
    participant Java as Java 服务

    Note over Java: Java 服务宕机

    APISIX->>SharedDict: 读取检查标志
    SharedDict-->>APISIX: 返回标志 (TTL 1 小时)

    Note over SharedDict: 1 小时后标志过期

    APISIX->>SharedDict: 读取检查标志
    SharedDict-->>APISIX: 返回 nil (已过期)

    Note over APISIX: 降级策略：<br/>标志为 nil 时默认检查<br/>（保守策略，避免超限）

    APISIX->>APISIX: 检查所有维度（9 key）
```

**容错机制：**
1. 标志 TTL 设置为 1 小时
2. 标志过期后，APISIX 默认检查所有维度（降级为原方案）
3. Java 服务恢复后，自动重新推送标志

### Redis Cluster 故障

```mermaid
sequenceDiagram
    participant APISIX as APISIX
    participant RedisCluster as Redis Cluster

    APISIX->>RedisCluster: Pipeline INCRBY

    Note over RedisCluster: 节点故障

    RedisCluster--xAPISIX: 连接失败

    Note over APISIX: 降级策略：<br/>允许请求通过<br/>（避免影响业务）

    APISIX-->>APISIX: 返回 true (放行)
```

**容错机制：**
1. Redis 连接失败时，插件降级放行
2. 定期同步任务会从日志表校准数据
3. Redis 恢复后，自动恢复限流功能

## 数据一致性保障

```mermaid
graph TD
    A[请求到达] --> B[读取检查标志]
    B --> C{需要检查?}

    C -->|是| D[Redis 预扣减 + 检查限额]
    C -->|否| E[Redis 预扣减（异步，不检查）]

    D --> F{上游成功?}
    E --> F

    F -->|成功| G[提取实际 Token]
    F -->|失败| H[回退预扣减]

    G --> I[计算差值]
    I --> J[异步更新 Redis]
    J --> K[写入日志表]
    H --> K

    K --> L[Java 服务定期聚合]
    L --> M{消耗百分比}

    M -->|>= 阈值| N[推送标志 = 1<br/>启用检查]
    M -->|< 阈值| O[推送标志 = 0<br/>不检查]

    N --> P[APISIX 更新 shared_dict]
    O --> P

    style N fill:#f96,stroke:#333,stroke-width:2px
    style L fill:#9cf,stroke:#333,stroke-width:2px
    style P fill:#f9f,stroke:#333,stroke-width:2px
```


## 上游失败流程（5xx/超时）

```mermaid
sequenceDiagram
    participant Client as 客户端
    participant APISIX as APISIX 网关
    participant RedisCluster as Redis Cluster
    participant LLM as 大模型服务
    participant Timer as 异步任务

    Client->>APISIX: 1. 发送请求

    Note over APISIX: access 阶段
    APISIX->>APISIX: 2. 预估 Token
    APISIX->>RedisCluster: 3. Pipeline INCRBY 预扣减<br/>(estimated_tokens)
    RedisCluster-->>APISIX: 返回成功

    APISIX->>LLM: 4. 转发请求

    alt 上游超时
        LLM--xAPISIX: 5a. 超时无响应
    else 上游 5xx
        LLM-->>APISIX: 5b. 返回 500/502/503
    end

    Note over APISIX: log 阶段
    APISIX->>APISIX: 6. 检测 upstream_status<br/>(0 或 >= 500)
    APISIX->>Timer: 7. 启动回退任务<br/>rollback_estimated_tokens

    Timer->>RedisCluster: 8. Pipeline INCRBY -estimated_tokens<br/>(回退 9 个维度)
    RedisCluster-->>Timer: 9. 完成

    APISIX-->>Client: 10. 返回错误响应
```

## Redis Cluster 内部处理流程

```mermaid
sequenceDiagram
    participant Plugin as ai-token-limit 插件
    participant RRC as resty-redis-cluster
    participant Node1 as Redis 节点 1<br/>(slot 0-5460)
    participant Node2 as Redis 节点 2<br/>(slot 5461-10922)
    participant Node3 as Redis 节点 3<br/>(slot 10923-16383)

    Plugin->>RRC: init_pipeline()
    Plugin->>RRC: incrby("token:model:m1:day:20260407", 100)
    Plugin->>RRC: incrby("token:api:a1:day:20260407", 100)
    Plugin->>RRC: incrby("token:app:app1:day:20260407", 100)
    Plugin->>RRC: ... (共 9 个 key)

    Plugin->>RRC: commit_pipeline()

    Note over RRC: 1. 计算每个 key 的 slot<br/>2. 按 slot 分组命令<br/>3. 构建多个 pipeline

    par 并行发送到不同节点
        RRC->>Node1: Pipeline 1<br/>(slot 0-5460 的 key)
        RRC->>Node2: Pipeline 2<br/>(slot 5461-10922 的 key)
        RRC->>Node3: Pipeline 3<br/>(slot 10923-16383 的 key)
    end

    par 并行返回结果
        Node1-->>RRC: 结果 1
        Node2-->>RRC: 结果 2
        Node3-->>RRC: 结果 3
    end

    Note over RRC: 合并结果，按原始顺序返回

    RRC-->>Plugin: results = [val1, val2, val3, ...]
```

## 超限回退流程详解

```mermaid
sequenceDiagram
    participant Plugin as ai-token-limit 插件
    participant RedisCluster as Redis Cluster

    Plugin->>RedisCluster: Pipeline INCRBY 9 个 key

    Note over RedisCluster: 自动按 slot 分组并行执行

    RedisCluster-->>Plugin: results = [<br/>  9500,  # key1 新值<br/>  10000, # key2 新值<br/>  10500, # key3 新值 (超限!)<br/>  ...<br/>]

    Plugin->>Plugin: 检测 results[3] > limit

    Note over Plugin: 发现 key3 超限，需要回退

    Plugin->>RedisCluster: Pipeline INCRBY 回退<br/>- key1: -100<br/>- key2: -100<br/>- key3: -100<br/>(回退所有已扣减的 key)

    Note over RedisCluster: 回退操作不是原子的<br/>但窗口极短（毫秒级）

    RedisCluster-->>Plugin: 回退完成

    Plugin-->>Plugin: 返回 429 错误
```

## 优化版：本地聚合 + 批量刷新

```mermaid
sequenceDiagram
    participant Client as 客户端
    participant APISIX as APISIX 网关
    participant SharedDict as shared_dict<br/>(本地缓存)
    participant RedisCluster as Redis Cluster
    participant LLM as 大模型服务
    participant MySQL as MySQL
    participant BatchTimer as 批量刷新定时器

    Client->>APISIX: 1. 发送请求

    Note over APISIX: access 阶段
    APISIX->>APISIX: 2. 预估 Token
    APISIX->>RedisCluster: 3. Pipeline INCRBY 预扣减
    RedisCluster-->>APISIX: 返回成功

    APISIX->>LLM: 4. 转发请求
    LLM-->>APISIX: 5. 返回响应

    Note over APISIX: log 阶段
    APISIX->>APISIX: 6. 提取实际 Token
    APISIX->>APISIX: 7. 计算差值 diff
    APISIX->>SharedDict: 8. shared_dict:incr(key, diff)<br/>(本地累加，无网络开销)
    APISIX->>MySQL: 9. 写入日志表
    APISIX-->>Client: 10. 返回响应

    Note over BatchTimer: 每 5 秒执行一次
    BatchTimer->>SharedDict: 11. 读取所有累积的 diff
    SharedDict-->>BatchTimer: 12. 返回 diff 数据
    BatchTimer->>RedisCluster: 13. Pipeline INCRBY<br/>(批量刷新所有差值)

    Note over RedisCluster: 自动按 slot 分组并行执行

    RedisCluster-->>BatchTimer: 14. 完成
    BatchTimer->>SharedDict: 15. 清零已刷新的 diff
```

## 关键时间点（Redis Cluster 版本）

| 阶段 | 操作 | 耗时 | 说明 |
|---|---|---|---|
| access | 预估 Token | < 1ms | 本地计算 |
| access | Pipeline INCRBY (9 key) | 1-3ms | 自动按 slot 分组并行发送<br/>（耗时 = 最慢节点的 RTT） |
| access | 超限回退 | 1-3ms | 仅超限时触发，同样并行 |
| access | 转发上游 | 100-5000ms | 取决于模型响应速度 |
| log | 提取实际 Token | < 1ms | 解析 JSON |
| log | 写 MySQL | 5-20ms | 异步，不阻塞响应 |
| log | 更新 Redis (原版) | 1-3ms | 异步，不阻塞响应 |
| log | 写 shared_dict (优化版) | < 0.1ms | 本地内存操作 |
| 批量刷新 | Pipeline 更新 Redis | 1-5ms | 每 5 秒一次 |
| 定期同步 | 聚合查询 + 更新 | 100-1000ms | 每小时一次 |

**注意：**
- 以上耗时基于单 key 读取 1ms 的网络环境
- Pipeline 并行发送到多个节点，耗时取决于最慢节点
- 如果 9 个 key 全部落在同一节点，耗时与单机版相同（1-2ms）
- 如果分布在 3 个节点，理论耗时仍为 1-2ms（并行）

## 并发场景示例（Redis Cluster）

### 场景：3 个并发请求同时到达

```mermaid
sequenceDiagram
    participant R1 as 请求1
    participant R2 as 请求2
    participant R3 as 请求3
    participant RedisCluster as Redis Cluster

    Note over R1,R3: 当前计数 9000, 限额 10000

    par 并发执行
        R1->>RedisCluster: Pipeline INCRBY (预扣 500)
        R2->>RedisCluster: Pipeline INCRBY (预扣 500)
        R3->>RedisCluster: Pipeline INCRBY (预扣 500)
    end

    Note over RedisCluster: 单个 key 的 INCRBY 是原子的<br/>但 3 个请求可能交错执行

    RedisCluster-->>R1: 成功，新值 9500
    RedisCluster-->>R2: 成功，新值 10000
    RedisCluster-->>R3: 成功，新值 10500 (超限!)

    R1->>R1: 转发上游
    R2->>R2: 转发上游
    R3->>RedisCluster: 回退预扣减
    R3->>R3: 返回 429

    Note over R1,R3: 极端情况：R3 回退前，<br/>R1/R2 已经在检查其他维度，<br/>可能看到短暂的不一致值<br/>（窗口 < 1ms，定期同步会校准）
```

## 数据一致性保障（Redis Cluster 版本）

```mermaid
graph TD
    A[请求到达] --> B[Redis Pipeline INCRBY 预扣减]
    B --> C{上游成功?}

    C -->|成功| D[提取实际 Token]
    C -->|失败| E[Pipeline INCRBY 回退]

    D --> F[计算差值 diff]
    F --> G{diff == 0?}

    G -->|是| H[无需调整]
    G -->|否| I[异步 Pipeline INCRBY 调整]

    I --> J[写入日志表]
    E --> J
    H --> J

    J --> K[定期同步任务]
    K --> L{Redis vs 日志表}

    L -->|一致| M[无操作]
    L -->|不一致| N[以日志表为准<br/>SET 覆盖 Redis]

    style N fill:#f96,stroke:#333,stroke-width:2px
    style K fill:#9cf,stroke:#333,stroke-width:2px
    style B fill:#ffa,stroke:#333,stroke-width:2px

    Note1[注: Pipeline 会自动按 slot 分组]
    Note2[注: 回退有微小不一致窗口<br/>但定期同步会校准]
```

## Redis Cluster vs 单机 Redis 对比

| 维度 | 单机 Redis | Redis Cluster |
|---|---|---|
| 限流实现 | Lua 脚本原子操作 | Pipeline INCRBY + 回退 |
| 原子性 | 完全原子 | 单 key 原子，回退有微小窗口 |
| 网络往返 | 1 次 EVAL | N 次并行 Pipeline（N=涉及的节点数） |
| 超限精度 | 精确 | 最多超出一个请求的 estimated_tokens |
| 可用性 | 需配合 Sentinel | 内置主从切换 |
| 扩展性 | 单节点瓶颈 | 水平扩展 |
| 适用场景 | 测试环境、小规模 | 生产环境、大规模 |

## 关键差异说明

### 1. 不使用 Lua 脚本

**原因：** 9 个 key 分布在不同 slot，Redis Cluster 不支持跨 slot 的 Lua 脚本

**替代方案：** Pipeline INCRBY + 检查返回值 + 超限回退

### 2. 自动 slot 分组

`resty-redis-cluster` 会自动：
- 计算每个 key 的 slot（CRC16 哈希）
- 按 slot 分组命令
- 并行发送到对应节点
- 合并结果按原始顺序返回

### 3. 微小不一致窗口

**场景：** 请求 A 的 key1-8 已扣减，key9 超限需要回退

**窗口：** 回退期间（< 1ms），其他请求可能读到 key1-8 的偏大值

**影响：** 可能导致短暂误拦截，但定期同步会校准

### 4. 性能优化

- **连接池：** `keepalive_cons = worker数 × 节点数 × 2`
- **超时控制：** `connection_timeout = 1000ms`
- **批量操作：** 尽量使用 pipeline 减少网络往返

