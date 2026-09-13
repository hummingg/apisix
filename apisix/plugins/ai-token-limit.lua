--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local core = require("apisix.core")
local time_window = require("apisix.plugins.ai-token-limit.time-window")
local limit_token_local = require("apisix.plugins.ai-token-limit.limit-token-local")
local limit_token_redis = require("apisix.plugins.ai-token-limit.limit-token-redis")
local redis_schema = require("apisix.utils.redis-schema")

local plugin_name = "ai-token-limit"
local ngx = ngx
local ipairs = ipairs
local type = type
local tonumber = tonumber
local table_concat = table.concat
local table_insert = table.insert

local schema = {
    type = "object",
    properties = {
        rules = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    token_type = {
                        type = "string",
                        enum = {"total_tokens", "prompt_tokens", "completion_tokens"},
                    },
                    period = {
                        oneOf = {
                            { type = "string", enum = {"day", "month", "year"} },
                            { type = "integer", exclusiveMinimum = 0 },
                        },
                    },
                    limit = {
                        oneOf = {
                            { type = "integer", exclusiveMinimum = 0 },
                            { type = "string" },
                        },
                    },
                    key = {
                        type = "string",
                        default = "consumer_name"
                    },
                    key_type = {
                        type = "string",
                        enum = {"var", "var_combination", "constant"},
                        default = "var"
                    },
                },
                required = {"token_type", "period", "limit"},
            },
            minItems = 1,
        },
        allow_degradation = { type = "boolean", default = false },
        policy = {
            type = "string",
            enum = {"local", "redis", "redis-cluster"},
            default = "local",
        },
    },
    required = {"rules"},
    ["if"] = {
        properties = {
            policy = {
                enum = {"redis"},
            },
        },
    },
    ["then"] = redis_schema.schema.redis,
    ["else"] = {
        ["if"] = {
            properties = {
                policy = {
                    enum = {"redis-cluster"},
                },
            },
        },
        ["then"] = redis_schema.schema["redis-cluster"],
    }
}

local _M = {
    version = 0.1,
    priority = 1029,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- 解析变量（如 "$http_x_daily_quota"）
local function resolve_var(ctx, value)
    if type(value) == "string" and value:sub(1, 1) == "$" then
        local var_name = value:sub(2)
        return tonumber(ctx.var[var_name]) or 0
    end
    return tonumber(value) or 0
end

-- 生成限流 key
local function gen_key(conf, ctx, rule, token_type, period_label)
    local resource_key = "unknown"
    if ctx.matched_route and ctx.matched_route.value then
        resource_key = ctx.matched_route.value.id
    end

    -- 生成配置版本号（使用配置的 hash）
    local conf_str = core.json.encode(conf.rules)
    local conf_version = ngx.crc32_short(conf_str)

    -- 解析 key（支持多种类型）
    local key_value
    if rule.key_type == "var_combination" then
        local err, n_resolved
        key_value, err, n_resolved = core.utils.resolve_var(rule.key, ctx.var)
        if err then
            core.log.error("could not resolve vars: ", err)
        end
        if n_resolved == 0 then
            key_value = nil
        end
    elseif rule.key_type == "constant" then
        key_value = rule.key
    else
        key_value = ctx.var[rule.key]
    end

    -- 后备方案：使用 remote_addr
    if not key_value then
        core.log.warn("key value is empty, use remote_addr")
        key_value = ctx.var["remote_addr"]
    end

    local key_parts = {
        "ai-token-limit",
        resource_key,
        conf_version,
        token_type,
        period_label,
        key_value,
    }

    return table_concat(key_parts, ":")
end

-- 获取时间窗口信息（请求级缓存）
local function get_window_info(ctx, period)
    local cache_key = "ai_token_limit_window_" .. period
    if ctx[cache_key] then
        return ctx[cache_key].ttl, ctx[cache_key].label
    end
    local ttl, label = time_window.calc_natural_window(period)
    if not ttl then
        return nil, label  -- label 包含错误信息
    end
    ctx[cache_key] = { ttl = ttl, label = label }
    return ttl, label
end

-- 获取 limit 对象（跨请求缓存）
local limit_obj_cache = core.lrucache.new({ ttl = 300, count = 512 })

local function get_limit_obj(conf, limit)
    local cache_key = conf.policy .. ":" .. limit
    return limit_obj_cache(cache_key, nil, function()
        if conf.policy == "local" then
            return limit_token_local.new("ai-token-limit", limit)
        elseif conf.policy == "redis" or conf.policy == "redis-cluster" then
            return limit_token_redis.new("ai-token-limit", limit, conf)
        end
    end)
end

-- Log 阶段：实际扣除（唯一的扣费点）
function _M.log(conf, ctx)
    local ai_instance_name = ctx.picked_ai_instance_name
    if not ai_instance_name then
        return
    end

    local usage = ctx.ai_token_usage
    if not usage then
        return
    end

    for _, rule in ipairs(conf.rules) do
        local token_type = rule.token_type
        local cost = usage[token_type]
        if not cost or cost <= 0 then
            goto continue
        end

        local period = rule.period
        local limit = resolve_var(ctx, rule.limit)
        local ttl, label = get_window_info(ctx, period)

        if not ttl then
            core.log.error("failed to get window info: ", label)
            goto continue
        end

        local key = gen_key(conf, ctx, rule, token_type, label)
        local lim, err = get_limit_obj(conf, limit)

        if not lim then
            if conf.allow_degradation then
                core.log.warn("failed to get limit obj but allow_degradation: ", err)
            else
                core.log.error("failed to get limit obj: ", err)
            end
            goto continue
        end

        -- 实际扣除（commit=true）
        local delay, remaining = lim:incoming(key, cost, ttl, true)

        if not delay then
            if conf.allow_degradation then
                core.log.warn("token limit check failed but allow_degradation: ", remaining)
            else
                core.log.error("token limit check failed: ", remaining)
            end
        end

        ::continue::
    end
end

return _M
