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

local redis_new = require("apisix.utils.redis").new
local core = require("apisix.core")
local setmetatable = setmetatable

local _M = {}
local mt = { __index = _M }

-- Redis Lua 脚本：原子扣费
local INCR_SCRIPT = [[
    local key = KEYS[1]
    local cost = tonumber(ARGV[1])
    local limit = tonumber(ARGV[2])
    local ttl = tonumber(ARGV[3])

    local current = redis.call('get', key)
    if not current then
        -- 键不存在，初始化
        redis.call('set', key, limit - cost, 'EX', ttl)
        return limit - cost
    else
        -- 键存在，扣费
        local remaining = tonumber(current) - cost
        redis.call('decrby', key, cost)
        return remaining
    end
]]

-- Redis Lua 脚本：查询配额
local QUERY_SCRIPT = [[
    local key = KEYS[1]
    local limit = tonumber(ARGV[1])
    local current = redis.call('get', key)
    local ttl = redis.call('ttl', key)
    if not current then
        return {limit, 0}
    end
    return {tonumber(current), ttl}
]]

function _M.new(_dict_name, limit, redis_conf)
    local self = {
        limit = limit,
        redis_conf = redis_conf,
    }
    return setmetatable(self, mt)
end

-- 扣费或查询配额
-- @param key 限流 key
-- @param cost 消耗的 token 数量
-- @param ttl 过期时间（秒）
-- @param commit true 表示实际扣费，false 表示只查询
-- @return delay 延迟时间（0 表示未超限）
-- @return remaining 剩余配额
function _M.incoming(self, key, cost, ttl, commit)
    local red, err = redis_new(self.redis_conf)
    if not red then
        return nil, "failed to connect redis: " .. (err or "unknown")
    end

    if commit then
        -- 实际扣费
        local remaining, eval_err = red:eval(INCR_SCRIPT, 1, key, cost, self.limit, ttl)
        if not remaining then
            return nil, "redis eval failed: " .. (eval_err or "unknown")
        end

        -- 即使超限也不拒绝，只记录日志
        if remaining < 0 then
            core.log.warn("token limit exceeded for key: ", key,
                         ", remaining: ", remaining)
        end

        return 0, remaining
    else
        -- 只查询
        local res, query_err = red:eval(QUERY_SCRIPT, 1, key, self.limit)
        if not res then
            return nil, "redis eval failed: " .. (query_err or "unknown")
        end
        return 0, res[1]
    end
end

-- 查询重置时间
-- @param key 限流 key
-- @return reset 到重置的秒数
function _M.get_reset_time(self, key)
    local red = redis_new(self.redis_conf)
    if not red then
        return 0
    end
    local ttl = red:ttl(key)
    if not ttl or ttl < 0 then
        return 0
    end
    return ttl
end

return _M
