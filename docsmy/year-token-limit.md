# AI 网关 Token 限流方案设计文档

## 1. 背景与需求

### 1.1 业务背景

企业从外部采购大模型接口后，通过内部网关（基于 Apache APISIX）提供统一的 AI 服务。业务流程如下：

```
外部大模型接口 → 注册为模型服务 → 创建模型 API → 授权给应用调用
```

### 1.2 核心需求

需要在网关层实现多维度、多时间窗口的 Token 限流：

**限流维度：**

- 模型维度：限制单个模型的总消耗
- API 维度：限制单个模型 API 的总消耗
- 应用维度：限制单个应用的总消耗

**时间窗口：**

- 日限额：每日 0 点重置
- 月限额：每月 1 号重置
- 年限额：每年 1 月 1 号重置

**性能要求：**

- 限流判断时延 < 20ms
- 不影响正常请求的转发性能
- 支持高并发场景（1000+ QPS）

### 1.3 现有基础设施

- **网关：** Apache APISIX（基于 OpenResty）
- **缓存：** Redis（用于存储实时计数）
- **数据库：** MySQL（存储 Token 消耗日志）
- **日志表：** 已有 `token_usage_log` 表记录每次请求的 Token 消耗

## 2. 整体架构

### 2.1 系统架构图

```
┌─────────────┐
│   客户端     │
└──────┬──────┘
       │ 1. 请求
       ↓
┌─────────────────────────────────────┐
│         APISIX 网关                  │
│  ┌─────────────────────────────┐   │
│  │  ai-token-limit 插件         │   │
│  │  ┌─────────────────────┐    │   │
│  │  │  access 阶段         │    │   │
│  │  │  - 查询 Redis 计数   │    │   │
│  │  │  - 判断是否超限      │    │   │
│  │  │  - 预扣减 Token     │    │   │
│  │  └─────────────────────┘    │   │
│  │  ┌─────────────────────┐    │   │
│  │  │  log 阶段            │    │   │
│  │  │  - 提取实际 Token    │    │   │
│  │  │  - 写入日志表        │    │   │
│  │  │  - [方案 A] 异步更新 │    │   │
│  │  └─────────────────────┘    │   │
│  └─────────────────────────────┘   │
└──────┬──────────────────────────────┘
       │ 2. 转发
       ↓
┌─────────────┐
│  大模型服务  │
└─────────────┘

┌─────────────┐      ┌─────────────┐
│    Redis    │      │    MySQL    │
│  (实时计数)  │      │  (日志表)   │
└──────┬──────┘      └──────┬──────┘
       │                    │
       └────────┬───────────┘
                │
         ┌──────┴──────┐
         │  定期同步任务 │
         │  (1-60 分钟) │
         └─────────────┘
```

### 2.2 数据流转

**请求阶段：**

1. 请求到达 APISIX
2. 查询 Redis 获取当前 Token 消耗
3. 判断是否超限
4. 预扣减 Token（基于预估值）
5. 转发到上游大模型

**响应阶段：**

- **方案 A：** 提取实际 Token → 异步更新 Redis（调整差值）→ 写日志表
- **方案 B：** 提取实际 Token → 写日志表

**同步阶段：**

- **方案 A：** 每小时从日志表同步（校准）
- **方案 B：** 每 1-5 分钟从日志表同步（更新）

## 3. 方案 A：响应后异步更新 Redis

### 3.1 方案概述

在请求响应后，立即异步更新 Redis 中的实际 Token 消耗，同时写入日志表。定期从日志表同步作为兜底校准。

### 3.2 工作流程

```
┌─────────┐
│ 1. 请求 │
└────┬────┘
     │
     ↓
┌─────────────────────┐
│ 2. 查询 Redis 计数   │
│    (9 个维度并行)    │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 3. 判断是否超限      │
│    超限 → 返回 429   │
└────┬────────────────┘
     │ 未超限
     ↓
┌─────────────────────┐
│ 4. 预扣减 Token      │
│    (基于预估值)      │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 5. 转发到大模型      │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 6. 收到响应          │
└────┬────────────────┘
     │
     ├─────────────────────────┐
     │                         │
     ↓                         ↓
┌──────────────┐      ┌──────────────────┐
│ 7a. 写日志表  │      │ 7b. 异步更新 Redis│
│              │      │  (调整预估差值)   │
└──────────────┘      └──────────────────┘
     │                         │
     └─────────┬───────────────┘
               ↓
        ┌─────────────┐
        │ 8. 返回响应  │
        └─────────────┘

        (定期任务)
        ┌─────────────────┐
        │ 9. 每小时同步    │
        │    从日志表校准  │
        └─────────────────┘
```

### 3.3 核心实现

#### 3.3.1 Redis 数据结构

```
# 计数 Key（存储当前消耗）
token:model:{model_id}:day:{YYYYMMDD}     → 整数（已消耗 token 数）
token:model:{model_id}:month:{YYYYMM}     → 整数
token:model:{model_id}:year:{YYYY}        → 整数

token:api:{api_id}:day:{YYYYMMDD}
token:api:{api_id}:month:{YYYYMM}
token:api:{api_id}:year:{YYYY}

token:app:{app_id}:day:{YYYYMMDD}
token:app:{app_id}:month:{YYYYMM}
token:app:{app_id}:year:{YYYY}

# 限额 Key（存储配置的限额）
limit:model:{model_id}:day    → 整数（日限额）
limit:model:{model_id}:month  → 整数（月限额）
limit:model:{model_id}:year   → 整数（年限额）
（API 和应用同理）

# TTL 设置
day 类型：3 天
month 类型：93 天
year 类型：730 天
```

#### 3.3.2 access 阶段实现（Redis Cluster 版本 + 动态检查优化）

```lua
-- apisix/plugins/ai-token-limit.lua
local redis_cluster = require("resty.rediscluster")
local core = require("apisix.core")

local function get_redis_connection(conf)
    -- Redis Cluster 配置
    local config = {
        name = "token_limit_cluster",
        serv_list = conf.redis_nodes,  -- 节点列表，如 {{ip="127.0.0.1", port=7000}, ...}
        keepalive_timeout = 60000,
        keepalive_cons = 1000,
        connection_timeout = 1000,
        max_redirection = 5,
        auth = conf.redis_password,
    }

    local red, err = redis_cluster:new(config)
    if not red then
        return nil, err
    end

    return red
end

local function estimate_tokens(ctx, conf)
    -- 策略 1：使用请求参数中的 max_tokens
    local body = core.request.get_body()
    if body then
        local data = core.json.decode(body)
        if data and data.max_tokens then
            -- 打个折扣，用户通常用不完
            return math.ceil(data.max_tokens * 0.7)
        end
    end

    -- 策略 2：使用历史平均值（从 shared_dict 缓存）
    local cache = ngx.shared.token_cache
    local avg_key = "avg:" .. conf.model_id
    local avg_tokens = cache:get(avg_key)
    if avg_tokens then
        return avg_tokens
    end

    -- 策略 3：保守估计
    return 1500
end

-- 动态检查优化：根据外部服务推送的标志决定是否检查月/年维度
-- 优势：
-- 1. 月初/年初时不检查月/年维度，性能最优（只检查 3 个 key）
-- 2. 接近限额时自动启用检查，不会漏
-- 3. 标志由独立的 Java 服务推送，职责分离
local function check_and_deduct(conf, ctx, estimated_tokens)
    local red, err = get_redis_connection(conf)
    if not red then
        core.log.error("Redis 连接失败: ", err)
        -- 降级：允许通过
        return true
    end

    local today = os.date("%Y%m%d")
    local this_month = os.date("%Y%m")
    local this_year = os.date("%Y")
    local app_id = ctx.var.app_id or "unknown"

    -- 从 shared_dict 读取检查标志（由外部 Java 服务推送）
    local check_flags = ngx.shared.token_check_flags

    -- 日维度：始终检查
    local checks = {
        { key = "token:model:" .. conf.model_id .. ":day:" .. today,
          limit = conf.model_day_limit, ttl = 259200 },
        { key = "token:api:" .. conf.api_id .. ":day:" .. today,
          limit = conf.api_day_limit, ttl = 259200 },
        { key = "token:app:" .. app_id .. ":day:" .. today,
          limit = conf.app_day_limit, ttl = 259200 },
    }

    -- 月维度：根据标志决定是否检查
    local month_checks = {
        { key = "token:model:" .. conf.model_id .. ":month:" .. this_month,
          limit = conf.model_month_limit, ttl = 7776000,
          flag_key = "check:model:" .. conf.model_id .. ":month:" .. this_month },
        { key = "token:api:" .. conf.api_id .. ":month:" .. this_month,
          limit = conf.api_month_limit, ttl = 7776000,
          flag_key = "check:api:" .. conf.api_id .. ":month:" .. this_month },
        { key = "token:app:" .. app_id .. ":month:" .. this_month,
          limit = conf.app_month_limit, ttl = 7776000,
          flag_key = "check:app:" .. app_id .. ":month:" .. this_month },
    }

    -- 年维度：根据标志决定是否检查
    local year_checks = {
        { key = "token:model:" .. conf.model_id .. ":year:" .. this_year,
          limit = conf.model_year_limit, ttl = 63072000,
          flag_key = "check:model:" .. conf.model_id .. ":year:" .. this_year },
        { key = "token:api:" .. conf.api_id .. ":year:" .. this_year,
          limit = conf.api_year_limit, ttl = 63072000,
          flag_key = "check:api:" .. conf.api_id .. ":year:" .. this_year },
        { key = "token:app:" .. app_id .. ":year:" .. this_year,
          limit = conf.app_year_limit, ttl = 63072000,
          flag_key = "check:app:" .. app_id .. ":year:" .. this_year },
    }

    -- 根据标志添加需要检查的维度
    local unchecked_keys = {}

    for _, item in ipairs(month_checks) do
        local should_check = check_flags:get(item.flag_key)
        if should_check == 1 then
            table.insert(checks, item)
        else
            table.insert(unchecked_keys, item)
        end
    end

    for _, item in ipairs(year_checks) do
        local should_check = check_flags:get(item.flag_key)
        if should_check == 1 then
            table.insert(checks, item)
        else
            table.insert(unchecked_keys, item)
        end
    end

    -- 使用 pipeline 批量 INCRBY，resty-redis-cluster 会自动按 slot 分组
    red:init_pipeline()
    for _, item in ipairs(checks) do
        red:incrby(item.key, estimated_tokens)
        red:expire(item.key, item.ttl)
    end

    local results, err = red:commit_pipeline()
    if not results then
        core.log.error("Pipeline 失败: ", err)
        return true  -- 降级
    end

    -- 检查结果，INCRBY 返回递增后的新值
    -- results 数组格式：[incrby结果1, expire结果1, incrby结果2, expire结果2, ...]
    local deducted_keys = {}
    for i = 1, #checks do
        local new_val = results[i * 2 - 1]  -- INCRBY 的结果在奇数位
        local item = checks[i]

        if type(new_val) == "number" and item.limit > 0 and new_val > item.limit then
            -- 超限：回退所有已扣减的 key
            core.log.warn("超限: ", item.key, " 新值=", new_val, " 限额=", item.limit)

            red:init_pipeline()
            for _, d in ipairs(deducted_keys) do
                red:incrby(d.key, -estimated_tokens)
            end
            -- 也回退当前这个超限的 key
            red:incrby(item.key, -estimated_tokens)
            red:commit_pipeline()

            return false, "超出 Token 限额"
        end

        table.insert(deducted_keys, item)
    end

    -- 不需要检查的维度，异步更新计数（不检查限额）
    if #unchecked_keys > 0 then
        ngx.timer.at(0, function(premature)
            if premature then return end

            local red2 = get_redis_connection(conf)
            if not red2 then return end

            red2:init_pipeline()
            for _, item in ipairs(unchecked_keys) do
                red2:incrby(item.key, estimated_tokens)
                red2:expire(item.key, item.ttl)
            end
            red2:commit_pipeline()
        end)
    end

    return true
end

function _M.access(conf, ctx)
    local estimated_tokens = estimate_tokens(ctx, conf)
    ctx.estimated_tokens = estimated_tokens

    local ok, err = check_and_deduct(conf, ctx, estimated_tokens)
    if not ok then
        return 429, {
            error = "rate_limit_exceeded",
            message = err
        }
    end
end
```

**说明：**

1. **动态检查优化**：月/年维度是否检查由外部 Java 服务决定
2. **性能提升**：月初时只检查 3 个 key（日维度），耗时 < 1ms
3. **自动启用**：接近限额时 Java 服务推送标志，自动启用检查
4. **职责分离**：APISIX 负责限流，Java 服务负责监控和策略

-- Redis Cluster 版本：不使用 Lua 脚本，改用 INCRBY + 回退机制
-- 原因：Lua 脚本要求所有 key 在同一 slot，不使用 hash tag 时无法满足
local function check_and_deduct(conf, ctx, estimated_tokens)
    local red, err = get_redis_connection(conf)
    if not red then
        core.log.error("Redis 连接失败: ", err)
        -- 降级：允许通过
        return true
    end

    local today = os.date("%Y%m%d")
    local this_month = os.date("%Y%m")
    local this_year = os.date("%Y")
    local app_id = ctx.var.app_id or "unknown"

    -- 从本地缓存读取限额配置
    local cache = ngx.shared.token_cache
    local checks = {
        { key = "token:model:" .. conf.model_id .. ":day:" .. today,
          limit = cache:get("limit:model:" .. conf.model_id .. ":day") or 0,
          ttl = 259200 },
        { key = "token:model:" .. conf.model_id .. ":month:" .. this_month,
          limit = cache:get("limit:model:" .. conf.model_id .. ":month") or 0,
          ttl = 7776000 },
        { key = "token:model:" .. conf.model_id .. ":year:" .. this_year,
          limit = cache:get("limit:model:" .. conf.model_id .. ":year") or 0,
          ttl = 63072000 },
        { key = "token:api:" .. conf.api_id .. ":day:" .. today,
          limit = cache:get("limit:api:" .. conf.api_id .. ":day") or 0,
          ttl = 259200 },
        { key = "token:api:" .. conf.api_id .. ":month:" .. this_month,
          limit = cache:get("limit:api:" .. conf.api_id .. ":month") or 0,
          ttl = 7776000 },
        { key = "token:api:" .. conf.api_id .. ":year:" .. this_year,
          limit = cache:get("limit:api:" .. conf.api_id .. ":year") or 0,
          ttl = 63072000 },
        { key = "token:app:" .. app_id .. ":day:" .. today,
          limit = cache:get("limit:app:" .. app_id .. ":day") or 0,
          ttl = 259200 },
        { key = "token:app:" .. app_id .. ":month:" .. this_month,
          limit = cache:get("limit:app:" .. app_id .. ":month") or 0,
          ttl = 7776000 },
        { key = "token:app:" .. app_id .. ":year:" .. this_year,
          limit = cache:get("limit:app:" .. app_id .. ":year") or 0,
          ttl = 63072000 },
    }

    -- 使用 pipeline 批量 INCRBY，resty-redis-cluster 会自动按 slot 分组
    red:init_pipeline()
    for _, item in ipairs(checks) do
        red:incrby(item.key, estimated_tokens)
        red:expire(item.key, item.ttl)
    end

    local results, err = red:commit_pipeline()
    if not results then
        core.log.error("Pipeline 失败: ", err)
        return true  -- 降级
    end

    -- 检查结果，INCRBY 返回递增后的新值
    -- results 数组格式：[incrby结果1, expire结果1, incrby结果2, expire结果2, ...]
    local deducted_keys = {}
    for i = 1, 9 do
        local new_val = results[i * 2 - 1]  -- INCRBY 的结果在奇数位
        local item = checks[i]

        if type(new_val) == "number" and item.limit > 0 and new_val > item.limit then
            -- 超限：回退所有已扣减的 key
            core.log.warn("超限: ", item.key, " 新值=", new_val, " 限额=", item.limit)

            red:init_pipeline()
            for _, deducted in ipairs(deducted_keys) do
                red:incrby(deducted.key, -estimated_tokens)
            end
            -- 也回退当前这个超限的 key
            red:incrby(item.key, -estimated_tokens)
            red:commit_pipeline()

            return false, "超出 Token 限额"
        end

        table.insert(deducted_keys, item)
    end

    return true
end

function _M.access(conf, ctx)
    local estimated_tokens = estimate_tokens(ctx, conf)
    ctx.estimated_tokens = estimated_tokens

    local ok, err = check_and_deduct(conf, ctx, estimated_tokens)
    if not ok then
        return 429, {
            error = "rate_limit_exceeded",
            message = err
        }
    end
end
```

**说明：**

1. **不使用 Lua 脚本**：因为 9 个 key 分布在不同 slot，无法用 EVAL 保证原子性
2. **Pipeline 自动分组**：`resty-redis-cluster` 会按 slot 自动拆分 pipeline，并行发送到不同节点
3. **INCRBY 先扣减**：直接 INCRBY 递增，返回新值后判断是否超限
4. **超限回退**：如果某个 key 超限，回退所有已扣减的 key（包括当前超限的）
5. **微小不一致窗口**：回退操作不是原子的，但窗口极短（毫秒级），且定期同步会校准

**性能优化建议：**

- Pipeline 中 18 个命令（9 个 INCRBY + 9 个 EXPIRE）会被自动拆分到不同节点
- 如果 9 个 key 分布在 3 个节点，实际网络往返 = 3 次并行请求
- 回退操作只在超限时触发，正常情况下不影响性能

#### 3.3.3 log 阶段实现

```lua
local function rollback_estimated_tokens(conf, ctx)
    -- 上游请求失败时，回退预扣减的 Token
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then
            return
        end

        local red = get_redis_connection(conf)
        if not red then
            core.log.error("回退预扣减失败: Redis 连接失败")
            return
        end

        local estimated = ctx.estimated_tokens
        local today = os.date("%Y%m%d")
        local this_month = os.date("%Y%m")
        local this_year = os.date("%Y")
        local app_id = ctx.var.app_id or "unknown"

        -- 使用负值 incrby 回退预扣减（pipeline 自动处理跨 slot）
        red:init_pipeline()
        red:incrby("token:model:" .. conf.model_id .. ":day:" .. today, -estimated)
        red:incrby("token:model:" .. conf.model_id .. ":month:" .. this_month, -estimated)
        red:incrby("token:model:" .. conf.model_id .. ":year:" .. this_year, -estimated)

        red:incrby("token:api:" .. conf.api_id .. ":day:" .. today, -estimated)
        red:incrby("token:api:" .. conf.api_id .. ":month:" .. this_month, -estimated)
        red:incrby("token:api:" .. conf.api_id .. ":year:" .. this_year, -estimated)

        red:incrby("token:app:" .. app_id .. ":day:" .. today, -estimated)
        red:incrby("token:app:" .. app_id .. ":month:" .. this_month, -estimated)
        red:incrby("token:app:" .. app_id .. ":year:" .. this_year, -estimated)

        red:commit_pipeline()

        core.log.info("已回退预扣减 Token: ", estimated)
    end)

    if not ok then
        core.log.error("启动回退任务失败: ", err)
    end
end

local function extract_actual_tokens(ctx)
    -- 从响应体中提取实际 Token 消耗
    local body = core.response.get_body()
    if not body then
        return ctx.estimated_tokens  -- 降级使用预估值
    end

    local data = core.json.decode(body)
    if not data or not data.usage then
        return ctx.estimated_tokens
    end

    return data.usage.total_tokens or ctx.estimated_tokens
end

local function async_update_redis(conf, ctx, actual_tokens)
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then
            return
        end

        local red = get_redis_connection(conf)
        if not red then
            core.log.error("异步更新 Redis 失败: 连接失败")
            return
        end

        -- 计算差值
        local diff = actual_tokens - ctx.estimated_tokens
        if diff == 0 then
            return  -- 无需调整
        end

        local today = os.date("%Y%m%d")
        local this_month = os.date("%Y%m")
        local this_year = os.date("%Y")
        local app_id = ctx.var.app_id or "unknown"

        -- 调整计数器（pipeline 自动处理跨 slot）
        red:init_pipeline()
        red:incrby("token:model:" .. conf.model_id .. ":day:" .. today, diff)
        red:incrby("token:model:" .. conf.model_id .. ":month:" .. this_month, diff)
        red:incrby("token:model:" .. conf.model_id .. ":year:" .. this_year, diff)

        red:incrby("token:api:" .. conf.api_id .. ":day:" .. today, diff)
        red:incrby("token:api:" .. conf.api_id .. ":month:" .. this_month, diff)
        red:incrby("token:api:" .. conf.api_id .. ":year:" .. this_year, diff)

        red:incrby("token:app:" .. app_id .. ":day:" .. today, diff)
        red:incrby("token:app:" .. app_id .. ":month:" .. this_month, diff)
        red:incrby("token:app:" .. app_id .. ":year:" .. this_year, diff)

        red:commit_pipeline()

        -- 更新历史平均值（用于下次预估）
        local cache = ngx.shared.token_cache
        local avg_key = "avg:" .. conf.model_id
        local old_avg = cache:get(avg_key) or actual_tokens
        local new_avg = math.floor((old_avg * 0.9) + (actual_tokens * 0.1))  -- 指数移动平均
        cache:set(avg_key, new_avg, 3600)
    end)

    if not ok then
        core.log.error("启动异步任务失败: ", err)
    end
end

local function write_log_to_db(conf, ctx, actual_tokens)
    -- 写入日志表（这里简化，实际应该使用连接池）
    local mysql = require("resty.mysql")
    local db = mysql:new()

    db:connect({
        host = conf.db_host,
        port = conf.db_port,
        database = conf.db_name,
        user = conf.db_user,
        password = conf.db_password
    })

    local request_id = ctx.var.request_id or ngx.var.request_id
    local app_id = ctx.var.app_id or "unknown"

    -- 使用 ngx.quote_sql_str 防止 SQL 注入
    local sql = string.format([[
        INSERT INTO token_usage_log (
            request_id, model_id, api_id, app_id,
            prompt_tokens, completion_tokens, total_tokens,
            created_at, status
        ) VALUES (
            %s, %s, %s, %s,
            0, 0, %d,
            NOW(), 1
        )
    ]], ngx.quote_sql_str(request_id),
       ngx.quote_sql_str(conf.model_id),
       ngx.quote_sql_str(conf.api_id),
       ngx.quote_sql_str(app_id),
       actual_tokens)

    db:query(sql)
    db:set_keepalive(10000, 100)
end

function _M.log(conf, ctx)
    -- 检查上游响应状态，失败时回退预扣减
    local upstream_status = tonumber(ctx.var.upstream_status) or 0
    if upstream_status == 0 or upstream_status >= 500 then
        -- 上游无响应（超时）或服务端错误，回退预扣减的 Token
        rollback_estimated_tokens(conf, ctx)
        return
    end

    -- 提取实际 Token 消耗
    local actual_tokens = extract_actual_tokens(ctx)

    -- 异步更新 Redis
    async_update_redis(conf, ctx, actual_tokens)

    -- 写入日志表
    write_log_to_db(conf, ctx, actual_tokens)
end
```

#### 3.3.4 定期同步任务（由 Java 服务实现）

**说明：** 定期同步任务不应该由 OpenResty/APISIX 实现，而应该由独立的 Java 服务负责。

**原因：**
- OpenResty 应专注于请求处理，不应承担批量任务
- 避免占用 worker/timer 资源
- 避免多 worker 重复执行问题
- 便于监控、告警、失败重试

**Java 实现：**

```java
package com.example.gateway.sync;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Slf4j
@Service
public class TokenSyncService {

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Autowired
    private RedisClusterClient redisClusterClient;

    @Autowired
    private AlertService alertService;

    /**
     * 定期同步任务：每小时执行一次
     * 从 MySQL 日志表聚合统计，更新 Redis Cluster
     */
    @Scheduled(cron = "0 0 * * * ?")  // 每小时整点执行
    public void syncTokenUsageToRedis() {
        log.info("开始定期同步 Token 消耗数据");

        String today = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMMdd"));
        String thisMonth = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMM"));
        String thisYear = String.valueOf(LocalDate.now().getYear());

        try {
            // 1. 同步日维度
            int dayCount = syncDayDimension(today);

            // 2. 同步月维度
            int monthCount = syncMonthDimension(thisMonth);

            // 3. 同步年维度
            int yearCount = syncYearDimension(thisYear);

            log.info("定期同步完成，更新了 {} 条记录（日:{} 月:{} 年:{}）",
                dayCount + monthCount + yearCount, dayCount, monthCount, yearCount);

        } catch (Exception e) {
            log.error("定期同步失败", e);
            alertService.sendAlert("Token 同步任务失败: " + e.getMessage());
        }
    }

    /**
     * 同步日维度数据
     */
    private int syncDayDimension(String day) {
        String sql = """
            SELECT model_id, api_id, app_id,
                   DATE_FORMAT(created_at, '%Y%m%d') as day,
                   SUM(total_tokens) as total
            FROM token_usage_log
            WHERE created_at >= CURDATE() AND status = 1
            GROUP BY model_id, api_id, app_id, day
        """;

        List<TokenUsageAgg> results = jdbcTemplate.query(sql,
            (rs, rowNum) -> new TokenUsageAgg(
                rs.getString("model_id"),
                rs.getString("api_id"),
                rs.getString("app_id"),
                rs.getString("day"),
                rs.getLong("total")
            ));

        if (results.isEmpty()) {
            log.debug("日维度无数据需要同步");
            return 0;
        }

        // 批量更新 Redis（使用 Pipeline）
        Map<String, Long> redisData = new HashMap<>();
        for (TokenUsageAgg agg : results) {
            redisData.put("token:model:" + agg.getModelId() + ":day:" + agg.getDay(), agg.getTotal());
            redisData.put("token:api:" + agg.getApiId() + ":day:" + agg.getDay(), agg.getTotal());
            redisData.put("token:app:" + agg.getAppId() + ":day:" + agg.getDay(), agg.getTotal());
        }

        redisClusterClient.mset(redisData);
        log.info("同步日维度完成，更新了 {} 条记录", results.size());

        return results.size();
    }

    /**
     * 同步月维度数据
     */
    private int syncMonthDimension(String month) {
        String sql = """
            SELECT model_id, api_id, app_id,
                   DATE_FORMAT(created_at, '%Y%m') as month,
                   SUM(total_tokens) as total
            FROM token_usage_log
            WHERE created_at >= DATE_FORMAT(CURDATE(), '%Y-%m-01') AND status = 1
            GROUP BY model_id, api_id, app_id, month
        """;

        List<TokenUsageAgg> results = jdbcTemplate.query(sql,
            (rs, rowNum) -> new TokenUsageAgg(
                rs.getString("model_id"),
                rs.getString("api_id"),
                rs.getString("app_id"),
                rs.getString("month"),
                rs.getLong("total")
            ));

        if (results.isEmpty()) {
            log.debug("月维度无数据需要同步");
            return 0;
        }

        Map<String, Long> redisData = new HashMap<>();
        for (TokenUsageAgg agg : results) {
            redisData.put("token:model:" + agg.getModelId() + ":month:" + agg.getMonth(), agg.getTotal());
            redisData.put("token:api:" + agg.getApiId() + ":month:" + agg.getMonth(), agg.getTotal());
            redisData.put("token:app:" + agg.getAppId() + ":month:" + agg.getMonth(), agg.getTotal());
        }

        redisClusterClient.mset(redisData);
        log.info("同步月维度完成，更新了 {} 条记录", results.size());

        return results.size();
    }

    /**
     * 同步年维度数据
     */
    private int syncYearDimension(String year) {
        String sql = """
            SELECT model_id, api_id, app_id,
                   DATE_FORMAT(created_at, '%Y') as year,
                   SUM(total_tokens) as total
            FROM token_usage_log
            WHERE created_at >= DATE_FORMAT(CURDATE(), '%Y-01-01') AND status = 1
            GROUP BY model_id, api_id, app_id, year
        """;

        List<TokenUsageAgg> results = jdbcTemplate.query(sql,
            (rs, rowNum) -> new TokenUsageAgg(
                rs.getString("model_id"),
                rs.getString("api_id"),
                rs.getString("app_id"),
                rs.getString("year"),
                rs.getLong("total")
            ));

        if (results.isEmpty()) {
            log.debug("年维度无数据需要同步");
            return 0;
        }

        Map<String, Long> redisData = new HashMap<>();
        for (TokenUsageAgg agg : results) {
            redisData.put("token:model:" + agg.getModelId() + ":year:" + agg.getYear(), agg.getTotal());
            redisData.put("token:api:" + agg.getApiId() + ":year:" + agg.getYear(), agg.getTotal());
            redisData.put("token:app:" + agg.getAppId() + ":year:" + agg.getYear(), agg.getTotal());
        }

        redisClusterClient.mset(redisData);
        log.info("同步年维度完成，更新了 {} 条记录", results.size());

        return results.size();
    }
}

/**
 * Token 消耗聚合结果
 */
@Data
@AllArgsConstructor
class TokenUsageAgg {
    private String modelId;
    private String apiId;
    private String appId;
    private String period;  // day/month/year
    private Long total;
}
```

**Redis Cluster 客户端封装：**

```java
package com.example.gateway.sync;

import io.lettuce.core.cluster.RedisClusterClient;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.cluster.api.sync.RedisAdvancedClusterCommands;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.annotation.PostConstruct;
import javax.annotation.PreDestroy;
import java.util.Map;

@Component
public class RedisClusterClient {

    @Value("${redis.cluster.nodes}")
    private String clusterNodes;  // 127.0.0.1:7000,127.0.0.1:7001,127.0.0.1:7002

    @Value("${redis.cluster.password}")
    private String password;

    private RedisClusterClient client;
    private StatefulRedisClusterConnection<String, String> connection;

    @PostConstruct
    public void init() {
        client = RedisClusterClient.create("redis://" + clusterNodes);
        connection = client.connect();
    }

    @PreDestroy
    public void destroy() {
        if (connection != null) {
            connection.close();
        }
        if (client != null) {
            client.shutdown();
        }
    }

    /**
     * 批量 SET（使用 Pipeline）
     */
    public void mset(Map<String, Long> data) {
        RedisAdvancedClusterCommands<String, String> commands = connection.sync();

        // Lettuce 会自动按 slot 分组并并行执行
        for (Map.Entry<String, Long> entry : data.entrySet()) {
            commands.set(entry.getKey(), String.valueOf(entry.getValue()));
        }
    }

    /**
     * 单个 SET
     */
    public void set(String key, Long value) {
        RedisAdvancedClusterCommands<String, String> commands = connection.sync();
        commands.set(key, String.valueOf(value));
    }

    /**
     * 单个 GET
     */
    public Long get(String key) {
        RedisAdvancedClusterCommands<String, String> commands = connection.sync();
        String value = commands.get(key);
        return value != null ? Long.parseLong(value) : null;
    }
}
```

**配置文件（application.yml）：**

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/gateway?useSSL=false
    username: root
    password: password
    driver-class-name: com.mysql.cj.jdbc.Driver
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5

redis:
  cluster:
    nodes: 127.0.0.1:7000,127.0.0.1:7001,127.0.0.1:7002
    password: your_password

# 定时任务配置
spring:
  task:
    scheduling:
      pool:
        size: 5
```

**监控和告警：**

```java
@Service
public class TokenSyncMonitorService {

    @Autowired
    private RedisClusterClient redisClusterClient;

    @Autowired
    private AlertService alertService;

    private long lastSyncTime = 0;

    /**
     * 监控同步任务健康状态
     */
    @Scheduled(fixedRate = 300000)  // 每 5 分钟检查一次
    public void checkSyncHealth() {
        long now = System.currentTimeMillis();

        // 检查上次同步时间
        if (lastSyncTime > 0 && now - lastSyncTime > 7200000) {  // 2 小时未同步
            alertService.sendAlert("警告：Token 同步任务超过 2 小时未执行");
        }

        // 检查 Redis 连接
        try {
            redisClusterClient.get("health_check");
        } catch (Exception e) {
            alertService.sendAlert("严重：Redis Cluster 连接失败 - " + e.getMessage());
        }
    }

    public void recordSyncSuccess() {
        lastSyncTime = System.currentTimeMillis();
    }
}
```


### 3.4 方案 A 的优缺点

**优点：**

- **实时性好**
  - 响应后立即更新 Redis，数据延迟 < 1 秒
  - 用户看到的计数接近真实值
- **数据准确**
  - 及时修正预估偏差，累积误差接近 0
  - 不会因为预估不准导致大量误拦截
- **误拦截率低**
  - 即使预估值偏大，也会在响应后立即调整
  - 用户体验好
- **同步频率低**
  - 定期同步只是兜底校准，可以每小时甚至更低
  - 对数据库压力小
- **适应性强**
  - 适合高并发场景
  - 适合预估准确度低的场景
  - 适合限额较紧的场景

**缺点：**

- **实现复杂**
  - 需要在 log 阶段解析响应体
  - 需要提取 Token 数量（不同模型格式可能不同）
  - 需要计算差值并异步更新
  - 代码量大，逻辑复杂
- **双写逻辑**
  - 既要写日志表，又要更新 Redis
  - 容易出现数据不一致
  - 需要处理部分失败的情况
- **维护成本高**
  - 代码逻辑复杂，排查问题困难
  - 需要监控异步更新的成功率
  - 需要处理各种边界情况
- **流式响应处理困难**
  - 如果是流式响应（SSE），需要边接收边计数
  - 实现更加复杂
- **幂等性问题**
  - 需要防止重复更新（如请求重试）
  - 需要使用 request_id 去重
- **资源消耗**
  - 每个请求都要异步更新 Redis（9 个维度）
  - 高并发时对 Redis 压力较大

## 4. 方案 B：定期从日志表同步

### 4.1 方案概述

在请求响应后，只写入日志表，不更新 Redis。通过定期任务（1-5 分钟）从日志表聚合统计，更新 Redis 计数。

### 4.2 工作流程

```
┌─────────┐
│ 1. 请求 │
└────┬────┘
     │
     ↓
┌─────────────────────┐
│ 2. 查询 Redis 计数   │
│    (9 个维度并行)    │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 3. 判断是否超限      │
│    超限 → 返回 429   │
└────┬────────────────┘
     │ 未超限
     ↓
┌─────────────────────┐
│ 4. 预扣减 Token      │
│    (基于预估值)      │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 5. 转发到大模型      │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 6. 收到响应          │
└────┬────────────────┘
     │
     ↓
┌─────────────────────┐
│ 7. 写日志表          │
│    (只写日志表)      │
└─────────────────────┘
     │
     ↓
┌─────────────────────┐
│ 8. 返回响应          │
└─────────────────────┘

(定期任务 - 独立进程)
┌─────────────────────┐
│ 9. 每 1-5 分钟       │
│    从日志表聚合      │
│    更新 Redis        │
└─────────────────────┘
```

### 4.3 核心实现

#### 4.3.1 日志表结构

```sql
CREATE TABLE `token_usage_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `request_id` varchar(64) NOT NULL COMMENT '请求唯一标识',
  `model_id` varchar(64) NOT NULL COMMENT '模型 ID',
  `api_id` varchar(64) NOT NULL COMMENT '模型 API ID',
  `app_id` varchar(64) NOT NULL COMMENT '应用 ID',

  `prompt_tokens` int(11) NOT NULL DEFAULT '0' COMMENT '输入 token 数',
  `completion_tokens` int(11) NOT NULL DEFAULT '0' COMMENT '输出 token 数',
  `total_tokens` int(11) NOT NULL DEFAULT '0' COMMENT '总 token 数',

  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `status` tinyint(4) NOT NULL DEFAULT '1' COMMENT '状态：1-成功 0-失败',

  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_request_id` (`request_id`),
  KEY `idx_model_time` (`model_id`, `created_at`),
  KEY `idx_api_time` (`api_id`, `created_at`),
  KEY `idx_app_time` (`app_id`, `created_at`),
  KEY `idx_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='AI Token 消耗日志表';
```

#### 4.3.2 access 阶段实现

与方案 A 相同，不再重复。

#### 4.3.3 log 阶段实现

```lua
function _M.log(conf, ctx)
    -- 检查上游响应状态，失败时回退预扣减
    local upstream_status = tonumber(ctx.var.upstream_status) or 0
    if upstream_status == 0 or upstream_status >= 500 then
        rollback_estimated_tokens(conf, ctx)
        return
    end

    -- 提取实际 Token 消耗
    local actual_tokens = extract_actual_tokens(ctx)

    -- 只写日志表，不更新 Redis（由定期同步任务负责）
    write_log_to_db(conf, ctx, actual_tokens)
end
```

#### 4.3.4 定期同步任务

```lua
-- sync_token_from_log.lua
-- 方案 B 的核心：定期从日志表聚合统计，更新 Redis 计数
-- 同步频率建议 1-5 分钟，根据业务对实时性的要求调整

local function sync_from_db(premature)
    if premature then
        return
    end

    local mysql = require("resty.mysql")
    local redis = require("resty.redis")

    local db = mysql:new()
    local ok, err = db:connect({
        host = "127.0.0.1",
        port = 3306,
        database = "gateway",
        user = "root",
        password = "password"
    })
    if not ok then
        ngx.log(ngx.ERR, "同步任务: MySQL 连接失败: ", err)
        return
    end

    local red = redis:new()
    local ok, err = red:connect("127.0.0.1", 6379)
    if not ok then
        ngx.log(ngx.ERR, "同步任务: Redis 连接失败: ", err)
        db:set_keepalive(10000, 100)
        return
    end

    -- 分别查询日、月、年三个维度的聚合数据

    -- 1. 同步日维度（当天数据）
    local day_sql = [[
        SELECT model_id, api_id, app_id,
               DATE_FORMAT(created_at, '%Y%m%d') as day,
               SUM(total_tokens) as total
        FROM token_usage_log
        WHERE created_at >= CURDATE() AND status = 1
        GROUP BY model_id, api_id, app_id, day
    ]]
    local day_res, err = db:query(day_sql)
    if not day_res then
        ngx.log(ngx.ERR, "查询日维度失败: ", err)
        return
    end
    for _, row in ipairs(day_res) do
        red:set("token:model:" .. row.model_id .. ":day:" .. row.day, row.total)
        red:set("token:api:" .. row.api_id .. ":day:" .. row.day, row.total)
        red:set("token:app:" .. row.app_id .. ":day:" .. row.day, row.total)
    end

    -- 2. 同步月维度（当月数据）
    local month_sql = [[
        SELECT model_id, api_id, app_id,
               DATE_FORMAT(created_at, '%Y%m') as month,
               SUM(total_tokens) as total
        FROM token_usage_log
        WHERE created_at >= DATE_FORMAT(CURDATE(), '%Y-%m-01') AND status = 1
        GROUP BY model_id, api_id, app_id, month
    ]]
    local month_res, err = db:query(month_sql)
    if not month_res then
        ngx.log(ngx.ERR, "查询月维度失败: ", err)
        return
    end
    for _, row in ipairs(month_res) do
        red:set("token:model:" .. row.model_id .. ":month:" .. row.month, row.total)
        red:set("token:api:" .. row.api_id .. ":month:" .. row.month, row.total)
        red:set("token:app:" .. row.app_id .. ":month:" .. row.month, row.total)
    end

    -- 3. 同步年维度（当年数据）
    local year_sql = [[
        SELECT model_id, api_id, app_id,
               DATE_FORMAT(created_at, '%Y') as year,
               SUM(total_tokens) as total
        FROM token_usage_log
        WHERE created_at >= DATE_FORMAT(CURDATE(), '%Y-01-01') AND status = 1
        GROUP BY model_id, api_id, app_id, year
    ]]
    local year_res, err = db:query(year_sql)
    if not year_res then
        ngx.log(ngx.ERR, "查询年维度失败: ", err)
        return
    end
    for _, row in ipairs(year_res) do
        red:set("token:model:" .. row.model_id .. ":year:" .. row.year, row.total)
        red:set("token:api:" .. row.api_id .. ":year:" .. row.year, row.total)
        red:set("token:app:" .. row.app_id .. ":year:" .. row.year, row.total)
    end

    red:set_keepalive(10000, 100)
    db:set_keepalive(10000, 100)

    local total = #day_res + #month_res + #year_res
    ngx.log(ngx.INFO, "同步完成，更新了 ", total, " 条记录")
end

-- 每 3 分钟执行一次
ngx.timer.every(180, sync_from_db)
```

### 4.4 方案 B 的优缺点

**优点：**

- **实现简单**
  - log 阶段只写日志表，逻辑清晰
  - 不需要在 log 阶段解析响应体更新 Redis
  - 代码量小，维护成本低
- **数据一致性好**
  - Redis 数据统一从日志表同步，不存在双写不一致的问题
  - 日志表是唯一数据源，出问题时排查简单
- **Redis 压力小**
  - 每个请求只在 access 阶段读取 Redis
  - 写 Redis 操作集中在定期同步任务中，对 Redis 压力可控
- **流式响应天然支持**
  - 不需要在 log 阶段实时解析响应体
  - 只需要日志表中记录最终的 Token 消耗（由写入日志的模块负责）

**缺点：**

- **数据延迟**
  - Redis 中的计数存在 1-5 分钟的延迟
  - 在同步间隔内，新请求的 Token 消耗不会体现在 Redis 中
  - 可能导致超限放行（在同步前已超限但 Redis 未更新）
- **预估误差累积**
  - 由于不实时修正预估值，预估偏差会在同步间隔内累积
  - 如果预估值偏小，可能在同步前放行大量请求
  - 如果预估值偏大，可能在同步前误拦截正常请求
- **不适合紧限额场景**
  - 如果日限额较小（如 10000 token），1-5 分钟的延迟可能导致显著超限
  - 适合限额较宽松的场景
- **数据库压力**
  - 每 1-5 分钟执行聚合查询，对数据库有一定压力
  - 数据量大时聚合查询耗时增加
  - 需要合理建立索引

## 5. 方案对比与选型建议

### 5.1 对比总结

| 对比维度 | 方案 A（响应后异步更新） | 方案 B（定期日志表同步） |
|---|---|---|
| 数据延迟 | < 1 秒 | 1-5 分钟 |
| 实现复杂度 | 高 | 低 |
| 代码维护成本 | 高 | 低 |
| 数据一致性 | 可能双写不一致 | 单一数据源，一致性好 |
| Redis 压力 | 每请求写 9 个 key | 集中批量写入 |
| 数据库压力 | 低（仅兜底同步） | 中（频繁聚合查询） |
| 误拦截率 | 低 | 中（预估偏差累积） |
| 超限放行风险 | 低 | 中（同步间隔内） |
| 流式响应支持 | 需额外处理 | 天然支持 |
| 适用场景 | 紧限额、高精度要求 | 宽限额、简单运维 |

### 5.2 选型建议

推荐**方案 B（定期日志表同步）**作为首选方案，原因如下：

1. **简单可靠：** 实现逻辑简单，bug 少，排查方便
2. **架构清晰：** 日志表是唯一数据源，数据一致性有保障
3. **满足业务需求：** Token 限流通常是粗粒度管控（日/月/年），1-5 分钟的延迟在大多数场景下可以接受
4. **运维友好：** 问题定位简单，同步任务独立可监控

以下场景建议采用**方案 A**：

- 限额非常紧张（如日限额 < 10000 token）
- 业务对超限放行零容忍
- 需要向用户展示实时的 Token 消耗量

### 5.3 折中优化

无论选择哪个方案，都可以通过以下方式优化预扣减的准确性：

1. **动态预估：** 基于历史平均值（指数移动平均）预估 Token 消耗
2. **适度超扣：** 预估值乘以 1.2 的安全系数，宁可少放行也不超限
3. **缩短同步间隔：** 方案 B 可以将同步间隔缩短到 1 分钟，以减少延迟

## 6. Redis Cluster 部署说明

### 6.1 为什么需要 Redis Cluster

在生产环境中，使用 Redis Cluster 可以提供：

- **高可用性：** 主节点故障时自动切换到从节点
- **水平扩展：** 数据分片到多个节点，突破单机内存限制
- **负载均衡：** 读写请求分散到多个节点

### 6.2 方案 A 在 Redis Cluster 下的实现差异

#### 6.2.1 不使用 Lua 脚本

**原因：** Redis Cluster 要求 Lua 脚本中的所有 KEYS 必须在同一个 slot，而我们的 9 个 key（model/api/app × day/month/year）分布在不同 slot。

**解决方案：** 改用 `INCRBY` + 回退机制：

1. 使用 pipeline 批量 `INCRBY` 预扣减 9 个 key
2. 检查返回值，如果某个 key 超限，回退所有已扣减的 key
3. `resty-redis-cluster` 会自动按 slot 分组，并行发送到不同节点

#### 6.2.2 原子性权衡

- **单机 Redis：** Lua 脚本保证 9 个 key 的检查+扣减完全原子
- **Redis Cluster：** 只能保证单个 key 的 `INCRBY` 原子，回退操作有微小不一致窗口（毫秒级）

**影响评估：**

- 不一致窗口极短，且只在超限边界触发
- 定期同步任务会从日志表校准 Redis
- Token 限额通常是粗粒度的（日/月/年），偶尔超出几千 token 可接受

### 6.3 配置示例

#### 6.3.1 插件配置

```json
{
  "uri": "/v1/chat/completions",
  "plugins": {
    "ai-token-limit": {
      "model_id": "gpt-4",
      "api_id": "api_001",
      "redis_nodes": [
        {"ip": "192.168.1.10", "port": 7000},
        {"ip": "192.168.1.11", "port": 7001},
        {"ip": "192.168.1.12", "port": 7002},
        {"ip": "192.168.1.13", "port": 7003},
        {"ip": "192.168.1.14", "port": 7004},
        {"ip": "192.168.1.15", "port": 7005}
      ],
      "redis_password": "your_password",
      "model_day_limit": 1000000,
      "model_month_limit": 30000000,
      "model_year_limit": 365000000,
      "api_day_limit": 500000,
      "api_month_limit": 15000000,
      "api_year_limit": 180000000,
      "app_day_limit": 100000,
      "app_month_limit": 3000000,
      "app_year_limit": 36000000,
      "db_host": "127.0.0.1",
      "db_port": 3306,
      "db_name": "gateway",
      "db_user": "root",
      "db_password": "password"
    }
  }
}
```

#### 6.3.2 Redis Cluster 搭建

**最小配置（3 主 3 从）：**

```bash
# 创建 6 个节点配置文件
for port in 7000 7001 7002 7003 7004 7005; do
  mkdir -p /data/redis-cluster/${port}
  cat > /data/redis-cluster/${port}/redis.conf <<EOF
port ${port}
cluster-enabled yes
cluster-config-file nodes-${port}.conf
cluster-node-timeout 5000
appendonly yes
dir /data/redis-cluster/${port}
requirepass your_password
masterauth your_password
EOF
done

# 启动 6 个节点
for port in 7000 7001 7002 7003 7004 7005; do
  redis-server /data/redis-cluster/${port}/redis.conf &
done

# 创建集群（3 主 3 从）
redis-cli --cluster create \
  192.168.1.10:7000 192.168.1.11:7001 192.168.1.12:7002 \
  192.168.1.13:7003 192.168.1.14:7004 192.168.1.15:7005 \
  --cluster-replicas 1 \
  -a your_password
```

#### 6.3.3 验证集群状态

```bash
# 查看集群信息
redis-cli -c -h 192.168.1.10 -p 7000 -a your_password cluster info

# 查看节点信息
redis-cli -c -h 192.168.1.10 -p 7000 -a your_password cluster nodes

# 测试写入
redis-cli -c -h 192.168.1.10 -p 7000 -a your_password set test_key "hello"

# 查看 key 所在 slot
redis-cli -c -h 192.168.1.10 -p 7000 -a your_password cluster keyslot "token:model:gpt-4:day:20260407"
```

### 6.4 依赖安装

#### 6.4.1 安装 resty-redis-cluster

```bash
# 使用 opm 安装
opm get anjia0532/lua-resty-redis-cluster

# 或使用 luarocks
luarocks install lua-resty-redis-cluster
```

#### 6.4.2 APISIX 配置

在 `config.yaml` 中添加 Lua 模块路径：

```yaml
nginx_config:
  http:
    lua_package_path: "/usr/local/openresty/site/lualib/?.lua;/usr/local/apisix/?.lua;;$prefix/deps/share/lua/5.1/?.lua;$prefix/deps/share/lua/5.1/?/init.lua;;"
```

### 6.5 监控和运维

#### 6.5.1 关键指标

- **Cluster 健康状态：** `cluster_state:ok`
- **节点在线数量：** 应等于配置的节点数
- **Slot 分配情况：** 16384 个 slot 应全部分配
- **主从复制延迟：** `master_repl_offset - slave_repl_offset`

#### 6.5.2 常见问题

**问题 1：MOVED 错误**

```
(error) MOVED 12345 192.168.1.11:7001
```

**原因：** 客户端未启用 cluster 模式或拓扑信息过期

**解决：** 使用 `resty-redis-cluster`，它会自动处理 MOVED 重定向

**问题 2：CROSSSLOT 错误**

```
(error) CROSSSLOT Keys in request don't hash to the same slot
```

**原因：** Pipeline 或 Lua 脚本中的 key 不在同一 slot

**解决：** 本方案已通过 `resty-redis-cluster` 的自动分组解决

**问题 3：节点故障切换**

- **检测时间：** `cluster-node-timeout`（默认 5 秒）
- **切换时间：** 通常 < 10 秒
- **影响：** 切换期间该节点的请求会失败，插件会降级放行

### 6.6 性能优化建议

1. **连接池配置：** `keepalive_cons` 设置为 worker 数量 × 节点数量 × 2
2. **超时设置：** `connection_timeout` 建议 1000ms，避免慢节点拖累整体
3. **Pipeline 批量：** 尽量合并多个命令到一个 pipeline
4. **监控慢查询：** `slowlog-log-slower-than 10000`（10ms）

### 6.7 单机 Redis vs Redis Cluster 对比

| 特性 | 单机 Redis | Redis Cluster |
|---|---|---|
| 部署复杂度 | 低 | 中 |
| 原子性保证 | Lua 脚本完全原子 | 单 key 原子，跨 key 有微小窗口 |
| 性能 | 单节点瓶颈 | 水平扩展 |
| 可用性 | 需配合 Sentinel | 内置主从切换 |
| 适用场景 | 小规模、低并发 | 大规模、高并发 |
| 本方案推荐 | 测试环境 | 生产环境 |

## 7. 动态检查优化方案

### 7.1 优化背景

在实际业务中，月/年维度的限额周期较长，大部分时间（尤其是月初/年初）距离限额还很远，没有必要每个请求都检查这些维度。

**问题：**
- 原方案每个请求检查 9 个维度（3 个实体 × 3 个时间窗口）
- access 阶段耗时 1-3ms，其中大部分时间花在检查不会超限的月/年维度

**优化思路：**
- 月初/年初：只检查日维度（3 个 key）
- 接近限额：动态启用月/年维度检查
- 由独立的 Java 服务负责监控消耗进度，推送检查标志到 APISIX

### 7.2 整体架构

```
┌─────────────────────────────────────────────────────┐
│                   APISIX 网关                        │
│  ┌──────────────────────────────────────────────┐  │
│  │  ai-token-limit 插件                          │  │
│  │  - 读取 shared_dict 中的检查标志              │  │
│  │  - 根据标志决定检查哪些维度                   │  │
│  │  - 月初只检查 3 个 key（日维度）              │  │
│  │  - 接近限额时检查 6-9 个 key                  │  │
│  └──────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────┐  │
│  │  shared_dict: token_check_flags               │  │
│  │  - check:model:m1:month:202604 = 0 (不检查)   │  │
│  │  - check:model:m1:year:2026 = 1 (需要检查)    │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
                        ↑
                        │ HTTP API 推送
                        │ (每分钟更新一次)
                        │
┌─────────────────────────────────────────────────────┐
│          Java Token Monitor Service                 │
│  ┌──────────────────────────────────────────────┐  │
│  │  定时任务 (每分钟)                            │  │
│  │  1. 查询 MySQL token_usage_log 表            │  │
│  │  2. 聚合计算各维度消耗百分比                  │  │
│  │  3. 判断是否达到阈值（月 80%、年 90%）        │  │
│  │  4. 调用 APISIX Admin API 更新 shared_dict   │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
                        ↓
                   MySQL 数据库
              (token_usage_log 表)
```

### 7.3 Java Token Monitor Service 实现

#### 7.3.1 核心服务类

```java
package com.example.gateway.monitor;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@Slf4j
@Service
public class TokenMonitorService {

    @Autowired
    private TokenUsageRepository tokenUsageRepository;

    @Autowired
    private ApisixAdminClient apisixAdminClient;

    // 缓存上次推送的标志，只推送变化的部分
    private Map<String, Integer> lastFlags = new ConcurrentHashMap<>();

    @Scheduled(fixedRate = 60000) // 每分钟执行一次
    public void updateCheckFlags() {
        String currentMonth = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMM"));
        String currentYear = String.valueOf(LocalDate.now().getYear());

        log.info("开始更新检查标志，当前月份: {}, 当前年份: {}", currentMonth, currentYear);

        // 查询所有模型/API/应用的消耗情况
        List<TokenUsage> usages = tokenUsageRepository.aggregateUsage(currentMonth, currentYear);

        Map<String, Integer> newFlags = new HashMap<>();

        for (TokenUsage usage : usages) {
            // 月维度判断：消耗 >= 80% 时启用检查
            if (usage.getMonthLimit() > 0) {
                double monthPercent = (double) usage.getMonthUsage() / usage.getMonthLimit();
                String monthKey = String.format("check:%s:%s:month:%s",
                    usage.getDimension(), usage.getId(), currentMonth);
                newFlags.put(monthKey, monthPercent >= 0.8 ? 1 : 0);

                if (monthPercent >= 0.8) {
                    log.warn("{}:{} 月维度消耗达到 {:.1f}%，已启用检查",
                        usage.getDimension(), usage.getId(), monthPercent * 100);
                }
            }

            // 年维度判断：消耗 >= 90% 时启用检查
            if (usage.getYearLimit() > 0) {
                double yearPercent = (double) usage.getYearUsage() / usage.getYearLimit();
                String yearKey = String.format("check:%s:%s:year:%s",
                    usage.getDimension(), usage.getId(), currentYear);
                newFlags.put(yearKey, yearPercent >= 0.9 ? 1 : 0);

                if (yearPercent >= 0.9) {
                    log.warn("{}:{} 年维度消耗达到 {:.1f}%，已启用检查",
                        usage.getDimension(), usage.getId(), yearPercent * 100);
                }
            }
        }

        // 只推送变化的标志，减少网络传输
        Map<String, Integer> changedFlags = new HashMap<>();
        for (Map.Entry<String, Integer> entry : newFlags.entrySet()) {
            Integer oldValue = lastFlags.get(entry.getKey());
            if (!entry.getValue().equals(oldValue)) {
                changedFlags.put(entry.getKey(), entry.getValue());
            }
        }

        // 推送到 APISIX
        if (!changedFlags.isEmpty()) {
            try {
                apisixAdminClient.updateSharedDict("token_check_flags", changedFlags);
                log.info("成功推送 {} 个变化的检查标志", changedFlags.size());
            } catch (Exception e) {
                log.error("推送检查标志失败: {}", e.getMessage(), e);
            }
        } else {
            log.debug("无检查标志变化，跳过推送");
        }

        lastFlags = newFlags;
    }
}
```

#### 7.3.2 数据访问层

```java
package com.example.gateway.monitor;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface TokenUsageRepository extends JpaRepository<TokenUsageLog, Long> {

    @Query(value = """
        SELECT 'model' as dimension,
               t.model_id as id,
               COALESCE(SUM(CASE WHEN DATE_FORMAT(t.created_at, '%Y%m') = :currentMonth
                                 THEN t.total_tokens ELSE 0 END), 0) as month_usage,
               COALESCE(SUM(CASE WHEN YEAR(t.created_at) = :currentYear
                                 THEN t.total_tokens ELSE 0 END), 0) as year_usage,
               m.month_limit,
               m.year_limit
        FROM token_usage_log t
        JOIN model m ON t.model_id = m.id
        WHERE t.status = 1
        GROUP BY t.model_id, m.month_limit, m.year_limit

        UNION ALL

        SELECT 'api' as dimension,
               t.api_id as id,
               COALESCE(SUM(CASE WHEN DATE_FORMAT(t.created_at, '%Y%m') = :currentMonth
                                 THEN t.total_tokens ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN YEAR(t.created_at) = :currentYear
                                 THEN t.total_tokens ELSE 0 END), 0),
               a.month_limit,
               a.year_limit
        FROM token_usage_log t
        JOIN api a ON t.api_id = a.id
        WHERE t.status = 1
        GROUP BY t.api_id, a.month_limit, a.year_limit

        UNION ALL

        SELECT 'app' as dimension,
               t.app_id as id,
               COALESCE(SUM(CASE WHEN DATE_FORMAT(t.created_at, '%Y%m') = :currentMonth
                                 THEN t.total_tokens ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN YEAR(t.created_at) = :currentYear
                                 THEN t.total_tokens ELSE 0 END), 0),
               app.month_limit,
               app.year_limit
        FROM token_usage_log t
        JOIN application app ON t.app_id = app.id
        WHERE t.status = 1
        GROUP BY t.app_id, app.month_limit, app.year_limit
    """, nativeQuery = true)
    List<Object[]> aggregateUsageRaw(@Param("currentMonth") String currentMonth,
                                      @Param("currentYear") int currentYear);

    default List<TokenUsage> aggregateUsage(String currentMonth, String currentYear) {
        List<Object[]> raw = aggregateUsageRaw(currentMonth, Integer.parseInt(currentYear));
        return raw.stream()
            .map(row -> new TokenUsage(
                (String) row[0],  // dimension
                (String) row[1],  // id
                ((Number) row[2]).longValue(),  // month_usage
                ((Number) row[3]).longValue(),  // year_usage
                ((Number) row[4]).longValue(),  // month_limit
                ((Number) row[5]).longValue()   // year_limit
            ))
            .toList();
    }
}
```

#### 7.3.3 数据模型

```java
package com.example.gateway.monitor;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class TokenUsage {
    private String dimension;  // model, api, app
    private String id;
    private long monthUsage;
    private long yearUsage;
    private long monthLimit;
    private long yearLimit;
}
```

#### 7.3.4 APISIX Admin API 客户端

```java
package com.example.gateway.monitor;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.*;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.util.HashMap;
import java.util.Map;

@Slf4j
@Component
public class ApisixAdminClient {

    @Value("${apisix.admin.url:http://127.0.0.1:9180}")
    private String adminUrl;

    @Value("${apisix.admin.key}")
    private String adminKey;

    private final RestTemplate restTemplate = new RestTemplate();

    public void updateSharedDict(String dictName, Map<String, Integer> data) {
        String url = adminUrl + "/apisix/admin/shared_dict/" + dictName;

        HttpHeaders headers = new HttpHeaders();
        headers.set("X-API-KEY", adminKey);
        headers.setContentType(MediaType.APPLICATION_JSON);

        // 批量更新
        Map<String, Object> body = new HashMap<>();
        body.put("data", data);

        HttpEntity<Map<String, Object>> request = new HttpEntity<>(body, headers);

        try {
            ResponseEntity<String> response = restTemplate.exchange(
                url, HttpMethod.PUT, request, String.class);

            if (response.getStatusCode().is2xxSuccessful()) {
                log.info("成功更新 shared_dict: {}, 数据量: {}", dictName, data.size());
            } else {
                log.error("更新 shared_dict 失败: {}, 状态码: {}",
                    dictName, response.getStatusCode());
            }
        } catch (Exception e) {
            log.error("调用 APISIX Admin API 失败: {}", e.getMessage(), e);
            throw new RuntimeException("Failed to update shared_dict", e);
        }
    }
}
```

#### 7.3.5 配置文件

```yaml
# application.yml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/gateway?useSSL=false&serverTimezone=UTC
    username: root
    password: password
    driver-class-name: com.mysql.cj.jdbc.Driver

  jpa:
    hibernate:
      ddl-auto: none
    show-sql: false

apisix:
  admin:
    url: http://127.0.0.1:9180
    key: your_admin_key

logging:
  level:
    com.example.gateway.monitor: INFO
```

### 7.4 APISIX 端点实现

在 APISIX 中添加自定义端点接收 Java 服务的推送：

```lua
-- apisix/plugins/token-check-flags-updater.lua
local core = require("apisix.core")
local ngx = ngx

local _M = {}

function _M.api()
    return {
        {
            methods = {"PUT"},
            uri = "/apisix/admin/shared_dict/:dict_name",
            handler = function(conf, ctx)
                local dict_name = ctx.curr_req_matched.dict_name
                local body = core.request.get_body()

                if not body then
                    return 400, {message = "Request body is required"}
                end

                local data, err = core.json.decode(body)
                if not data or not data.data then
                    return 400, {message = "Invalid request body: " .. (err or "missing data field")}
                end

                local cache = ngx.shared[dict_name]
                if not cache then
                    return 404, {message = "Shared dict not found: " .. dict_name}
                end

                local count = 0
                for key, value in pairs(data.data) do
                    local success, err = cache:set(key, value, 3600)  -- TTL 1 小时
                    if success then
                        count = count + 1
                    else
                        core.log.error("Failed to set key: ", key, ", error: ", err)
                    end
                end

                return 200, {
                    message = "Updated " .. count .. " keys",
                    dict_name = dict_name,
                    total_keys = count
                }
            end
        }
    }
end

return _M
```

### 7.5 APISIX 配置

#### 7.5.1 添加 shared_dict

在 `config.yaml` 中添加：

```yaml
nginx_config:
  http:
    lua_shared_dict:
      token_cache: 10m          # 存储历史平均值等缓存
      token_check_flags: 10m    # 存储检查标志（新增）
```

#### 7.5.2 注册自定义端点

在 `config.yaml` 中启用插件：

```yaml
plugins:
  - token-check-flags-updater  # 新增
  - ai-token-limit
  # ... 其他插件
```

### 7.6 性能对比

| 场景 | 检查维度数 | Redis 操作 | 耗时 | 说明 |
|---|---|---|---|---|
| 月初（原方案） | 9 个 key | 18 个命令 (INCRBY+EXPIRE) | 1-3ms | 检查所有维度 |
| 月初（优化后） | 3 个 key | 6 个命令 | **< 1ms** | 只检查日维度 |
| 月底（优化后） | 6 个 key | 12 个命令 | 1-1.5ms | 检查日+月维度 |
| 年底（优化后） | 9 个 key | 18 个命令 | 1.5-2ms | 检查所有维度 |

**性能提升：**
- 月初（95% 的时间）：耗时减少 **50-70%**
- 月底/年底：耗时与原方案相同
- 平均性能提升：**40-60%**

### 7.7 阈值配置建议

| 维度 | 推荐阈值 | 启用时机 | 理由 |
|---|---|---|---|
| 日 | 始终检查 | - | 周期短，必须严格控制 |
| 月 | 80% | 月底前 6 天 | 留 20% 缓冲，足够应对突发流量 |
| 年 | 90% | 年底前 36 天 | 留 10% 缓冲，年度限额通常较大 |

**可根据业务调整：**
- **保守策略**：月 70%、年 80%（更早启用检查，更安全）
- **激进策略**：月 90%、年 95%（更晚启用检查，性能更好）

### 7.8 监控和告警

#### 7.8.1 关键指标

Java 服务应输出以下监控指标：

```java
@Component
public class TokenMonitorMetrics {

    @Autowired
    private MeterRegistry meterRegistry;

    public void recordCheckFlagUpdate(String dimension, String id, String period, double percent) {
        meterRegistry.gauge("token.usage.percent",
            Tags.of("dimension", dimension, "id", id, "period", period),
            percent);
    }

    public void recordFlagChange(String key, int oldValue, int newValue) {
        meterRegistry.counter("token.check.flag.changes",
            Tags.of("key", key, "from", String.valueOf(oldValue), "to", String.valueOf(newValue)))
            .increment();
    }
}
```

#### 7.8.2 告警规则

```yaml
# Prometheus 告警规则示例
groups:
  - name: token_limit_alerts
    rules:
      - alert: TokenUsageHigh
        expr: token_usage_percent{period="month"} > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Token 月消耗超过 80%"
          description: "{{ $labels.dimension }}:{{ $labels.id }} 月消耗达到 {{ $value }}%"

      - alert: TokenUsageCritical
        expr: token_usage_percent{period="month"} > 95
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Token 月消耗超过 95%"
          description: "{{ $labels.dimension }}:{{ $labels.id }} 月消耗达到 {{ $value }}%，即将超限"
```

### 7.9 故障处理

#### 7.9.1 Java 服务故障

**现象：** Java 服务宕机，无法推送检查标志

**影响：**
- shared_dict 中的标志有 TTL（1 小时）
- TTL 过期后，标志为 nil
- 插件会降级为**不检查月/年维度**（保守策略）

**恢复：**
- Java 服务恢复后，下一次定时任务会重新推送标志
- 或手动调用 API 立即推送

#### 7.9.2 APISIX Admin API 故障

**现象：** APISIX Admin API 不可用

**影响：**
- Java 服务推送失败，但不影响 APISIX 处理请求
- 使用 shared_dict 中的旧标志（TTL 内有效）

**恢复：**
- Admin API 恢复后，Java 服务会自动重试推送

### 7.10 方案优势总结

| 优势 | 说明 |
|---|---|
| **性能最优** | 月初只检查 3 个 key，耗时 < 1ms |
| **架构清晰** | 职责分离：APISIX 负责限流，Java 负责监控 |
| **易于扩展** | 可添加更复杂的策略（分时段、分地域、动态阈值） |
| **监控友好** | Java 服务可输出监控指标、告警、可视化 |
| **配置灵活** | 阈值、更新频率可在 Java 侧动态调整 |
| **故障隔离** | Java 服务故障不影响 APISIX（标志有 TTL） |
| **运维友好** | 可通过 Java 服务的管理界面查看消耗情况 |
