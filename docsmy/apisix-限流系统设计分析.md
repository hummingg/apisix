# APISIX 限流系统设计分析

> 文档版本：1.0.0
> 创建日期：2026-03-30
> 分析对象：Apache APISIX 限流插件系统

## 概述

APISIX 提供了完善的限流系统，支持多种限流策略和动态配置能力。本文档详细分析其设计架构和实现原理。

---

## 一、限流插件类型

APISIX 提供了三种限流插件，分别针对不同的限流场景：

### 1. limit-count（固定时间窗口计数限流）
- **优先级：** 1002
- **适用场景：** 最常用的限流方式，限制固定时间窗口内的请求数量
- **算法：** 固定时间窗口计数
- **示例：** 限制每分钟最多 100 个请求

### 2. limit-req（请求速率限流）
- **优先级：** 1001
- **适用场景：** 平滑限流，控制请求速率
- **算法：** 漏桶算法（Leaky Bucket）
- **示例：** 限制每秒 10 个请求，允许突发 5 个请求

### 3. limit-conn（并发连接数限流）
- **优先级：** 1003
- **适用场景：** 限制同时处理的连接数
- **算法：** 并发连接计数
- **示例：** 限制同时最多 50 个并发连接

---

## 二、架构设计

### 2.1 分层架构

```
┌─────────────────────────────────────┐
│      Plugin Layer                   │  插件入口层
│  (limit-count.lua)                  │  - 配置验证
│                                     │  - 插件注册
└──────────────┬──────────────────────┘
               │
               ↓
┌─────────────────────────────────────┐
│      Init Layer                     │  业务逻辑层
│  (limit-count/init.lua)             │  - 规则解析
│                                     │  - 变量解析
│                                     │  - 限流执行
└──────────────┬──────────────────────┘
               │
               ↓
┌─────────────────────────────────────┐
│      Storage Layer                  │  存储策略层
│  - limit-count-local.lua            │  - 本地内存
│  - limit-count-redis.lua            │  - Redis 单机
│  - limit-count-redis-cluster.lua    │  - Redis 集群
└─────────────────────────────────────┘
```

### 2.2 多策略支持

每个限流插件都支持三种存储策略：

#### local（本地策略）
- **存储位置：** 本地共享内存（ngx.shared.dict）
- **适用场景：** 单机限流
- **优点：** 性能最高，无网络开销
- **缺点：** 无法跨节点共享计数

#### redis（Redis 单机策略）
- **存储位置：** Redis 单机实例
- **适用场景：** 分布式限流（小规模）
- **优点：** 跨节点共享计数，配置简单
- **缺点：** 单点故障风险

#### redis-cluster（Redis 集群策略）
- **存储位置：** Redis 集群
- **适用场景：** 大规模分布式限流
- **优点：** 高可用，可扩展
- **缺点：** 配置复杂，性能略低

---

## 三、动态限流支持

**APISIX 完全支持动态限流**，主要体现在以下几个方面：

### 3.1 动态配置变量

限流参数支持使用变量动态计算，而不是固定值。

#### Schema 定义
```lua
count = {
    oneOf = {
        {type = "integer", exclusiveMinimum = 0},  -- 固定值
        {type = "string"},                          -- 变量（动态）
    },
},
time_window = {
    oneOf = {
        {type = "integer", exclusiveMinimum = 0},  -- 固定值
        {type = "string"},                          -- 变量（动态）
    },
}
```

#### 变量解析机制
```lua
local function resolve_var(ctx, value)
    if type(value) == "string" then
        local err, _
        -- 从请求上下文解析变量
        value, err, _ = core.utils.resolve_var(value, ctx.var)
        if err then
            return nil, "could not resolve var for value: " .. value
        end
        -- 转换为数字
        value = tonumber(value)
        if not value then
            return nil, "resolved value is not a number"
        end
    end
    return value
end
```

#### 应用示例

**重要说明：** 动态变量限流的值来源有多种方式，不是让客户端直接设置（不安全）。

**方式 1：使用 Consumer 变量（最推荐）**

APISIX 的认证插件（如 key-auth、jwt-auth）会自动将 consumer 信息设置到 `ctx` 上下文中，限流插件可以直接使用 `$consumer_name` 变量：

```json
{
  "count": 1000,
  "time_window": 60,
  "key": "$consumer_name",
  "key_type": "var"
}
```

不同 Consumer 自动使用不同的限流 key，无需额外配置。

**方式 2：使用多规则配置（推荐）**

根据不同的用户属性配置不同的限流规则：

```json
{
  "rules": [
    {
      "count": 1000,
      "time_window": 60,
      "key": "$consumer_name"
    }
  ],
  "policy": "redis"
}
```

**方式 3：通过上游服务返回的响应头（特殊场景）**

某些场景下，可以从上游服务的响应头中获取限流配置，用于下次请求：

```lua
-- 在 header_filter 阶段读取上游返回的限流配置
local rate_limit = ngx.header["X-Rate-Limit-Config"]
if rate_limit then
    -- 存储到共享内存或 Redis，供下次请求使用
end
```

**方式 4：自定义认证插件设置 ctx 变量（高级）**

在自定义认证插件中，根据用户等级设置 ctx 变量：

```lua
-- 自定义认证插件
function _M.rewrite(conf, ctx)
    -- 认证逻辑...
    local user = authenticate(ctx)

    -- 根据用户等级设置限流值到 ctx
    if user.level == "vip" then
        ctx.var.rate_limit = "1000"
    elseif user.level == "premium" then
        ctx.var.rate_limit = "500"
    else
        ctx.var.rate_limit = "100"
    end
end
```

然后在 limit-count 中使用：
```json
{
  "count": "$rate_limit",
  "time_window": 60,
  "key": "$consumer_name"
}
```

**注意事项：**
1. **不要通过请求头传递限流配置** - 客户端可以伪造请求头
2. **Consumer 变量不会转发到后端** - `$consumer_name` 等变量只在 APISIX 内部使用
3. **认证插件设置的头会转发** - 如 `X-Consumer-Username` 会转发到后端，让后端知道用户身份
4. **内部控制头应该删除** - 如果设置了内部使用的头，应在转发前删除

### 3.2 多规则动态匹配

支持配置多个限流规则，运行时根据条件动态选择应用哪些规则。

#### Schema 定义
```lua
rules = {
    type = "array",
    items = {
        type = "object",
        properties = {
            count = {
                oneOf = {
                    {type = "integer", exclusiveMinimum = 0},
                    {type = "string"},
                },
            },
            time_window = {
                oneOf = {
                    {type = "integer", exclusiveMinimum = 0},
                    {type = "string"},
                },
            },
            key = {type = "string"},
            header_prefix = {
                type = "string",
                description = "prefix for rate limit headers"
            },
        },
        required = {"count", "time_window", "key"},
    },
}
```

#### 规则解析逻辑
```lua
local function get_rules(ctx, conf)
    if not conf.rules then
        -- 单规则模式
        return {{
            count = resolve_var(ctx, conf.count),
            time_window = resolve_var(ctx, conf.time_window),
            key = conf.key,
            key_type = conf.key_type,
        }}
    end

    -- 多规则模式：遍历所有规则
    local rules = {}
    for index, rule in ipairs(conf.rules) do
        local count = resolve_var(ctx, rule.count)
        local time_window = resolve_var(ctx, rule.time_window)
        local key = core.utils.resolve_var(rule.key, ctx.var)

        -- 只有变量解析成功的规则才会被应用
        if count and time_window and key then
            table.insert(rules, {
                count = count,
                time_window = time_window,
                key = key,
                header_prefix = rule.header_prefix or index,
            })
        end
    end
    return rules
end
```

#### 应用示例
```json
{
  "rules": [
    {
      "count": 1000,
      "time_window": 60,
      "key": "$http_x_user_type",
      "header_prefix": "VIP"
    },
    {
      "count": 100,
      "time_window": 60,
      "key": "$http_x_api_key",
      "header_prefix": "API"
    }
  ],
  "policy": "redis"
}
```

- VIP 用户：1000 次/分钟
- 普通用户：100 次/分钟
- 响应头自动区分：`X-VIP-RateLimit-*` 和 `X-API-RateLimit-*`

### 3.3 动态 Key 生成

支持三种 key 类型，实现灵活的限流维度。

#### Key 类型定义
```lua
key_type = {
    type = "string",
    enum = {"var", "var_combination", "constant"},
    default = "var",
}
```

#### Key 解析逻辑
```lua
local conf_key = rule.key
local key

if rule.key_type == "var_combination" then
    -- 变量组合：$host$uri -> example.com/api/users
    key, err, n_resolved = core.utils.resolve_var(conf_key, ctx.var)
    if n_resolved == 0 then
        key = nil
    end

elseif rule.key_type == "constant" then
    -- 常量：直接使用配置的值
    key = conf_key

else
    -- 单变量：从 ctx.var 中获取
    key = ctx.var[conf_key]
end

-- 兜底：如果 key 为空，使用客户端 IP
if key == nil then
    core.log.info("The value of the configured key is empty, use client IP instead")
    key = ctx.var["remote_addr"]
end
```

#### 应用示例

**按 IP 限流：**
```json
{
  "key": "remote_addr",
  "key_type": "var"
}
```

**按用户 ID 限流：**
```json
{
  "key": "http_x_user_id",
  "key_type": "var"
}
```

**按 Host + URI 组合限流：**
```json
{
  "key": "$host$uri",
  "key_type": "var_combination"
}
```

**全局限流（所有请求共享计数器）：**
```json
{
  "key": "global",
  "key_type": "constant"
}
```

### 3.4 配置热更新

APISIX 通过 Admin API 修改配置后会立即生效，无需重启服务。

#### 配置版本控制
```lua
local function gen_limit_key(conf, ctx, key)
    local parent = conf._meta and conf._meta.parent
    if not parent or not parent.resource_key then
        core.log.error("failed to generate key invalid parent")
        return nil
    end

    -- 生成唯一 key：资源标识 + 配置版本 + 用户 key
    local new_key = parent.resource_key .. ':'
                    .. apisix_plugin.conf_version(conf)
                    .. ':' .. key

    if conf._vid then
        -- workflow 插件场景：添加 action ID
        return new_key .. ':' .. conf._vid
    end

    return new_key
end
```

#### 热更新机制
1. **配置变更：** 通过 Admin API 更新路由或插件配置
2. **版本递增：** `conf_version` 自动递增
3. **Key 变化：** 限流 key 包含版本号，自动创建新计数器
4. **旧计数器：** 自动过期，不影响新配置

#### 示例流程
```bash
# 初始配置：100 次/分钟
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/1 \
  -d '{
    "plugins": {
      "limit-count": {
        "count": 100,
        "time_window": 60
      }
    }
  }'

# 热更新：改为 200 次/分钟（立即生效）
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/1 \
  -d '{
    "plugins": {
      "limit-count": {
        "count": 200,
        "time_window": 60
      }
    }
  }'
```

---

## 四、核心工作流程

以 `limit-count` 插件为例，完整的限流流程如下：

### 4.1 流程图

```
请求到达
    ↓
access 阶段触发
    ↓
解析配置规则 (get_rules)
    ├─ 单规则模式：使用 count/time_window
    └─ 多规则模式：遍历 rules 数组
    ↓
解析动态变量 (resolve_var)
    ├─ 解析 count 变量
    └─ 解析 time_window 变量
    ↓
生成限流 key (gen_limit_key)
    ├─ 解析 key_type
    ├─ 获取用户标识
    └─ 拼接版本号
    ↓
创建限流对象 (create_limit_obj)
    ├─ local: limit_local_new
    ├─ redis: limit_redis_new
    └─ redis-cluster: limit_redis_cluster_new
    ↓
执行限流检查 (lim:incoming)
    ├─ 获取当前计数
    ├─ 判断是否超限
    └─ 更新计数器
    ↓
处理结果
    ├─ 未超限：设置响应头，放行请求
    └─ 已超限：返回 rejected_code（默认 503）
```

### 4.2 代码实现

#### 主入口函数
```lua
function _M.rate_limit(conf, ctx, name, cost, dry_run)
    core.log.info("ver: ", ctx.conf_version)

    -- 1. 获取限流规则
    local rules, err = get_rules(ctx, conf)
    if not rules or #rules == 0 then
        core.log.error("failed to get rate limit rules: ", err)
        if conf.allow_degradation then
            return  -- 降级：允许请求通过
        end
        return 500
    end

    -- 2. 遍历所有规则，执行限流检查
    for _, rule in ipairs(rules) do
        local code, msg = run_rate_limit(conf, rule, ctx, name, cost, dry_run)
        if code then
            return code, msg  -- 任一规则触发限流，立即返回
        end
    end
end
```

#### 单规则限流执行
```lua
local function run_rate_limit(conf, rule, ctx, name, cost, dry_run)
    -- 1. 创建限流对象
    local lim, err = create_limit_obj(conf, rule, name)
    if not lim then
        core.log.error("failed to fetch limit.count object: ", err)
        if conf.allow_degradation then
            return  -- 降级
        end
        return 500
    end

    -- 2. 解析限流 key
    local key = parse_key(rule, ctx)
    key = gen_limit_key(conf, ctx, key)
    core.log.info("limit key: ", key)

    -- 3. 执行限流检查
    local delay, remaining, reset
    if not conf.policy or conf.policy == "local" then
        delay, remaining, reset = lim:incoming(key, not dry_run, conf, cost)
    else
        delay, remaining, reset = lim:incoming(key, cost)
    end

    -- 4. 处理结果
    if not delay then
        local err = remaining
        if err == "rejected" then
            -- 设置限流响应头
            if conf.show_limit_quota_header then
                core.response.set_header(
                    "X-RateLimit-Limit", lim.limit,
                    "X-RateLimit-Remaining", 0,
                    "X-RateLimit-Reset", reset
                )
            end

            -- 返回拒绝响应
            if conf.rejected_msg then
                return conf.rejected_code, { error_msg = conf.rejected_msg }
            end
            return conf.rejected_code
        end

        -- 其他错误
        core.log.error("failed to limit count: ", err)
        if conf.allow_degradation then
            return
        end
        return 500, {error_msg = "failed to limit count"}
    end

    -- 5. 设置成功响应头
    if conf.show_limit_quota_header then
        core.response.set_header(
            "X-RateLimit-Limit", lim.limit,
            "X-RateLimit-Remaining", remaining,
            "X-RateLimit-Reset", reset
        )
    end
end
```

---

## 五、配置示例

### 5.1 基础限流配置

#### 按 IP 限流
```json
{
  "plugins": {
    "limit-count": {
      "count": 100,
      "time_window": 60,
      "key": "remote_addr",
      "policy": "local",
      "rejected_code": 429,
      "rejected_msg": "请求过于频繁，请稍后再试"
    }
  }
}
```

#### 按用户 ID 限流
```json
{
  "plugins": {
    "limit-count": {
      "count": 1000,
      "time_window": 3600,
      "key": "http_x_user_id",
      "key_type": "var",
      "policy": "redis",
      "redis_host": "127.0.0.1",
      "redis_port": 6379,
      "redis_database": 0
    }
  }
}
```

### 5.2 动态限流配置

#### 根据请求头动态限流
```json
{
  "plugins": {
    "limit-count": {
      "count": "$http_x_rate_limit",
      "time_window": 60,
      "key": "remote_addr",
      "policy": "local"
    }
  }
}
```

请求示例：
```bash
# VIP 用户：1000 次/分钟
curl -H "X-Rate-Limit: 1000" http://example.com/api

# 普通用户：100 次/分钟
curl -H "X-Rate-Limit: 100" http://example.com/api
```

#### 多规则动态限流
```json
{
  "plugins": {
    "limit-count": {
      "rules": [
        {
          "count": 1000,
          "time_window": 60,
          "key": "$http_x_user_type",
          "header_prefix": "User"
        },
        {
          "count": 100,
          "time_window": 60,
          "key": "$http_x_api_key",
          "header_prefix": "API"
        }
      ],
      "policy": "redis",
      "redis_host": "127.0.0.1"
    }
  }
}
```

响应头示例：
```
X-User-RateLimit-Limit: 1000
X-User-RateLimit-Remaining: 999
X-User-RateLimit-Reset: 1711785600
X-API-RateLimit-Limit: 100
X-API-RateLimit-Remaining: 99
X-API-RateLimit-Reset: 1711785600
```

### 5.3 分布式限流配置

#### Redis 单机
```json
{
  "plugins": {
    "limit-count": {
      "count": 100,
      "time_window": 60,
      "key": "remote_addr",
      "policy": "redis",
      "redis_host": "127.0.0.1",
      "redis_port": 6379,
      "redis_password": "password",
      "redis_database": 0,
      "redis_timeout": 1000
    }
  }
}
```

#### Redis 集群
```json
{
  "plugins": {
    "limit-count": {
      "count": 100,
      "time_window": 60,
      "key": "remote_addr",
      "policy": "redis-cluster",
      "redis_cluster_nodes": [
        "127.0.0.1:7000",
        "127.0.0.1:7001",
        "127.0.0.1:7002"
      ],
      "redis_cluster_name": "redis-cluster"
    }
  }
}
```

### 5.4 高级配置

#### 降级保护
```json
{
  "plugins": {
    "limit-count": {
      "count": 100,
      "time_window": 60,
      "key": "remote_addr",
      "policy": "redis",
      "redis_host": "127.0.0.1",
      "allow_degradation": true
    }
  }
}
```

当 Redis 不可用时，自动降级为放行所有请求，避免限流组件故障影响业务。

#### 自定义响应头
```json
{
  "plugins": {
    "limit-count": {
      "count": 100,
      "time_window": 60,
      "key": "remote_addr",
      "show_limit_quota_header": true
    }
  },
  "plugin_metadata": {
    "limit-count": {
      "limit_header": "X-Custom-Limit",
      "remaining_header": "X-Custom-Remaining",
      "reset_header": "X-Custom-Reset"
    }
  }
}
```

---

## 六、优势特性

### 6.1 配置热更新
- ✅ 通过 Admin API 实时修改配置
- ✅ 无需重启服务，立即生效
- ✅ 配置版本控制，自动创建新计数器

### 6.2 多维度限流
- ✅ 支持 IP、用户 ID、API Key 等多种维度
- ✅ 支持变量组合，实现复杂限流逻辑
- ✅ 支持多规则并行，灵活应对不同场景

### 6.3 分布式支持
- ✅ Redis 单机实现跨节点限流
- ✅ Redis 集群实现大规模分布式限流
- ✅ 本地策略实现高性能单机限流

### 6.4 降级保护
- ✅ `allow_degradation` 选项防止限流组件故障影响业务
- ✅ 存储层异常时自动降级为放行
- ✅ 保障系统高可用性

### 6.5 灵活响应
- ✅ 自定义拒绝状态码（默认 503）
- ✅ 自定义拒绝消息
- ✅ 自动添加 `X-RateLimit-*` 响应头

### 6.6 Header 透出
- ✅ `X-RateLimit-Limit`: 限流阈值
- ✅ `X-RateLimit-Remaining`: 剩余配额
- ✅ `X-RateLimit-Reset`: 重置时间戳
- ✅ 支持自定义响应头名称

---

## 七、性能优化

### 7.1 LRU 缓存
```lua
local lrucache = core.lrucache.new({
    type = "plugin",
})

local lim, err = core.lrucache.plugin_ctx(lrucache, ctx, nil,
                                          create_limit_obj, conf)
```

限流对象使用 LRU 缓存，避免重复创建，提升性能。

### 7.2 Redis 连接池
```lua
local ok, err = red:set_keepalive(conf.redis_keepalive_timeout,
                                  conf.redis_keepalive_pool)
```

Redis 连接使用连接池，减少连接开销。

### 7.3 本地策略优先
对于单机场景，优先使用 `local` 策略，性能最高。

---

## 八、最佳实践

### 8.1 选择合适的存储策略

| 场景 | 推荐策略 | 原因 |
|------|---------|------|
| 单机部署 | local | 性能最高，无网络开销 |
| 小规模集群（< 10 节点） | redis | 配置简单，满足需求 |
| 大规模集群（> 10 节点） | redis-cluster | 高可用，可扩展 |
| 对性能要求极高 | local | 牺牲分布式能力换取性能 |
| 对准确性要求极高 | redis-cluster | 分布式一致性最好 |

### 8.2 合理设置限流参数

```json
{
  "count": 100,
  "time_window": 60,
  "burst": 20,
  "rejected_code": 429,
  "allow_degradation": true
}
```

- **count**: 根据业务容量设置
- **time_window**: 建议 60 秒或 3600 秒
- **burst**: limit-req 插件使用，允许突发流量
- **rejected_code**: 使用 429（Too Many Requests）
- **allow_degradation**: 生产环境建议开启

### 8.3 监控和告警

建议监控以下指标：
- 限流触发次数
- 限流拒绝率
- Redis 连接状态（分布式场景）
- 响应时间

### 8.4 降级策略

```json
{
  "allow_degradation": true
}
```

生产环境建议开启降级保护，避免限流组件故障导致服务不可用。

---

## 九、总结

APISIX 的限流系统设计非常灵活和强大：

1. **完全支持动态限流**：可以根据请求上下文、HTTP 头、变量等动态调整限流策略
2. **配置实时热更新**：通过 Admin API 修改配置立即生效，无需重启
3. **多维度限流**：支持 IP、用户、API Key 等多种维度，以及变量组合
4. **分布式支持**：Redis 集群实现跨节点限流，保证分布式一致性
5. **高可用设计**：降级保护机制，避免限流组件故障影响业务
6. **灵活可扩展**：插件化设计，易于扩展新的限流策略

适用于各种规模的生产环境，从单机到大规模分布式集群都能很好地支持。

---

## 参考资料

- [APISIX 官方文档 - limit-count](https://apisix.apache.org/docs/apisix/plugins/limit-count/)
- [APISIX 官方文档 - limit-req](https://apisix.apache.org/docs/apisix/plugins/limit-req/)
- [APISIX 官方文档 - limit-conn](https://apisix.apache.org/docs/apisix/plugins/limit-conn/)
- APISIX 源码：`apisix/plugins/limit-count/init.lua`
- APISIX 源码：`apisix/plugins/limit-req.lua`
- APISIX 源码：`apisix/plugins/limit-conn.lua`
