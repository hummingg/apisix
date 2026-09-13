#!/usr/bin/env lua
--
-- 队列处理 Worker - 从 Redis 队列中取出请求并处理
-- 这是一个独立运行的 Lua 脚本，可以作为后台服务运行
--
-- 使用方法：
--   lua queue-worker.lua
--

local cjson = require("cjson.safe")
local redis = require("resty.redis")
local http = require("resty.http")

-- 配置
local config = {
    redis_host = "127.0.0.1",
    redis_port = 6379,
    redis_password = nil,
    redis_database = 0,
    queue_name = "apisix:queue:requests",
    backend_url = "http://127.0.0.1:8080/api/process",
    worker_count = 1,
    poll_interval = 1,
    request_timeout = 30000
}

-- 连接 Redis
local function connect_redis()
    local red = redis:new()
    red:set_timeout(1000)

    local ok, err = red:connect(config.redis_host, config.redis_port)
    if not ok then
        return nil, "failed to connect: " .. err
    end

    if config.redis_password then
        local ok, err = red:auth(config.redis_password)
        if not ok then
            return nil, "failed to auth: " .. err
        end
    end

    if config.redis_database > 0 then
        local ok, err = red:select(config.redis_database)
        if not ok then
            return nil, "failed to select db: " .. err
        end
    end

    return red
end

-- 处理单个请求
local function process_request(request_data)
    local httpc = http.new()
    httpc:set_timeout(config.request_timeout)

    -- 构造请求
    local res, err = httpc:request_uri(config.backend_url, {
        method = request_data.method or "POST",
        body = request_data.body,
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Request-ID"] = request_data.id,
            ["X-Original-URI"] = request_data.uri
        }
    })

    if not res then
        return nil, "request failed: " .. (err or "unknown error")
    end

    return {
        status_code = res.status,
        headers = res.headers,
        body = res.body
    }
end

-- 更新请求状态
local function update_status(red, request_id, status, result)
    local status_key = "apisix:queue:status:" .. request_id
    local result_key = "apisix:queue:result:" .. request_id
    local ttl = 3600

    red:setex(status_key, ttl, status)

    if result then
        local result_json = cjson.encode(result)
        red:setex(result_key, ttl, result_json)
    end
end

-- Worker 主循环
local function worker_loop()
    print("[Worker] Starting queue worker...")

    while true do
        local red, err = connect_redis()
        if not red then
            print("[Worker] Redis connection error: " .. err)
            os.execute("sleep " .. config.poll_interval)
            goto continue
        end

        -- 从队列右侧取出请求（FIFO）
        local result, err = red:rpop(config.queue_name)

        if err then
            print("[Worker] Redis error: " .. err)
            red:close()
            os.execute("sleep " .. config.poll_interval)
            goto continue
        end

        -- 队列为空，等待
        if result == ngx.null or not result then
            red:close()
            os.execute("sleep " .. config.poll_interval)
            goto continue
        end

        -- 解析请求数据
        local request_data, err = cjson.decode(result)
        if not request_data then
            print("[Worker] Failed to decode request: " .. (err or "unknown"))
            red:close()
            goto continue
        end

        local request_id = request_data.id
        print("[Worker] Processing request: " .. request_id)

        -- 更新状态为 processing
        update_status(red, request_id, "processing")

        -- 处理请求
        local response, err = process_request(request_data)

        if not response then
            print("[Worker] Request processing failed: " .. (err or "unknown"))
            update_status(red, request_id, "failed", {
                request_id = request_id,
                status = "failed",
                error = err or "unknown error",
                timestamp = os.time()
            })
        else
            print("[Worker] Request completed: " .. request_id)
            update_status(red, request_id, "completed", {
                request_id = request_id,
                status = "completed",
                result = response,
                timestamp = os.time()
            })
        end

        red:close()

        ::continue::
    end
end

-- 启动 Worker
print("=================================")
print("APISIX Queue Worker")
print("=================================")
print("Redis: " .. config.redis_host .. ":" .. config.redis_port)
print("Queue: " .. config.queue_name)
print("Backend: " .. config.backend_url)
print("=================================")

worker_loop()
