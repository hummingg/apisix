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

local ngx = ngx
local ngx_shared = ngx.shared
local ngx_time = ngx.time
local setmetatable = setmetatable
local core = require("apisix.core")

local _M = {}
local mt = { __index = _M }

function _M.new(dict_name, limit)
    local dict = ngx_shared[dict_name]
    if not dict then
        return nil, "shared dict " .. dict_name .. " not found"
    end

    local self = {
        dict = dict,
        limit = limit,
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
    local dict = self.dict
    local limit = self.limit

    if commit then
        -- 实际扣费
        -- incr(key, delta, init_val, init_ttl)
        -- 如果 key 不存在，初始化为 limit，然后减去 cost
        local remaining, err = dict:incr(key, -cost, limit, ttl)
        if not remaining then
            return nil, "dict incr failed: " .. (err or "unknown")
        end

        -- 记录绝对截止时间戳（用于查询重置时间）
        if remaining == limit - cost then
            local end_time_key = key .. ":end"
            local abs_end = ngx_time() + ttl
            dict:set(end_time_key, abs_end, ttl)
        end

        -- 即使超限也不拒绝（因为响应已发送），只记录日志
        if remaining < 0 then
            core.log.warn("token limit exceeded for key: ", key,
                         ", remaining: ", remaining)
        end

        return 0, remaining
    else
        -- 只查询，不扣费
        local current = dict:get(key)
        if not current then
            return 0, limit  -- 键不存在，返回完整配额
        end
        return 0, current
    end
end

-- 查询重置时间
-- @param key 限流 key
-- @return reset 到重置的秒数
function _M.get_reset_time(self, key)
    local dict = self.dict
    local end_time_key = key .. ":end"
    local abs_end = dict:get(end_time_key) or 0
    local reset = abs_end - ngx_time()
    if reset < 0 then
        reset = 0
    end
    return reset
end

return _M
