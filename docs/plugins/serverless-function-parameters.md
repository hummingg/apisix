# Serverless 函数参数详解

在 `serverless-pre-function` 和 `serverless-post-function` 插件中，函数签名为：

```lua
return function(conf, ctx)
    -- 你的代码
end
```

## 1. conf 参数

`conf` 是**插件配置对象**，包含你在 Admin API 中为该插件配置的所有参数。

### 示例

如果你的配置是：

```json
{
  "serverless-pre-function": {
    "phase": "access",
    "functions": ["..."],
    "custom_field": "custom_value",
    "timeout": 30
  }
}
```

那么在函数中：

```lua
return function(conf, ctx)
    -- conf.phase = "access"
    -- conf.functions = {...}
    -- conf.custom_field = "custom_value"
    -- conf.timeout = 30
end
```

### 内置字段

- `conf.phase` - 执行阶段（rewrite/access/header_filter/body_filter/log/before_proxy）
- `conf.functions` - 函数列表
- `conf._meta` - 元数据（如 disable、priority、filter 等）

## 2. ctx 参数（核心）

`ctx` 是**请求上下文对象**，包含请求的所有信息和状态。

### 2.1 ctx.var - Nginx 变量

`ctx.var` 提供对所有 Nginx 变量的访问（基于 [resty.ngxvar](https://github.com/api7/lua-resty-ngxvar)）。

#### 请求相关

```lua
-- 请求方法和 URI
ctx.var.request_method    -- "GET", "POST", etc.
ctx.var.uri               -- "/api/users"
ctx.var.request_uri       -- "/api/users?id=123"
ctx.var.args              -- "id=123"
ctx.var.is_args           -- "?" 或 ""

-- 请求头
ctx.var.http_host         -- "example.com"
ctx.var.http_user_agent   -- "Mozilla/5.0..."
ctx.var.http_authorization -- "Bearer token..."
ctx.var.http_content_type  -- "application/json"
ctx.var.http_x_custom      -- 自定义头（http_ + 小写头名）

-- 客户端信息
ctx.var.remote_addr       -- 客户端 IP "192.168.1.100"
ctx.var.remote_port       -- 客户端端口
ctx.var.realip_remote_addr -- 真实 IP（经过 real-ip 处理）

-- 服务器信息
ctx.var.server_addr       -- 服务器 IP
ctx.var.server_port       -- 服务器端口 "9080"
ctx.var.scheme            -- "http" 或 "https"
ctx.var.host              -- Host 头值
```

#### 上游相关

```lua
ctx.var.upstream_addr     -- 上游服务器地址 "127.0.0.1:8080"
ctx.var.upstream_status   -- 上游响应状态码
ctx.var.upstream_response_time -- 上游响应时间（秒）
ctx.var.upstream_host     -- 上游 Host 头
ctx.var.upstream_uri      -- 上游 URI
```

#### 时间和连接

```lua
ctx.var.request_time      -- 请求处理时间（秒）
ctx.var.time_local        -- 本地时间 "01/Jan/2024:12:00:00 +0800"
ctx.var.connection        -- 连接序号
ctx.var.connection_requests -- 当前连接的请求数
```

#### 响应相关

```lua
ctx.var.status            -- 响应状态码
ctx.var.body_bytes_sent   -- 发送的响应体字节数
ctx.var.bytes_sent        -- 发送的总字节数
```

### 2.2 ctx.matched_route - 匹配的路由

```lua
ctx.matched_route.value.id          -- 路由 ID
ctx.matched_route.value.uri         -- 路由 URI 模式
ctx.matched_route.value.name        -- 路由名称
ctx.matched_route.value.methods     -- 允许的 HTTP 方法
ctx.matched_route.value.hosts       -- 匹配的 Host
ctx.matched_route.value.plugins     -- 路由上的插件配置
ctx.matched_route.value.upstream    -- 上游配置
ctx.matched_route.value.service_id  -- 关联的 Service ID
```

### 2.3 ctx.matched_upstream - 上游配置

```lua
ctx.matched_upstream.type           -- "roundrobin", "chash", etc.
ctx.matched_upstream.nodes          -- 上游节点列表
ctx.matched_upstream.scheme         -- "http", "https", "grpc", etc.
ctx.matched_upstream.pass_host      -- Host 传递方式
```

### 2.4 ctx.consumer - 消费者信息

如果请求通过了认证插件：

```lua
ctx.consumer.username               -- 消费者用户名
ctx.consumer.plugins                -- 消费者的插件配置
ctx.consumer_name                   -- 消费者名称（快捷访问）
ctx.consumer_group_id               -- 消费者组 ID
```

### 2.5 其他重要字段

```lua
-- 配置信息
ctx.conf_type                       -- "route", "service", "consumer", etc.
ctx.conf_id                         -- 配置对象 ID
ctx.conf_version                    -- 配置版本

-- 插件相关
ctx.plugins                         -- 当前请求的插件列表
ctx._plugin_name                    -- 当前执行的插件名称

-- 负载均衡
ctx.picked_server                   -- 选中的上游服务器
ctx.balancer_ip                     -- 负载均衡器选择的 IP
ctx.balancer_port                   -- 负载均衡器选择的端口

-- 其他
ctx.script_obj                      -- Script 对象（如果使用了 script）
ctx.global_rules                    -- 全局规则
```

## 3. 实用示例

### 3.1 读取请求信息

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 获取请求方法和 URI
    core.log.info("Method: ", ctx.var.request_method)
    core.log.info("URI: ", ctx.var.uri)
    core.log.info("Query: ", ctx.var.args)

    -- 获取请求头
    local token = ctx.var.http_authorization
    local user_agent = ctx.var.http_user_agent

    -- 获取客户端 IP
    local client_ip = ctx.var.remote_addr

    core.log.info("Client IP: ", client_ip)
end
```

### 3.2 访问控制

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 检查 IP 白名单
    local allowed_ips = {"192.168.1.100", "10.0.0.1"}
    local client_ip = ctx.var.remote_addr

    local allowed = false
    for _, ip in ipairs(allowed_ips) do
        if ip == client_ip then
            allowed = true
            break
        end
    end

    if not allowed then
        return 403, {error = "IP not allowed"}
    end
end
```

### 3.3 修改请求头

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 添加自定义请求头
    core.request.set_header(ctx, "X-Request-ID", ngx.var.request_id)
    core.request.set_header(ctx, "X-Client-IP", ctx.var.remote_addr)

    -- 删除请求头
    core.request.set_header(ctx, "X-Sensitive-Header", nil)
end
```

### 3.4 条件路由

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 根据请求头路由到不同上游
    local version = ctx.var.http_x_api_version

    if version == "v2" then
        -- 修改上游地址
        ctx.var.upstream_uri = "/v2" .. ctx.var.uri
    end
end
```

### 3.5 获取路由信息

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 获取当前路由信息
    local route = ctx.matched_route
    if route then
        core.log.info("Route ID: ", route.value.id)
        core.log.info("Route Name: ", route.value.name)
        core.log.info("Route URI: ", route.value.uri)
    end

    -- 获取消费者信息
    if ctx.consumer then
        core.log.info("Consumer: ", ctx.consumer.username)
    end
end
```

### 3.6 记录自定义日志

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 在 log 阶段记录详细信息
    if conf.phase == "log" then
        local log_data = {
            method = ctx.var.request_method,
            uri = ctx.var.uri,
            status = ctx.var.status,
            client_ip = ctx.var.remote_addr,
            upstream_addr = ctx.var.upstream_addr,
            request_time = ctx.var.request_time,
            upstream_response_time = ctx.var.upstream_response_time,
        }

        core.log.warn("Request Log: ", core.json.encode(log_data))
    end
end
```

### 3.7 动态认证

```lua
return function(conf, ctx)
    local core = require("apisix.core")
    local http = require("resty.http")

    -- 从请求头获取 token
    local token = ctx.var.http_authorization
    if not token then
        return 401, {error = "Missing authorization header"}
    end

    -- 调用外部认证服务
    local httpc = http.new()
    local res, err = httpc:request_uri("http://auth-service/verify", {
        method = "POST",
        body = core.json.encode({token = token}),
        headers = {
            ["Content-Type"] = "application/json",
        }
    })

    if not res or res.status ~= 200 then
        return 401, {error = "Invalid token"}
    end

    -- 将用户信息存储到 ctx 中供后续使用
    local user_info = core.json.decode(res.body)
    ctx.user_id = user_info.user_id
    ctx.user_name = user_info.username

    -- 添加到请求头传递给上游
    core.request.set_header(ctx, "X-User-ID", user_info.user_id)
end
```

### 3.8 响应修改

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 在 header_filter 阶段修改响应头
    if conf.phase == "header_filter" then
        ngx.header["X-Powered-By"] = "APISIX"
        ngx.header["X-Request-Time"] = ctx.var.request_time
    end
end
```

## 4. 可用的核心模块

在 serverless 函数中可以使用的模块：

```lua
local core = require("apisix.core")

-- 日志
core.log.info("message")
core.log.warn("message")
core.log.error("message")

-- JSON
local data = core.json.decode(json_string)
local json_string = core.json.encode(data)

-- 请求
local body = core.request.get_body()
local headers = core.request.headers(ctx)
local header_value = core.request.header(ctx, "X-Custom")
core.request.set_header(ctx, "X-Custom", "value")

-- 响应
core.response.exit(200, {message = "OK"})
core.response.set_header("X-Custom", "value")

-- 表操作
core.table.insert(t, value)
core.table.clear(t)
core.table.nkeys(t)

-- 字符串
core.string.has_prefix(str, prefix)
core.string.has_suffix(str, suffix)
```

## 5. 注意事项

1. **性能考虑**：serverless 函数使用 `loadstring` 动态加载，有一定性能开销，建议用于简单逻辑
2. **错误处理**：函数中的错误会被捕获并记录，但不会中断请求处理
3. **返回值**：返回 `code, body` 可以中断请求并返回响应
4. **阶段限制**：不同阶段可用的操作不同（如 body_filter 阶段不能修改请求头）
5. **安全性**：允许执行任意 Lua 代码，务必限制 Admin API 访问权限

## 6. 调试技巧

### 打印 ctx 内容

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 打印所有 var 变量（注意：可能很多）
    for k, v in pairs(ctx.var) do
        core.log.info("ctx.var.", k, " = ", v)
    end

    -- 打印路由信息
    if ctx.matched_route then
        core.log.info("Route: ", core.json.encode(ctx.matched_route.value))
    end
end
```

### 使用 ngx.say 调试

```lua
return function(conf, ctx)
    -- 直接返回调试信息
    return 200, {
        method = ctx.var.request_method,
        uri = ctx.var.uri,
        client_ip = ctx.var.remote_addr,
        route_id = ctx.matched_route and ctx.matched_route.value.id,
    }
end
```

## 参考

- [ctx.lua 源码](apisix/core/ctx.lua) - 上下文实现
- [serverless/init.lua 源码](apisix/plugins/serverless/init.lua) - Serverless 插件实现
- [Nginx 变量文档](http://nginx.org/en/docs/varindex.html) - 所有可用的 Nginx 变量
