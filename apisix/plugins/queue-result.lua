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
-- 队列结果查询插件 - 查询异步请求的处理结果
--

local redis_new = require("resty.redis").new
local core = require("apisix.core")

-- 连接 Redis
local function connect_redis(conf)
    local red = redis_new()
    red:set_timeout(conf.redis_timeout or 1000)

    local ok, err = red:connect(conf.redis_host, conf.redis_port or 6379)
    if not ok then
        return nil, "failed to connect: " .. err
    end

    if conf.redis_password then
        local ok, err = red:auth(conf.redis_password)
        if not ok then
            return nil, "failed to auth: " .. err
        end
    end

    if conf.redis_database and conf.redis_database > 0 then
        local ok, err = red:select(conf.redis_database)
        if not ok then
            return nil, "failed to select db: " .. err
        end
    end

    return red
end

local schema = {
    type = "object",
    properties = {
        redis_host = {type = "string"},
        redis_port = {type = "integer", default = 6379},
        redis_password = {type = "string"},
        redis_username = {type = "string"},
        redis_database = {type = "integer", default = 0},
        redis_timeout = {type = "integer", default = 1000},
        redis_ssl = {type = "boolean", default = false},
        redis_ssl_verify = {type = "boolean", default = false},
        redis_keepalive_timeout = {type = "integer", default = 60000},
        redis_keepalive_pool = {type = "integer", default = 5}
    },
    required = {"redis_host"}
}

local _M = {
    version = 0.1,
    priority = 1009,
    name = "queue-result",
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- 从 URI 中提取 request_id
    -- URI 格式: /api/task/{request_id} 或 /api/queue/result/{request_id}
    local uri = ctx.var.uri
    local request_id = uri:match("/api/task/([^/]+)") or uri:match("/api/queue/result/([^/]+)")

    if not request_id or request_id == "" then
        return 400, {error_msg = "request_id is required"}
    end

    local red, err = connect_redis(conf)
    if not red then
        core.log.error("failed to connect to redis: ", err)
        return 503, {error_msg = "service unavailable"}
    end

    local status_key = "apisix:queue:status:" .. request_id
    local result_key = "apisix:queue:result:" .. request_id

    local status, err = red:get(status_key)
    if err then
        core.log.error("failed to get status: ", err)
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
        return 500, {error_msg = "failed to query status"}
    end

    if status == ngx.null then
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
        return 404, {error_msg = "request not found or expired"}
    end

    if status == "queued" or status == "processing" then
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
        return 200, {
            request_id = request_id,
            status = status,
            message = "request is still being processed"
        }
    end

    if status == "completed" or status == "failed" then
        local result, err = red:get(result_key)
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)

        if err or result == ngx.null then
            return 500, {error_msg = "failed to get result"}
        end

        local result_data, err = core.json.decode(result)
        if not result_data then
            return 500, {error_msg = "invalid result data"}
        end

        return 200, result_data
    end

    red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
    return 200, {
        request_id = request_id,
        status = status
    }
end

return _M
