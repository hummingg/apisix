# APISIX AI 限流插件详解

> 版本：基于 APISIX 最新版本
> 创建日期：2026-03-30
> 作者：基于源码分析

## 📋 概述

**是的，APISIX 完全支持对调用大模型接口的用户进行限流！**

APISIX 提供了专门的 `ai-rate-limiting` 插件，专门用于对 LLM（大语言模型）服务进行**基于 Token 的速率限制**。这个插件与传统的 `limit-count`、`limit-req`、`limit-conn` 不同，它是专门为 AI 场景设计的。

### 核心特性

1. **基于 Token 的限流**：不是按请求数限流，而是按 Token 消耗量限流
2. **多种 Token 策略**：支持 `total_tokens`、`prompt_tokens`、`completion_tokens` 三种限流策略
3. **实例级限流**：可以为不同的 LLM 实例（如 OpenAI、DeepSeek）设置不同的限流配额
4. **Consumer 隔离**：支持按用户（Consumer）进行独立限流
5. **动态变量支持**：支持通过变量动态设置限流配额
6. **智能降级**：配合 `ai-proxy-multi` 实现限流后自动切换到备用实例

---

## 🏗️ 架构设计

### 插件优先级

```
ai-rate-limiting: 1030  (高于普通限流插件 limit-count: 1002)
```

优先级高于普通限流插件，确保 AI 限流逻辑优先执行。

### 工作流程

```
┌─────────────────────────────────────────────────────────────┐
│                    客户端请求                                 │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ↓
┌─────────────────────────────────────────────────────────────┐
│  1. access 阶段：预检查限流配额                               │
│     - 检查 ctx.picked_ai_instance_name                       │
│     - 调用 limit_count.rate_limit(conf, ctx, 1, true)       │
│     - 如果超限，返回 rejected_code (默认 503)                 │
└──────────────────────┬──────────────────────────────────────┘
                       │ 未超限
                       ↓
┌─────────────────────────────────────────────────────────────┐
│  2. 转发到 LLM 服务 (ai-proxy/ai-proxy-multi)                │
│     - 调用 OpenAI/DeepSeek/Anthropic 等 LLM API              │
│     - 获取响应中的 Token 使用量                               │
│     - 设置 ctx.ai_token_usage                                │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ↓
┌─────────────────────────────────────────────────────────────┐
│  3. log 阶段：扣除实际消耗的 Token                            │
│     - 从 ctx.ai_token_usage 获取实际消耗量                    │
│     - 根据 limit_strategy 选择 Token 类型                    │
│     - 调用 limit_count.rate_limit(conf, ctx, used_tokens)   │
│     - 更新限流计数器                                          │
└─────────────────────────────────────────────────────────────┘
```

### 核心机制

#### 1. 两阶段限流

**access 阶段（预检查）**
```lua
function _M.access(conf, ctx)
    local ai_instance_name = ctx.picked_ai_instance_name
    if not ai_instance_name then
        return
    end

    -- 预扣 1 个 Token，检查是否超限
    local code, msg = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    ctx.ai_rate_limiting = code and true or false
    return code, msg
end
```

**log 阶段（实际扣除）**
```lua
function _M.log(conf, ctx)
    if ctx.ai_rate_limiting then
        return  -- 如果 access 阶段已拒绝，不再扣除
    end

    -- 获取实际消耗的 Token 数量
    local used_tokens = get_token_usage(conf, ctx)

    -- 扣除实际消耗量
    limit_count.rate_limit(limit_conf, ctx, plugin_name, used_tokens)
end
```

#### 2. Token 策略选择

```lua
local function get_token_usage(conf, ctx)
    local usage = ctx.ai_token_usage
    if not usage then
        return
    end
    -- 根据配置的策略返回对应的 Token 数量
    return usage[conf.limit_strategy]
end
```

支持三种策略：
- `total_tokens`：总 Token 数（默认）= prompt_tokens + completion_tokens
- `prompt_tokens`：仅限制输入 Token
- `completion_tokens`：仅限制输出 Token

---

## ⚙️ 配置详解

### 配置参数

| 参数名 | 类型 | 必填 | 默认值 | 说明 |
|--------|------|------|--------|------|
| `limit` | integer/string | 否 | - | 全局限流配额（Token 数量） |
| `time_window` | integer/string | 否 | - | 时间窗口（秒） |
| `limit_strategy` | string | 否 | total_tokens | Token 类型：total_tokens/prompt_tokens/completion_tokens |
| `instances` | array[object] | 否 | - | 实例级限流配置 |
| `instances[].name` | string | 是 | - | LLM 实例名称 |
| `instances[].limit` | integer/string | 是 | - | 实例限流配额 |
| `instances[].time_window` | integer/string | 是 | - | 实例时间窗口 |
| `rules` | array[object] | 否 | - | 动态限流规则（类似 limit-count） |
| `rules[].count` | integer/string | 是 | - | 限流配额（支持变量） |
| `rules[].time_window` | integer/string | 是 | - | 时间窗口（支持变量） |
| `rules[].key` | string | 是 | - | 限流键（变量组合） |
| `rules[].header_prefix` | string | 否 | - | 响应头前缀 |
| `show_limit_quota_header` | boolean | 否 | true | 是否返回限流信息头 |
| `rejected_code` | integer | 否 | 503 | 超限时的 HTTP 状态码 |
| `rejected_msg` | string | 否 | - | 超限时的响应消息 |

### 配置模式

#### 模式 1：全局限流（所有实例共享配额）

```json
{
  "ai-rate-limiting": {
    "limit": 1000,
    "time_window": 60,
    "limit_strategy": "total_tokens"
  }
}
```

所有 LLM 实例共享 60 秒内 1000 个 Token 的配额。

#### 模式 2：实例级限流（每个实例独立配额）

```json
{
  "ai-rate-limiting": {
    "instances": [
      {
        "name": "openai-instance",
        "limit": 500,
        "time_window": 60
      },
      {
        "name": "deepseek-instance",
        "limit": 1000,
        "time_window": 60
      }
    ],
    "limit_strategy": "total_tokens"
  }
}
```

每个实例有独立的限流配额。

#### 模式 3：动态限流规则（支持变量）

```json
{
  "ai-rate-limiting": {
    "rules": [
      {
        "count": "$http_x_token_limit",
        "time_window": 60,
        "key": "$consumer_name",
        "header_prefix": "user"
      }
    ],
    "limit_strategy": "total_tokens"
  }
}
```

支持通过请求头或 Consumer 变量动态设置限流配额。

---

## 💡 使用场景

### 场景 1：单一 LLM 服务的 Token 限流

**需求**：限制所有用户在 30 秒内最多消耗 300 个 prompt tokens。

**配置**：

```bash
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "ai-proxy": {
        "provider": "openai",
        "auth": {
          "header": {
            "Authorization": "Bearer YOUR_OPENAI_KEY"
          }
        },
        "options": {
          "model": "gpt-4"
        }
      },
      "ai-rate-limiting": {
        "limit": 300,
        "time_window": 30,
        "limit_strategy": "prompt_tokens"
      }
    }
  }'
```

**效果**：
- 前几个请求正常返回
- 当 30 秒内累计消耗 300 个 prompt tokens 后，后续请求返回 503
- 响应头包含：
  ```
  X-AI-RateLimit-Limit: 300
  X-AI-RateLimit-Remaining: 0
  X-AI-RateLimit-Reset: 15
  ```

### 场景 2：多实例负载均衡 + 限流降级

**需求**：
- 主实例（OpenAI）：80% 流量，限制 100 tokens/30s
- 备用实例（DeepSeek）：20% 流量，无限制
- 主实例超限后，自动切换到备用实例

**配置**：

```bash
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "ai-proxy-multi": {
        "fallback_strategy": ["rate_limiting"],
        "instances": [
          {
            "name": "openai-primary",
            "provider": "openai",
            "weight": 8,
            "auth": {
              "header": {
                "Authorization": "Bearer YOUR_OPENAI_KEY"
              }
            },
            "options": {
              "model": "gpt-4"
            }
          },
          {
            "name": "deepseek-backup",
            "provider": "deepseek",
            "weight": 2,
            "auth": {
              "header": {
                "Authorization": "Bearer YOUR_DEEPSEEK_KEY"
              }
            },
            "options": {
              "model": "deepseek-chat"
            }
          }
        ]
      },
      "ai-rate-limiting": {
        "instances": [
          {
            "name": "openai-primary",
            "limit": 100,
            "time_window": 30
          }
        ],
        "limit_strategy": "total_tokens"
      }
    }
  }'
```

**效果**：
- 正常情况：80% 流量到 OpenAI，20% 到 DeepSeek
- OpenAI 超限后：100% 流量自动切换到 DeepSeek
- 30 秒后：OpenAI 配额重置，恢复正常分配

### 场景 3：按用户（Consumer）独立限流

**需求**：
- 免费用户：10 tokens/分钟
- 付费用户：1000 tokens/分钟
- 每个用户独立计数

**配置**：

```bash
# 1. 创建免费用户
curl "http://127.0.0.1:9180/apisix/admin/consumers" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "username": "free-user",
    "plugins": {
      "ai-rate-limiting": {
        "instances": [
          {
            "name": "openai-instance",
            "limit": 10,
            "time_window": 60
          }
        ],
        "limit_strategy": "total_tokens",
        "rejected_code": 429
      }
    }
  }'

# 2. 为免费用户配置 API Key
curl "http://127.0.0.1:9180/apisix/admin/consumers/free-user/credentials" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "free-user-key",
    "plugins": {
      "key-auth": {
        "key": "free-user-api-key"
      }
    }
  }'

# 3. 创建付费用户
curl "http://127.0.0.1:9180/apisix/admin/consumers" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "username": "premium-user",
    "plugins": {
      "ai-rate-limiting": {
        "instances": [
          {
            "name": "openai-instance",
            "limit": 1000,
            "time_window": 60
          }
        ],
        "limit_strategy": "total_tokens",
        "rejected_code": 429
      }
    }
  }'

# 4. 为付费用户配置 API Key
curl "http://127.0.0.1:9180/apisix/admin/consumers/premium-user/credentials" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "premium-user-key",
    "plugins": {
      "key-auth": {
        "key": "premium-user-api-key"
      }
    }
  }'

# 5. 创建路由
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "key-auth": {},
      "ai-proxy": {
        "provider": "openai",
        "auth": {
          "header": {
            "Authorization": "Bearer YOUR_OPENAI_KEY"
          }
        },
        "options": {
          "model": "gpt-4"
        }
      }
    }
  }'
```

**使用**：

```bash
# 免费用户请求（10 tokens/分钟）
curl "http://127.0.0.1:9080/v1/chat/completions" \
  -H "apikey: free-user-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'

# 付费用户请求（1000 tokens/分钟）
curl "http://127.0.0.1:9080/v1/chat/completions" \
  -H "apikey: premium-user-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

**效果**：
- 免费用户和付费用户的限流配额完全独立
- 免费用户超限返回 429，不影响付费用户
- 每个用户的计数器独立维护

### 场景 4：优先级 + 限流降级

**需求**：
- 优先使用 OpenAI（高质量，贵）
- OpenAI 超限后自动切换到 DeepSeek（便宜）

**配置**：

```bash
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "ai-proxy-multi": {
        "fallback_strategy": ["rate_limiting"],
        "instances": [
          {
            "name": "openai-instance",
            "provider": "openai",
            "priority": 1,
            "weight": 0,
            "auth": {
              "header": {
                "Authorization": "Bearer YOUR_OPENAI_KEY"
              }
            },
            "options": {
              "model": "gpt-4"
            }
          },
          {
            "name": "deepseek-instance",
            "provider": "deepseek",
            "priority": 0,
            "weight": 0,
            "auth": {
              "header": {
                "Authorization": "Bearer YOUR_DEEPSEEK_KEY"
              }
            },
            "options": {
              "model": "deepseek-chat"
            }
          }
        ]
      },
      "ai-rate-limiting": {
        "instances": [
          {
            "name": "openai-instance",
            "limit": 100,
            "time_window": 60
          }
        ],
        "limit_strategy": "total_tokens"
      }
    }
  }'
```

**效果**：
- 所有请求优先发送到 OpenAI（priority: 1）
- OpenAI 超限后，自动切换到 DeepSeek
- 60 秒后 OpenAI 配额重置，恢复优先使用

---

## 🔍 核心源码分析

### 1. 限流配置转换

```lua
local function transform_limit_conf(plugin_conf, instance_conf, instance_name)
    local limit_conf = {
        rejected_code = plugin_conf.rejected_code,
        rejected_msg = plugin_conf.rejected_msg,
        show_limit_quota_header = plugin_conf.show_limit_quota_header,

        -- 固定配置
        policy = "local",              -- 仅支持本地存储
        key_type = "constant",         -- 使用常量键
        allow_degradation = false,
        sync_interval = -1,

        -- 响应头配置
        limit_header = "X-AI-RateLimit-Limit",
        remaining_header = "X-AI-RateLimit-Remaining",
        reset_header = "X-AI-RateLimit-Reset",
    }

    -- 如果配置了 rules，使用 rules 模式
    if plugin_conf.rules and #plugin_conf.rules > 0 then
        limit_conf.rules = plugin_conf.rules
        limit_conf._meta = plugin_conf._meta
        return limit_conf
    end

    -- 否则使用实例模式
    local key = plugin_name .. "#global"
    local limit = plugin_conf.limit
    local time_window = plugin_conf.time_window
    local name = instance_name or ""

    if instance_conf then
        name = instance_conf.name
        key = instance_conf.name
        limit = instance_conf.limit
        time_window = instance_conf.time_window
    end

    limit_conf._vid = key
    limit_conf.key = key
    limit_conf._meta = plugin_conf._meta
    limit_conf.count = limit
    limit_conf.time_window = time_window

    -- 为每个实例设置独立的响应头
    limit_conf.limit_header = "X-AI-RateLimit-Limit-" .. name
    limit_conf.remaining_header = "X-AI-RateLimit-Remaining-" .. name
    limit_conf.reset_header = "X-AI-RateLimit-Reset-" .. name

    return limit_conf
end
```

**关键点**：
- `policy = "local"`：仅支持本地存储，不支持 Redis（与 limit-count 不同）
- `key_type = "constant"`：使用实例名作为限流键
- 每个实例有独立的响应头前缀

### 2. 实例状态检查（供 ai-proxy-multi 调用）

```lua
function _M.check_instance_status(conf, ctx, instance_name)
    if conf == nil then
        -- 从 ctx.plugins 中查找配置
        local plugins = ctx.plugins
        for i = 1, #plugins, 2 do
            if plugins[i]["name"] == plugin_name then
                conf = plugins[i + 1]
            end
        end
    end

    if not conf then
        return true  -- 没有配置限流，允许通过
    end

    instance_name = instance_name or ctx.picked_ai_instance_name
    if not instance_name then
        return nil, "missing instance_name"
    end

    -- 获取实例的限流配置
    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]

    if not limit_conf then
        return true  -- 该实例没有配置限流，允许通过
    end

    -- 检查是否超限（预扣 1 个 Token）
    local code, _ = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    if code then
        core.log.info("rate limit for instance: ", instance_name, " code: ", code)
        return false  -- 超限，不允许使用该实例
    end

    return true  -- 未超限，允许使用
end
```

**关键点**：
- 这个函数被 `ai-proxy-multi` 调用，用于选择可用的实例
- 返回 `false` 表示该实例已超限，应该选择其他实例
- 支持 `fallback_strategy = ["rate_limiting"]` 策略

### 3. LRU 缓存优化

```lua
local limit_conf_cache = core.lrucache.new({
    ttl = 300,    -- 5 分钟过期
    count = 512   -- 最多缓存 512 个配置
})

local function fetch_limit_conf_kvs(conf)
    local mt = {
        __index = function(t, k)
            if not conf.limit then
                return nil
            end

            -- 动态生成实例配置
            local limit_conf = transform_limit_conf(conf, nil, k)
            t[k] = limit_conf
            return limit_conf
        end
    }

    local limit_conf_kvs = setmetatable({}, mt)

    -- 预加载配置的实例
    local conf_instances = conf.instances or {}
    for _, limit_conf in ipairs(conf_instances) do
        limit_conf_kvs[limit_conf.name] = transform_limit_conf(conf, limit_conf)
    end

    return limit_conf_kvs
end
```

**关键点**：
- 使用 LRU 缓存避免重复转换配置
- 支持动态生成未配置的实例限流配置（使用全局 limit）
- 使用 metatable 实现懒加载

---

## 📊 与普通限流插件的对比

| 特性 | ai-rate-limiting | limit-count | limit-req | limit-conn |
|------|------------------|-------------|-----------|------------|
| **限流单位** | Token 数量 | 请求次数 | 请求速率 | 并发连接数 |
| **限流算法** | 固定窗口计数器 | 固定窗口计数器 | 漏桶算法 | 计数器 |
| **存储策略** | 仅 local | local/redis/redis-cluster | local/redis | local/redis |
| **实例隔离** | ✅ 支持 | ❌ 不支持 | ❌ 不支持 | ❌ 不支持 |
| **两阶段限流** | ✅ access + log | ❌ 仅 access | ❌ 仅 access | ✅ access + log |
| **动态变量** | ✅ 支持 | ✅ 支持 | ❌ 不支持 | ❌ 不支持 |
| **Consumer 隔离** | ✅ 支持 | ✅ 支持 | ✅ 支持 | ✅ 支持 |
| **降级策略** | ✅ 配合 ai-proxy-multi | ❌ 不支持 | ❌ 不支持 | ❌ 不支持 |
| **优先级** | 1030 | 1002 | 1001 | 1003 |

### 为什么 ai-rate-limiting 不支持 Redis？

从源码可以看到，`ai-rate-limiting` 固定使用 `policy = "local"`，原因：

1. **Token 计数的特殊性**：
   - access 阶段预扣 1 个 Token
   - log 阶段扣除实际消耗量
   - 需要在同一个 APISIX 节点上完成两次操作

2. **性能考虑**：
   - LLM 请求本身延迟较高（秒级）
   - 本地计数器性能足够
   - 避免 Redis 网络开销

3. **简化设计**：
   - 大多数 AI 网关场景不需要跨节点精确限流
   - 多节点部署时，每个节点独立限流即可

---

## 🎯 最佳实践

### 1. 选择合适的 Token 策略

**场景分析**：

| 场景 | 推荐策略 | 原因 |
|------|---------|------|
| 控制成本 | `total_tokens` | 直接对应 LLM 计费 |
| 防止长输入攻击 | `prompt_tokens` | 限制用户输入长度 |
| 控制响应长度 | `completion_tokens` | 限制模型输出 |
| 聊天应用 | `total_tokens` | 平衡输入输出 |
| 代码生成 | `completion_tokens` | 输出通常更长 |

### 2. 合理设置时间窗口

```
建议配置：
- 短期限流：30-60 秒（防止突发流量）
- 中期限流：5-15 分钟（控制用户使用）
- 长期限流：1 小时或 1 天（配额管理）
```

**多层限流示例**：

```json
{
  "ai-rate-limiting": {
    "rules": [
      {
        "count": 100,
        "time_window": 60,
        "key": "$consumer_name",
        "header_prefix": "minute"
      },
      {
        "count": 5000,
        "time_window": 3600,
        "key": "$consumer_name",
        "header_prefix": "hour"
      }
    ]
  }
}
```

### 3. Consumer 级别限流 vs 全局限流

**选择指南**：

| 场景 | 推荐方式 | 配置位置 |
|------|---------|---------|
| SaaS 平台（多租户） | Consumer 级别 | Consumer 配置 |
| 内部服务（单租户） | 全局限流 | Route 配置 |
| 免费 + 付费用户 | Consumer 级别 | Consumer 配置 |
| 成本控制 | 全局限流 | Route 配置 |

### 4. 配合 ai-proxy-multi 实现高可用

**推荐架构**：

```
┌─────────────────────────────────────────┐
│  主实例（OpenAI GPT-4）                  │
│  - 高质量，高成本                        │
│  - 限流：1000 tokens/分钟                │
│  - priority: 1                          │
└──────────────┬──────────────────────────┘
               │ 超限后降级
               ↓
┌─────────────────────────────────────────┐
│  备用实例（DeepSeek）                    │
│  - 中等质量，低成本                      │
│  - 限流：5000 tokens/分钟                │
│  - priority: 0                          │
└─────────────────────────────────────────┘
```

**配置**：

```json
{
  "ai-proxy-multi": {
    "fallback_strategy": ["rate_limiting"],
    "instances": [
      {
        "name": "openai-gpt4",
        "provider": "openai",
        "priority": 1,
        "options": {"model": "gpt-4"}
      },
      {
        "name": "deepseek-chat",
        "provider": "deepseek",
        "priority": 0,
        "options": {"model": "deepseek-chat"}
      }
    ]
  },
  "ai-rate-limiting": {
    "instances": [
      {"name": "openai-gpt4", "limit": 1000, "time_window": 60},
      {"name": "deepseek-chat", "limit": 5000, "time_window": 60}
    ]
  }
}
```

### 5. 监控和告警

**响应头监控**：

```bash
# 查看限流状态
curl -I "http://127.0.0.1:9080/v1/chat/completions" \
  -H "apikey: your-key"

# 响应头示例
X-AI-RateLimit-Limit-openai-instance: 1000
X-AI-RateLimit-Remaining-openai-instance: 234
X-AI-RateLimit-Reset-openai-instance: 45
```

**告警规则建议**：

```
- Remaining < 10%：预警
- Remaining = 0：告警
- 连续 5 分钟 Remaining = 0：严重告警
```

---

## ❓ 常见问题

### Q1: 为什么 access 阶段预扣 1 个 Token？

**A**: 因为在 access 阶段还没有调用 LLM，不知道实际会消耗多少 Token。预扣 1 个 Token 是为了：
1. 检查是否还有配额
2. 防止超限请求进入 LLM
3. log 阶段会扣除实际消耗量（已经包含了 access 阶段预扣的 1）

### Q2: 多节点部署时，限流是否精确？

**A**: 不精确。因为 `ai-rate-limiting` 使用本地存储，每个节点独立计数。

**示例**：
- 配置：1000 tokens/分钟
- 3 个 APISIX 节点
- 实际限流：约 3000 tokens/分钟（每个节点 1000）

**解决方案**：
- 将配置的 limit 除以节点数：`limit = 1000 / 3 = 333`
- 或者接受这个误差（大多数场景可接受）

### Q3: 如何实现按用户的精确限流？

**A**: 使用 Consumer 机制：

```bash
# 1. 创建 Consumer 并配置限流
curl "http://127.0.0.1:9180/apisix/admin/consumers" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "username": "user123",
    "plugins": {
      "ai-rate-limiting": {
        "limit": 1000,
        "time_window": 60
      }
    }
  }'

# 2. 配置认证凭据
curl "http://127.0.0.1:9180/apisix/admin/consumers/user123/credentials" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "id": "user123-key",
    "plugins": {
      "key-auth": {"key": "user123-api-key"}
    }
  }'

# 3. 路由启用认证
curl "http://127.0.0.1:9180/apisix/admin/routes" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "key-auth": {},
      "ai-proxy": {...}
    }
  }'
```

### Q4: 如何实现动态限流配额？

**A**: 使用 `rules` 配置：

```json
{
  "ai-rate-limiting": {
    "rules": [
      {
        "count": "$http_x_user_quota",
        "time_window": 60,
        "key": "$consumer_name"
      }
    ]
  }
}
```

客户端请求时携带：
```bash
curl "http://127.0.0.1:9080/v1/chat/completions" \
  -H "X-User-Quota: 500" \
  -H "apikey: user-key"
```

### Q5: 限流后如何自定义错误响应？

**A**: 使用 `rejected_code` 和 `rejected_msg`：

```json
{
  "ai-rate-limiting": {
    "limit": 1000,
    "time_window": 60,
    "rejected_code": 429,
    "rejected_msg": "{\"error\": \"Token quota exceeded. Please try again later.\"}"
  }
}
```

### Q6: 如何查看当前限流状态？

**A**: 通过响应头：

```bash
curl -I "http://127.0.0.1:9080/v1/chat/completions" \
  -H "apikey: your-key"

# 响应头
X-AI-RateLimit-Limit-openai-instance: 1000
X-AI-RateLimit-Remaining-openai-instance: 234
X-AI-RateLimit-Reset-openai-instance: 45  # 45 秒后重置
```

如果不想返回这些头，设置：
```json
{
  "show_limit_quota_header": false
}
```

---

## 📚 相关文档

- [APISIX 限流系统设计分析](./apisix-限流系统设计分析.md)
- [APISIX Consumer 机制详解](./apisix-Consumer机制详解.md)
- [ai-proxy 插件文档](https://apisix.apache.org/docs/apisix/plugins/ai-proxy/)
- [ai-proxy-multi 插件文档](https://apisix.apache.org/docs/apisix/plugins/ai-proxy-multi/)

---

## 🎉 总结

**APISIX 完全支持对调用大模型接口的用户进行限流！**

核心特性：
1. ✅ **基于 Token 的限流**：按实际消耗的 Token 数量限流，而非请求次数
2. ✅ **多种 Token 策略**：支持 total_tokens、prompt_tokens、completion_tokens
3. ✅ **实例级限流**：为不同 LLM 实例设置不同配额
4. ✅ **Consumer 隔离**：按用户独立限流，支持免费/付费用户差异化
5. ✅ **智能降级**：配合 ai-proxy-multi 实现限流后自动切换
6. ✅ **动态配额**：支持通过变量动态设置限流配额
7. ✅ **两阶段限流**：access 预检 + log 实际扣除

适用场景：
- SaaS 平台的 AI 服务
- 多租户 LLM 网关
- 成本控制和配额管理
- 防止滥用和攻击
- 高可用架构（主备切换）

---

*文档基于 APISIX 源码分析，最后更新：2026-03-30*
