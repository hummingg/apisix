# AI Token Limit 插件

## 功能说明

`ai-token-limit` 插件用于对 AI 服务的 Token 使用量进行限流控制。支持多维度、多时间窗口的灵活限流策略。

## 核心特性

1. **多维度限流**：支持按 Consumer、IP、自定义 Header 或组合维度限流
2. **多时间窗口**：支持自然日/月/年或自定义秒数
3. **多 Token 类型**：支持 `total_tokens`、`prompt_tokens`、`completion_tokens`
4. **多存储策略**：支持 `local`、`redis`、`redis-cluster`
5. **配额查询 API**：提供 Control API 查询当前配额使用情况

## 配置示例

### 基础配置（按 Consumer 限流）

```json
{
  "plugins": {
    "ai-token-limit": {
      "rules": [
        {
          "token_type": "total_tokens",
          "period": "day",
          "limit": 10000,
          "key": "consumer_name",
          "key_type": "var"
        }
      ],
      "policy": "local"
    }
  }
}
```

### 多维度组合限流

```json
{
  "plugins": {
    "ai-token-limit": {
      "rules": [
        {
          "token_type": "total_tokens",
          "period": "day",
          "limit": 10000,
          "key": "$consumer_name-$remote_addr",
          "key_type": "var_combination"
        }
      ],
      "policy": "local"
    }
  }
}
```

### 全局限流

```json
{
  "plugins": {
    "ai-token-limit": {
      "rules": [
        {
          "token_type": "total_tokens",
          "period": "month",
          "limit": 1000000,
          "key": "global",
          "key_type": "constant"
        }
      ],
      "policy": "redis",
      "redis_host": "127.0.0.1",
      "redis_port": 6379,
      "redis_database": 0
    }
  }
}
```

### 多规则组合

```json
{
  "plugins": {
    "ai-token-limit": {
      "rules": [
        {
          "token_type": "total_tokens",
          "period": "day",
          "limit": 10000,
          "key": "consumer_name",
          "key_type": "var"
        },
        {
          "token_type": "prompt_tokens",
          "period": "month",
          "limit": 50000,
          "key": "consumer_name",
          "key_type": "var"
        }
      ],
      "policy": "local"
    }
  }
}
```

## 配置参数

### 插件级别参数

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| rules | array | 是 | - | 限流规则数组 |
| policy | string | 否 | local | 存储策略：local/redis/redis-cluster |
| allow_degradation | boolean | 否 | false | Redis 失败时是否降级放行 |

### 规则参数（rules）

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| token_type | string | 是 | - | Token 类型：total_tokens/prompt_tokens/completion_tokens |
| period | string/integer | 是 | - | 时间窗口：day/month/year 或秒数 |
| limit | integer/string | 是 | - | 限额（支持变量如 "$http_x_daily_quota"） |
| key | string | 否 | consumer_name | 限流维度 key |
| key_type | string | 否 | var | Key 类型：var/var_combination/constant |

### key_type 说明

- **var**：单个变量，如 `consumer_name`、`remote_addr`、`http_x_api_key`
- **var_combination**：变量组合模板，如 `$consumer_name-$remote_addr`
- **constant**：常量，如 `global`（用于全局限流）

## Control API

### 查询配额

```bash
GET /apisix/control/v1/ai_token_quota?route_id=<route_id>&key_value=<key_value>
```

**参数：**
- `route_id`：路由 ID
- `key_value`：限流 key 的值（如 consumer_name 的值）

**响应示例：**

```json
{
  "quotas": [
    {
      "token_type": "total_tokens",
      "period": "day",
      "limit": 10000,
      "used": 3500,
      "remaining": 6500,
      "reset_at": "2026-03-06"
    }
  ]
}
```

## 使用场景

### 场景 1：按用户限流

每个用户每天最多使用 10000 tokens：

```json
{
  "rules": [{
    "token_type": "total_tokens",
    "period": "day",
    "limit": 10000,
    "key": "consumer_name",
    "key_type": "var"
  }]
}
```

### 场景 2：按 IP 限流

每个 IP 每小时最多使用 1000 tokens：

```json
{
  "rules": [{
    "token_type": "total_tokens",
    "period": 3600,
    "limit": 1000,
    "key": "remote_addr",
    "key_type": "var"
  }]
}
```

### 场景 3：按自定义 Header 限流

根据 `X-API-Key` 限流：

```json
{
  "rules": [{
    "token_type": "total_tokens",
    "period": "day",
    "limit": 5000,
    "key": "http_x_api_key",
    "key_type": "var"
  }]
}
```

### 场景 4：动态配额

从请求头读取每日配额：

```json
{
  "rules": [{
    "token_type": "total_tokens",
    "period": "day",
    "limit": "$http_x_daily_quota",
    "key": "consumer_name",
    "key_type": "var"
  }]
}
```

## 注意事项

1. **时间窗口**：
   - 自然时间窗口（day/month/year）会在自然日/月/年边界重置
   - 自定义秒数窗口是滑动窗口

2. **存储策略**：
   - `local`：单机内存存储，重启后清空
   - `redis`：集中式存储，支持分布式部署
   - `redis-cluster`：Redis 集群模式

3. **降级策略**：
   - `allow_degradation: false`（默认）：Redis 失败时拒绝请求
   - `allow_degradation: true`：Redis 失败时放行请求

4. **配额查询**：
   - Control API 仅用于查询，不影响实际扣费
   - 需要提供准确的 `route_id` 和 `key_value`

## 与 ai-rate-limiting 的区别

| 特性 | ai-token-limit | ai-rate-limiting |
|------|----------------|------------------|
| 限流维度 | Token 使用量 | 请求次数 |
| 扣费时机 | Log 阶段（实际消耗） | Access 阶段（预检查） |
| 响应头 | 无（使用 Control API） | 有（X-RateLimit-*） |
| 多维度支持 | 支持（var_combination） | 有限 |
| 动态配额 | 支持（变量） | 不支持 |
