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
local get_routes = require("apisix.router").http_routes
local time_window = require("apisix.plugins.ai-token-limit.time-window")
local limit_token_local = require("apisix.plugins.ai-token-limit.limit-token-local")
local limit_token_redis = require("apisix.plugins.ai-token-limit.limit-token-redis")

local ngx = ngx
local ipairs = ipairs
local tonumber = tonumber
local table_concat = table.concat
local table_insert = table.insert

local _M = {}

-- 生成限流 key（与主插件保持一致）
local function gen_key(conf, route_id, token_type, period_label, key_value)
    local resource_key = route_id or "unknown"
    local conf_str = core.json.encode(conf.rules)
    local conf_version = ngx.crc32_short(conf_str)

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

-- 获取 limit 对象
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

-- GET /v1/ai_token_quota?route_id=xxx&key_value=xxx
function _M.get(query_params)
    local route_id = query_params.route_id
    local key_value = query_params.key_value

    if not route_id or not key_value then
        return 400, { error = "route_id and key_value are required" }
    end

    -- 查找路由配置
    local routes = get_routes()
    local route
    for _, r in ipairs(routes or {}) do
        if r.value and r.value.id == route_id then
            route = r
            break
        end
    end

    if not route then
        return 404, { error = "route not found" }
    end

    -- 获取插件配置
    local plugins = route.value.plugins
    if not plugins or not plugins["ai-token-limit"] then
        return 404, { error = "ai-token-limit plugin not configured" }
    end

    local conf = plugins["ai-token-limit"]
    local result = { quotas = {} }

    -- 遍历所有规则
    for _, rule in ipairs(conf.rules) do
        local token_type = rule.token_type
        local period = rule.period
        local limit = tonumber(rule.limit) or 0

        local ttl, label = time_window.calc_natural_window(period)
        if not ttl then
            return 500, { error = "failed to calculate window: " .. label }
        end

        local key = gen_key(conf, route_id, token_type, label, key_value)
        local lim, err = get_limit_obj(conf, limit)

        if not lim then
            return 500, { error = "failed to get limit obj: " .. err }
        end

        -- 查询当前使用量（cost=0 不扣费）
        local _, remaining = lim:incoming(key, 0, ttl, false)
        local used = limit - (remaining or 0)

        table.insert(result.quotas, {
            token_type = token_type,
            period = period,
            limit = limit,
            used = used,
            remaining = remaining or 0,
            reset_at = label,
        })
    end

    return 200, result
end

return _M
