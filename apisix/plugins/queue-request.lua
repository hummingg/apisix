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
-- 请求队列插件 - 将 API 请求异步化处理
-- 功能：接收请求后立即返回 request_id，请求进入 Redis 队列等待处理
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
        redis_keepalive_pool = {type = "integer", default = 5},
        queue_name = {type = "string", default = "apisix:queue:requests"},
        result_ttl = {type = "integer", default = 3600},
        max_queue_size = {type = "integer", default = 10000}
    },
    required = {"redis_host"}
}

local _M = {
    version = 0.1,
    priority = 1010,
    name = "queue-request",
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- 生成唯一的请求 ID
local function generate_request_id()
    -- 使用时间戳 + 随机数生成唯一 ID
    local timestamp = ngx.now() * 1000  -- 毫秒时间戳
    local random = math.random(10000, 99999)
    return string.format("%d%d", math.floor(timestamp), random)
end

-- 将请求入队到 Redis
function _M.access(conf, ctx)
    -- 读取请求体
    local body, err = core.request.get_body()
    if err then
        core.log.error("failed to read request body: ", err)
        return 400, {error_msg = "failed to read request body"}
    end

    -- 生成请求 ID
    local request_id = generate_request_id()

    -- 连接 Redis
    local red, err = connect_redis(conf)
    if not red then
        core.log.error("failed to connect to redis: ", err)
        return 503, {error_msg = "service temporarily unavailable"}
    end

    -- 检查队列长度（防止队列过长）
    local queue_len, err = red:llen(conf.queue_name)
    if err then
        core.log.error("failed to get queue length: ", err)
    elseif queue_len and queue_len >= conf.max_queue_size then
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
        return 429, {error_msg = "queue is full, please try again later"}
    end

    -- 构造请求数据
    local request_data = {
        id = request_id,
        method = ctx.var.request_method,
        uri = ctx.var.uri,
        query_string = ctx.var.query_string or "",
        body = body,
        headers = core.request.headers(ctx),
        client_ip = core.request.get_remote_client_ip(ctx),
        timestamp = ngx.time()
    }

    -- 将请求数据序列化为 JSON
    local json_data, err = core.json.encode(request_data)
    if not json_data then
        core.log.error("failed to encode request data: ", err)
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
        return 500, {error_msg = "internal server error"}
    end

    -- 将请求推入队列（LPUSH 从���侧推入，RPOP 从右侧取出，实现 FIFO）
    local ok, err = red:lpush(conf.queue_name, json_data)
    if not ok then
        core.log.error("failed to push request to queue: ", err)
        red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
        return 500, {error_msg = "failed to queue request"}
    end

    -- 设置请求状态为 queued
    local status_key = "apisix:queue:status:" .. request_id
    red:setex(status_key, conf.result_ttl, "queued")

    -- 归还连接到连接池
    local ok, err = red:set_keepalive(conf.redis_keepalive_timeout, conf.redis_keepalive_pool)
    if not ok then
        core.log.error("failed to set keepalive: ", err)
    end

    -- 返回 202 Accepted 和请求 ID
    core.response.set_header("Content-Type", "application/json")
    return 202, {
        request_id = tostring(request_id),
        status = "queued",
        message = "request has been queued for processing",
        poll_url = "/apisix/admin/queue/result/" .. request_id
    }
end

return _M
