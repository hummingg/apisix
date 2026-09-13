# APISIX 自定义插件设计与实现

APISIX 提供了多种自定义插件的方式，从静态文件插件到动态代码执行，满足不同场景的需求。

## 1. 自定义插件方式对比

| 方式 | 代码位置 | 动态加载 | 通过 API 传递 | 复杂度 | 性能 | 适用场景 |
|------|---------|---------|--------------|--------|------|---------|
| **Lua 插件** | 文件系统 | ❌ 需重启 | ❌ | 高 | 最高 | 可复用的通用功能 |
| **Serverless 插件** | etcd/API | ✅ 实时 | ✅ | 低 | 中等 | 简单的定制逻辑 |
| **Script 字段** | etcd/API | ✅ 实时 | ✅ | 中等 | 中等 | 路由级完整控制 |
| **外部插件** | 独立进程 | ✅ 热重载 | ❌ | 中等 | 中等 | 非 Lua 语言开发 |
| **WASM 插件** | 文件系统 | ✅ 热重载 | ❌ | 高 | 高 | 跨平台/沙箱隔离 |

## 2. Serverless 插件（推荐用于动态代码）

### 2.1 设计原理

Serverless 插件允许通过 Admin API 传递 Lua 函数代码，在运行时动态加载执行。

**核心实现** ([serverless/init.lua:62-73](apisix/plugins/serverless/init.lua#L62-L73))：

```lua
local function load_funcs(functions)
    local funcs = core.table.new(#functions, 0)

    for _, func_str in ipairs(functions) do
        -- 使用 loadstring 动态编译 Lua 代码
        local _, func = pcall(loadstring(func_str))
        funcs[index] = func
        index = index + 1
    end

    return funcs
end
```

**执行流程**：

```
Admin API 提交代码
    ↓
存储到 etcd
    ↓
APISIX 监听配置变化
    ↓
loadstring 编译代码
    ↓
缓存到 LRU Cache
    ↓
在指定阶段执行
```

### 2.2 两种 Serverless 插件

#### serverless-pre-function
在指定阶段**开始时**执行（优先级 10000）

#### serverless-post-function
在指定阶段**结束时**执行（优先级 -2000）

### 2.3 配置示例

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
  "uri": "/api/*",
  "plugins": {
    "serverless-pre-function": {
      "phase": "access",
      "functions": [
        "return function(conf, ctx)
          local core = require(\"apisix.core\")

          -- 自定义认证逻辑
          local token = ctx.var.http_authorization
          if not token or token ~= \"Bearer secret-token\" then
            return 401, {error = \"Unauthorized\"}
          end

          -- 添加自定义请求头
          core.request.set_header(ctx, \"X-Authenticated\", \"true\")
          core.log.info(\"Request authenticated\")
        end"
      ]
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {"127.0.0.1:8080": 1}
  }
}'
```

### 2.4 支持的执行阶段

| 阶段 | 说明 | 可用操作 |
|------|------|---------|
| `rewrite` | URI 重写阶段 | 修改 URI、请求头 |
| `access` | 访问控制阶段 | 认证、鉴权、限流 |
| `header_filter` | 响应头过滤 | 修改响应头 |
| `body_filter` | 响应体过滤 | 修改响应体 |
| `log` | 日志阶段 | 记录日志、统计 |
| `before_proxy` | 代理前阶段 | 最后的请求修改 |

### 2.5 代码要求

**✅ 必须返回函数**：

```lua
-- 正确：匿名函数
return function(conf, ctx)
    ngx.log(ngx.ERR, "Hello")
end

-- 正确：闭包
local count = 0
return function(conf, ctx)
    count = count + 1
    ngx.say("Request #", count)
end
```

**❌ 不能是普通代码**：

```lua
-- 错误：不是函数
local count = 1
ngx.say(count)
```

### 2.6 实用示例

#### 动态 IP 白名单

```json
{
  "serverless-pre-function": {
    "phase": "access",
    "functions": [
      "return function(conf, ctx)
        local core = require('apisix.core')
        local allowed_ips = {'192.168.1.100', '10.0.0.1'}
        local client_ip = ctx.var.remote_addr

        for _, ip in ipairs(allowed_ips) do
          if ip == client_ip then
            return
          end
        end

        return 403, {error = 'IP not allowed: ' .. client_ip}
      end"
    ]
  }
}
```

#### 动态请求重写

```json
{
  "serverless-pre-function": {
    "phase": "rewrite",
    "functions": [
      "return function(conf, ctx)
        local core = require('apisix.core')

        -- 根据请求头路由到不同版本
        local version = ctx.var.http_x_api_version
        if version == 'v2' then
          ctx.var.uri = '/v2' .. ctx.var.uri
        end

        -- 添加追踪 ID
        local request_id = ngx.var.request_id
        core.request.set_header(ctx, 'X-Request-ID', request_id)
      end"
    ]
  }
}
```

#### 外部认证服务集成

```json
{
  "serverless-pre-function": {
    "phase": "access",
    "functions": [
      "return function(conf, ctx)
        local core = require('apisix.core')
        local http = require('resty.http')

        local token = ctx.var.http_authorization
        if not token then
          return 401, {error = 'Missing token'}
        end

        -- 调用外部认证服务
        local httpc = http.new()
        httpc:set_timeout(3000)

        local res, err = httpc:request_uri('http://auth-service/verify', {
          method = 'POST',
          body = core.json.encode({token = token}),
          headers = {['Content-Type'] = 'application/json'}
        })

        if not res or res.status ~= 200 then
          return 401, {error = 'Invalid token'}
        end

        -- 将用户信息传递给上游
        local user = core.json.decode(res.body)
        core.request.set_header(ctx, 'X-User-ID', user.id)
        core.request.set_header(ctx, 'X-User-Name', user.name)
      end"
    ]
  }
}
```

#### 响应头注入

```json
{
  "serverless-post-function": {
    "phase": "header_filter",
    "functions": [
      "return function(conf, ctx)
        ngx.header['X-Powered-By'] = 'APISIX'
        ngx.header['X-Request-Time'] = ctx.var.request_time
        ngx.header['X-Upstream-Addr'] = ctx.var.upstream_addr
      end"
    ]
  }
}
```

#### 自定义日志

```json
{
  "serverless-post-function": {
    "phase": "log",
    "functions": [
      "return function(conf, ctx)
        local core = require('apisix.core')

        local log_entry = {
          timestamp = ngx.time(),
          method = ctx.var.request_method,
          uri = ctx.var.uri,
          status = ctx.var.status,
          client_ip = ctx.var.remote_addr,
          user_agent = ctx.var.http_user_agent,
          request_time = ctx.var.request_time,
          upstream_addr = ctx.var.upstream_addr,
          upstream_status = ctx.var.upstream_status,
          upstream_response_time = ctx.var.upstream_response_time
        }

        core.log.warn('ACCESS_LOG: ', core.json.encode(log_entry))
      end"
    ]
  }
}
```

## 3. Script 字段

### 3.1 设计原理

`script` 字段允许在路由配置中直接传递完整的 Lua 脚本，**完全接管**该路由的请求处理。

**核心实现** ([script.lua:26-38](apisix/script.lua#L26-L38))：

```lua
function _M.load(route, api_ctx)
    local script = route.value.script

    -- 使用 loadstring 加载脚本
    local loadfun, err = loadstring(script, "route#" .. route.value.id)
    if not loadfun then
        error("failed to load script: " .. err)
    end

    -- 执行脚本，返回模块对象
    api_ctx.script_obj = loadfun()
end
```

### 3.2 Script vs Plugins

**重要**：使用 `script` 字段时，**所有插件将被跳过**，脚本完全控制请求处理。

### 3.3 配置示例

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
  "uri": "/api/*",
  "script": "
    local _M = {}
    local core = require(\"apisix.core\")

    function _M.access(ctx)
        -- 自定义访问控制
        local token = ctx.var.http_authorization
        if not token then
            ngx.exit(401)
        end

        core.log.info(\"Script access phase\")
    end

    function _M.header_filter(ctx)
        -- 修改响应头
        ngx.header[\"X-Custom-Script\"] = \"true\"
    end

    function _M.log(ctx)
        -- 记录日志
        core.log.warn(\"Request completed: \", ctx.var.status)
    end

    return _M
  ",
  "upstream": {
    "type": "roundrobin",
    "nodes": {"127.0.0.1:8080": 1}
  }
}'
```

### 3.4 Script 模块结构

```lua
local _M = {}

-- 可选：初始化函数
function _M.init()
    -- 脚本加载时执行一次
end

-- 可选：各个阶段的处理函数
function _M.rewrite(ctx)
    -- rewrite 阶段
end

function _M.access(ctx)
    -- access 阶段
end

function _M.header_filter(ctx)
    -- header_filter 阶段
end

function _M.body_filter(ctx)
    -- body_filter 阶段
end

function _M.log(ctx)
    -- log 阶段
end

return _M
```

## 4. 传统 Lua 插件

### 4.1 目录结构

```bash
# 配置自定义插件路径
# config.yaml
apisix:
  extra_lua_path: "/path/to/custom/?.lua"
```

```
/path/to/custom/
└── apisix/
    ├── plugins/
    │   └── my-plugin.lua      # HTTP 插件
    └── stream/
        └── plugins/
            └── my-stream.lua  # Stream 插件
```

### 4.2 插件模板

```lua
-- my-plugin.lua
local core = require("apisix.core")

-- 配置 Schema
local schema = {
    type = "object",
    properties = {
        api_key = {type = "string"},
        timeout = {type = "integer", minimum = 1, default = 3000},
    },
    required = {"api_key"},
}

local plugin_name = "my-plugin"

local _M = {
    version = 0.1,
    priority = 1000,        -- 优先级（1-99 推荐）
    name = plugin_name,
    schema = schema,
}

-- Schema 验证
function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

-- 初始化（插件加载时调用一次）
function _M.init()
    core.log.info(plugin_name, " plugin initialized")
end

-- 销毁（插件卸载时调用）
function _M.destroy()
    core.log.info(plugin_name, " plugin destroyed")
end

-- 请求处理阶段
function _M.access(conf, ctx)
    core.log.info("my-plugin access phase")

    -- 验证 API Key
    local api_key = ctx.var.http_x_api_key
    if api_key ~= conf.api_key then
        return 401, {error = "Invalid API Key"}
    end
end

function _M.header_filter(conf, ctx)
    ngx.header["X-Plugin"] = plugin_name
end

return _M
```

### 4.3 启用插件

```yaml
# config.yaml
plugins:
  - real-ip
  - ... # 其他内置插件
  - my-plugin  # 你的自定义插件
```

### 4.4 使用插件

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
  "uri": "/api/*",
  "plugins": {
    "my-plugin": {
      "api_key": "secret-key-123",
      "timeout": 5000
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {"127.0.0.1:8080": 1}
  }
}'
```

## 5. 外部插件（Plugin Runner）

### 5.1 架构

```
┌─────────────┐         Unix Socket          ┌──────────────────┐
│   APISIX    │ ◄──── RPC (MessagePack) ────► │  Plugin Runner   │
│   (Lua)     │                                │ (Java/Go/Python) │
└─────────────┘                                └──────────────────┘
      │                                               │
      └──────────────────────────────────���────────────┘
                  作为子进程管理
```

### 5.2 配置

```yaml
# config.yaml
ext-plugin:
  cmd: ["/path/to/runner"]  # Plugin Runner 可执行文件
```

### 5.3 使用外部插件

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
  "uri": "/api/*",
  "plugins": {
    "ext-plugin-pre-req": {
      "conf": [
        {
          "name": "my-java-plugin",
          "value": "{\"key\":\"value\"}"
        }
      ]
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {"127.0.0.1:8080": 1}
  }
}'
```

### 5.4 支持的语言

- **Java**: https://github.com/apache/apisix-java-plugin-runner
- **Go**: https://github.com/apache/apisix-go-plugin-runner
- **Python**: https://github.com/apache/apisix-python-plugin-runner
- **JavaScript**: https://github.com/zenozeng/apisix-javascript-plugin-runner

## 6. WASM 插件

### 6.1 配置

```yaml
# config.yaml
wasm:
  plugins:
    - name: wasm-plugin
      priority: 7999
      file: /path/to/plugin.wasm
```

### 6.2 优势

- 高性能（接近原生）
- 沙箱隔离（安全）
- 跨平台
- 支持多种语言（Rust、C、C++、AssemblyScript 等）

## 7. 性能对比

| 方式 | 加载时间 | 执行性能 | 内存占用 | 热重载 |
|------|---------|---------|---------|--------|
| Lua 插件 | 最快（预编译） | 最高 | 低 | ❌ |
| Serverless | 中等（动态编译+缓存） | 中等 | 中等 | ✅ |
| Script | 中等（动态编译+缓存） | 中等 | 中等 | ✅ |
| 外部插件 | 慢（RPC 开销） | 中等 | 高（独立进程） | ✅ |
| WASM | 快（预编译） | 高 | 低 | ✅ |

## 8. 安全考虑

### 8.1 Serverless/Script 安全风险

**⚠️ 严重风险**：

1. **任意代码执行**：可以执行任何 Lua 代码
2. **系统访问**：可以访问文件系统、网络、系统调用
3. **资源耗尽**：可能导致 CPU、内存耗尽
4. **数据泄露**：可以读取 etcd 中的敏感数据

### 8.2 安全措施

#### 限制 Admin API 访问

```yaml
# config.yaml
deployment:
  admin:
    admin_key_required: true
    allow_admin:
      - 127.0.0.1      # 仅本地访问
      - 10.0.0.0/8     # 或内网访问
    admin_key:
      - key: your-very-secure-key-here
        role: admin
```

#### 代码审查流程

```
开发者提交代码
    ↓
代码审查（人工/自动）
    ↓
安全扫描
    ↓
测试环境验证
    ↓
生产环境部署
```

#### 使用外部插件替代

对于不受信任的代码，使用外部插件（独立进程，更好的隔离）。

### 8.3 生产环境建议

1. **仅允许受信任的管理员使用 Serverless/Script**
2. **启用 Admin API 认证和 IP 白名单**
3. **使用 RBAC 控制权限**
4. **记录所有 Admin API 操作日志**
5. **定期审计动态代码**
6. **考虑使用 WASM 插件（沙箱隔离）**

## 9. 选择指南

### 9.1 决策树

```
需要动态加载？
├─ 否 → 传统 Lua 插件（最高性能）
└─ 是
    ├─ 简单逻辑（< 50 行）？
    │   └─ 是 → Serverless 插件
    ├─ 完整控制流程？
    │   └─ 是 → Script 字段
    ├─ 非 Lua 语言？
    │   └─ 是 → 外部插件
    └─ 需要沙箱隔离？
        └─ 是 → WASM 插件
```

### 9.2 场景推荐

| 场景 | 推荐方式 | 原因 |
|------|---------|------|
| 快速原型验证 | Serverless | 无需重启，快速迭代 |
| 特定路由定制逻辑 | Serverless | 配置简单，易于管理 |
| 临时的 A/B 测试 | Serverless | 可随时启用/禁用 |
| 复杂业务逻辑 | 外部插件 | 使用熟悉的语言 |
| 可复用的通用功能 | Lua 插件 | 最高性能，代码复用 |
| 第三方不受信任代码 | WASM 插件 | 沙箱隔离，安全 |
| 完全自定义请求处理 | Script | 完整控制权 |

## 10. 最佳实践

### 10.1 Serverless 插件

```lua
-- ✅ 好的实践
return function(conf, ctx)
    local core = require("apisix.core")

    -- 1. 尽早返回
    if not ctx.var.http_authorization then
        return 401, {error = "Unauthorized"}
    end

    -- 2. 使用局部变量
    local token = ctx.var.http_authorization

    -- 3. 错误处理
    local ok, err = some_operation()
    if not ok then
        core.log.error("Operation failed: ", err)
        return 500, {error = "Internal error"}
    end

    -- 4. 避免阻塞操作
    -- 使用 ngx.timer.at 进行异步操作
end
```

### 10.2 避免的反模式

```lua
-- ❌ 不好的实践
return function(conf, ctx)
    -- 1. 避免全局变量
    global_var = "bad"  -- 会污染全局命名空间

    -- 2. 避免长时间阻塞
    ngx.sleep(10)  -- 会阻塞 worker

    -- 3. 避免在每次请求中创建大对象
    local huge_table = {}
    for i = 1, 1000000 do
        huge_table[i] = i
    end

    -- 4. 避免在 log 阶段修改请求
    if conf.phase == "log" then
        core.request.set_header(ctx, "X-Test", "value")  -- 无效
    end
end
```

### 10.3 性能优化

```lua
-- 使用模块级缓存
local lrucache = require("resty.lrucache").new(200)

return function(conf, ctx)
    local core = require("apisix.core")

    -- 缓存昂贵的计算结果
    local cache_key = "user:" .. ctx.var.http_user_id
    local user_data = lrucache:get(cache_key)

    if not user_data then
        -- 执行昂贵的操作
        user_data = fetch_user_data()
        lrucache:set(cache_key, user_data, 300)  -- 缓存 5 分钟
    end

    -- 使用缓存的数据
    core.request.set_header(ctx, "X-User-Name", user_data.name)
end
```

## 11. 调试技巧

### 11.1 启用调试日志

```yaml
# config.yaml
nginx_config:
  error_log_level: debug
```

### 11.2 打印调试信息

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    -- 打印到错误日志
    core.log.warn("Debug: ", core.json.encode({
        method = ctx.var.request_method,
        uri = ctx.var.uri,
        client_ip = ctx.var.remote_addr
    }))

    -- 直接返回调试信息
    return 200, {
        debug = {
            vars = {
                method = ctx.var.request_method,
                uri = ctx.var.uri,
            },
            route = ctx.matched_route and ctx.matched_route.value.id
        }
    }
end
```

### 11.3 使用 inspect 插件

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
  "uri": "/api/*",
  "plugins": {
    "inspect": {
      "delay": 3,
      "hooks_file": "/path/to/hooks.lua"
    }
  }
}'
```

## 12. 相关文档

- [plugin.lua](apisix/plugin.lua) - 插件系统核心
- [serverless/init.lua](apisix/plugins/serverless/init.lua) - Serverless 插件实现
- [script.lua](apisix/script.lua) - Script 实现
- [example-plugin.lua](apisix/plugins/example-plugin.lua) - 插件示例
- [plugin-develop.md](docs/en/latest/plugin-develop.md) - 插件开发文档
- [external-plugin.md](docs/en/latest/external-plugin.md) - 外部插件文档
