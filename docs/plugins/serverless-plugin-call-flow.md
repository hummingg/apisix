# Serverless 插件调用流程详解

## 1. 插件定义

[serverless-pre-function.lua:17](apisix/plugins/serverless-pre-function.lua#L17)：

```lua
return require("apisix.plugins.serverless.init")("serverless-pre-function", 10000)
```

这一行代码做了两件事：
1. 调用 `serverless.init` 工厂函数
2. 传入插件名称 `"serverless-pre-function"` 和优先级 `10000`

## 2. 插件初始化

### 2.1 工厂函数创建插件对象

[serverless/init.lua:30-124](apisix/plugins/serverless/init.lua#L30-L124)：

```lua
return function(plugin_name, priority)
    local core = require("apisix.core")

    -- 创建 LRU 缓存（用于缓存编译后的函数）
    local lrucache = core.lrucache.new({
        type = "plugin",
    })

    -- 定义插件对象
    local _M = {
        version = 0.1,
        priority = priority,      -- 10000（很高的优先级）
        name = plugin_name,       -- "serverless-pre-function"
        schema = schema,
    }

    -- 为每个阶段生成处理函数
    for _, phase in ipairs(phases) do
        _M[phase] = function (conf, ctx)
            return call_funcs(phase, conf, ctx)
        end
    end

    return _M
end
```

**关键点**：
- 优先级 `10000` 非常高，确保在大多数插件之前执行
- 为所有阶段（rewrite、access、header_filter、body_filter、log、before_proxy）都生成了处理函数

### 2.2 插件加载

[plugin.lua:132-203](apisix/plugin.lua#L132-L203)：

```lua
local function load_plugin(name, plugins_list, plugin_type)
    local pkg_name = "apisix.plugins." .. name
    ok, plugin = pcall(require, pkg_name)

    -- 验证必需字段
    if not plugin.priority then
        core.log.error("invalid plugin [", name, "], missing field: priority")
        return
    end

    -- 注入 schema
    plugin.schema.properties._meta = plugin_injected_schema._meta

    -- 添加到插件列表
    core.table.insert(plugins_list, plugin)

    -- 调用插件的 init 方法（如果有）
    if plugin.init then
        plugin.init()
    end
end
```

### 2.3 插件排序

[plugin.lua:242-244](apisix/plugin.lua#L242-L244)：

```lua
-- 按优先级降序排列（数字越大越先执行）
if #local_plugins > 1 then
    sort_tab(local_plugins, sort_plugin)
end
```

**结果**：`serverless-pre-function`（优先级 10000）会排在大多数插件前面。

## 3. 请求处理流程

### 3.1 OpenResty 生命周期

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenResty 请求生命周期                      │
├─────────────────────────────────────────────────────────────┤
│  init_by_lua        → 启动时初始化                            │
│  init_worker_by_lua → Worker 进程初始化                       │
│  ↓                                                            │
│  ssl_certificate    → SSL 握手阶段                            │
│  ↓                                                            │
│  rewrite_by_lua     → URI 重写阶段      ← serverless 可执行   │
│  ↓                                                            │
│  access_by_lua      → 访问控制阶段      ← serverless 可执行   │
│  ↓                                                            │
│  balancer_by_lua    → 负载均衡阶段      ← before_proxy       │
│  ↓                                                            │
│  [代理到上游服务器]                                            │
│  ↓                                                            │
│  header_filter      → 响应头过滤阶段    ← serverless 可执行   │
│  ↓                                                            │
│  body_filter        → 响应体过滤阶段    ← serverless 可执行   │
│  ↓                                                            │
│  log_by_lua         → 日志阶段          ← serverless 可执行   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 APISIX Access 阶段详细流程

[init.lua:668-827](apisix/init.lua#L668-L827)：

```lua
function _M.http_access_phase()
    -- 1. 创建请求上下文
    local api_ctx = core.tablepool.fetch("api_ctx", 0, 32)
    ngx_ctx.api_ctx = api_ctx
    core.ctx.set_vars_meta(api_ctx)

    -- 2. 路由匹配
    router.router_http.match(api_ctx)
    local route = api_ctx.matched_route

    -- 3. 运行全局规则
    local global_rules = apisix_global_rules.global_rules()
    plugin.run_global_rules(api_ctx, global_rules, nil)

    -- 4. 检查是否使用 script
    if route.value.script then
        script.load(route, api_ctx)
        script.run("access", api_ctx)
    else
        -- 5. 过滤插件（准备要执行的插件列表）
        local plugins = plugin.filter(api_ctx, route)
        api_ctx.plugins = plugins

        -- 6. 运行 rewrite 阶段插件
        plugin.run_plugin("rewrite", plugins, api_ctx)

        -- 7. 如果有消费者，合并消费者插件
        if api_ctx.consumer then
            route, changed = plugin.merge_consumer_route(...)
            if changed then
                api_ctx.plugins = plugin.filter(api_ctx, route, ...)
                plugin.run_plugin("rewrite_in_consumer", api_ctx.plugins, api_ctx)
            end
        end

        -- 8. 运行 access 阶段插件
        plugin.run_plugin("access", plugins, api_ctx)
    end

    -- 9. 处理上游
    _M.handle_upstream(api_ctx, route, enable_websocket)
end
```

### 3.3 插件过滤

[plugin.lua:469-561](apisix/plugin.lua#L469-L561)：

```lua
function _M.filter(ctx, conf, plugins, route_conf, phase)
    local user_plugin_conf = conf.value.plugins

    plugins = plugins or core.tablepool.fetch("plugins", 32, 0)

    -- 遍历所有已加载的插件（按优先级排序）
    for _, plugin_obj in ipairs(local_plugins) do
        local name = plugin_obj.name
        local plugin_conf = user_plugin_conf[name]

        -- 检查插件是否在路由配置中启用
        if type(plugin_conf) ~= "table" then
            goto continue
        end

        -- 检查插件是否被禁用
        if check_disable(plugin_conf) then
            goto continue
        end

        -- 检查 meta filter（条件执行）
        -- ...

        -- 添加到执行列表（交替存储：插件对象、插件配置）
        core.table.insert(plugins, plugin_obj)
        core.table.insert(plugins, plugin_conf)

        ::continue::
    end

    return plugins
end
```

**结果**：返回一个数组 `[plugin_obj1, conf1, plugin_obj2, conf2, ...]`

### 3.4 插件执行

[plugin.lua:1161-1239](apisix/plugin.lua#L1161-L1239)：

```lua
function _M.run_plugin(phase, plugins, api_ctx)
    if not plugins or #plugins == 0 then
        return api_ctx
    end

    -- 遍历插件列表（步长为 2，因为交替存储）
    for i = 1, #plugins, 2 do
        local plugin_obj = plugins[i]      -- 插件对象
        local plugin_conf = plugins[i + 1] -- 插件配置

        -- 获取插件的阶段处理函数
        local phase_func = plugin_obj[phase]

        if phase_func then
            -- 检查 meta filter（条件执行）
            if not meta_filter(api_ctx, plugin_obj.name, plugin_conf) then
                goto CONTINUE
            end

            -- 运行 pre_function（如果配置了）
            run_meta_pre_function(plugin_conf, api_ctx, plugin_obj.name)

            -- 执行插件的阶段函数
            api_ctx._plugin_name = plugin_obj.name
            local code, body = phase_func(plugin_conf, api_ctx)
            api_ctx._plugin_name = nil

            -- 如果插件返回了状态码，中断请求
            if code or body then
                if code >= 400 then
                    core.log.warn(plugin_obj.name, " exits with http status code ", code)
                end
                core.response.exit(code, body)
            end
        end

        ::CONTINUE::
    end

    return api_ctx
end
```

## 4. Serverless 函数执行

### 4.1 阶段函数调用

当 `plugin.run_plugin("access", plugins, api_ctx)` 执行时，会调用：

```lua
-- serverless-pre-function 的 access 函数
plugin_obj.access(plugin_conf, api_ctx)
```

### 4.2 call_funcs 函数

[serverless/init.lua:75-89](apisix/plugins/serverless/init.lua#L75-L89)：

```lua
local function call_funcs(phase, conf, ctx)
    -- 检查是否是配置的执行阶段
    if phase ~= conf.phase then
        return
    end

    -- 从 LRU 缓存获取编译后的函数（或编译新函数）
    local functions = core.lrucache.plugin_ctx(
        lrucache, ctx, nil,
        load_funcs, conf.functions
    )

    -- 依次执行所有函数
    for _, func in ipairs(functions) do
        local code, body = func(conf, ctx)
        if code or body then
            return code, body  -- 如果函数返回值，中断执行
        end
    end
end
```

### 4.3 load_funcs 函数（动态编译）

[serverless/init.lua:62-73](apisix/plugins/serverless/init.lua#L62-L73)：

```lua
local function load_funcs(functions)
    local funcs = core.table.new(#functions, 0)

    local index = 1
    for _, func_str in ipairs(functions) do
        -- 使用 loadstring 动态编译 Lua 代码
        local _, func = pcall(loadstring(func_str))
        funcs[index] = func
        index = index + 1
    end

    return funcs
end
```

**关键点**：
- `loadstring(func_str)` 将字符串编译为 Lua 函数
- 编译后的函数被缓存在 LRU Cache 中
- 下次请求直接使用缓存的函数，无需重新编译

## 5. 完整调用链

```
HTTP 请求到达
    ↓
OpenResty: access_by_lua
    ↓
APISIX: init.lua:http_access_phase()
    ↓
路由匹配: router.router_http.match(api_ctx)
    ↓
插件过滤: plugin.filter(api_ctx, route)
    ├─ 遍历所有已加载插件（按优先级排序）
    ├─ serverless-pre-function (priority=10000) 排在前面
    ├─ 检查插件是否在路由配置中启用
    └─ 构建插件执行列表 [plugin_obj, conf, ...]
    ↓
运行 rewrite 阶段: plugin.run_plugin("rewrite", plugins, api_ctx)
    ├─ 遍历插件列表
    ├─ 调用 serverless-pre-function.rewrite(conf, ctx)
    │   └─ call_funcs("rewrite", conf, ctx)
    │       ├─ 检查 conf.phase == "rewrite"?
    │       ├─ 从 LRU 缓存获取编译后的函数
    │       └─ 执行用户定义的函数
    └─ 继续执行其他插件...
    ↓
运行 access 阶段: plugin.run_plugin("access", plugins, api_ctx)
    ├─ 遍历插件列表
    ├─ 调用 serverless-pre-function.access(conf, ctx)
    │   └─ call_funcs("access", conf, ctx)
    │       ├─ 检查 conf.phase == "access"?
    │       ├─ 从 LRU 缓存获取编译后的函数
    │       └─ 执行用户定义的函数
    │           └─ return function(conf, ctx)
    │               -- 你的代码在这里执行
    │               end
    └─ 继续执行其他插件...
    ↓
代理到上游服务器
    ↓
OpenResty: header_filter_by_lua
    ↓
APISIX: init.lua:http_header_filter_phase()
    ↓
plugin.run_plugin("header_filter", plugins, api_ctx)
    └─ serverless-pre-function.header_filter(conf, ctx)
    ↓
OpenResty: body_filter_by_lua
    ↓
APISIX: init.lua:http_body_filter_phase()
    ↓
plugin.run_plugin("body_filter", plugins, api_ctx)
    └─ serverless-pre-function.body_filter(conf, ctx)
    ↓
OpenResty: log_by_lua
    ↓
APISIX: init.lua:http_log_phase()
    ↓
plugin.run_plugin("log", plugins, api_ctx)
    └─ serverless-pre-function.log(conf, ctx)
    ↓
请求结束
```

## 6. 关键机制

### 6.1 优先级控制

```lua
-- serverless-pre-function: priority = 10000 (很高)
-- serverless-post-function: priority = -2000 (很低)
```

这确保了：
- `serverless-pre-function` 在大多数插件**之前**执行
- `serverless-post-function` 在大多数插件**之后**执行

### 6.2 LRU 缓存

```lua
local lrucache = core.lrucache.new({type = "plugin"})

local functions = core.lrucache.plugin_ctx(
    lrucache, ctx, nil,
    load_funcs, conf.functions
)
```

**缓存键**：基于 `ctx.conf_type`、`ctx.conf_id`、`ctx.conf_version`

**好处**：
- 避免每次请求都重新编译代码
- 配置变化时自动失效（版本号变化）

### 6.3 阶段控制

```lua
if phase ~= conf.phase then
    return  -- 不执行
end
```

用户配置的 `phase` 字段决定函数在哪个阶段执行。

### 6.4 条件执行（meta filter）

```lua
if plugin_conf._meta and plugin_conf._meta.filter then
    -- 使用表达式引擎评估条件
    ok = expr:eval(ctx.var)
    if not ok then
        goto CONTINUE  -- 跳过此插件
    end
end
```

支持基于请求变量的条件执行。

## 7. 配置示例与执行

### 配置

```json
{
  "uri": "/api/*",
  "plugins": {
    "serverless-pre-function": {
      "phase": "access",
      "functions": [
        "return function(conf, ctx)
          local core = require('apisix.core')
          core.log.info('Hello from serverless!')
          if ctx.var.http_authorization ~= 'Bearer token' then
            return 401, {error = 'Unauthorized'}
          end
        end"
      ]
    }
  }
}
```

### 执行流程

1. **请求到达** `/api/users`
2. **路由匹配** 成功
3. **插件过滤** 发现 `serverless-pre-function` 已启用
4. **rewrite 阶段**
   - 调用 `serverless-pre-function.rewrite(conf, ctx)`
   - `conf.phase = "access"` ≠ `"rewrite"` → 不执行
5. **access 阶段**
   - 调用 `serverless-pre-function.access(conf, ctx)`
   - `conf.phase = "access"` = `"access"` → 执行
   - 从缓存获取编译后的函数（首次请求会编译）
   - 执行用户函数：
     ```lua
     function(conf, ctx)
       local core = require('apisix.core')
       core.log.info('Hello from serverless!')
       if ctx.var.http_authorization ~= 'Bearer token' then
         return 401, {error = 'Unauthorized'}
       end
     end
     ```
   - 如果 Authorization 头不正确，返回 `401, {error = 'Unauthorized'}`
   - `plugin.run_plugin` 检测到返回值，调用 `core.response.exit(401, body)`
   - **请求被中断**，不再执行后续插件和上游代理

## 8. 性能考虑

### 首次请求

```
loadstring 编译代码 (慢)
    ↓
缓存到 LRU Cache
    ↓
执行函数
```

### 后续请求

```
从 LRU Cache 获取函数 (快)
    ↓
执行函数
```

### 配置更新

```
etcd 配置变化
    ↓
ctx.conf_version 变化
    ↓
LRU Cache 键变化
    ↓
重新编译代码
    ↓
缓存新版本
```

## 9. 调试技巧

### 查看插件执行顺序

```bash
# 启用调试模式
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
  "uri": "/test",
  "plugins": {
    "serverless-pre-function": {
      "phase": "access",
      "functions": [
        "return function(conf, ctx)
          local core = require(\"apisix.core\")
          core.log.warn(\"[DEBUG] serverless-pre-function executed\")
          core.log.warn(\"[DEBUG] Priority: \", 10000)
        end"
      ]
    }
  }
}'
```

### 查看所有插件优先级

```bash
curl http://127.0.0.1:9180/v1/schema | jq '.plugins[] | {name: .name, priority: .priority}' | sort -k2 -n
```

### 打印执行上下文

```lua
return function(conf, ctx)
    local core = require("apisix.core")

    core.log.warn("=== Serverless Function Debug ===")
    core.log.warn("Phase: ", conf.phase)
    core.log.warn("Route ID: ", ctx.matched_route.value.id)
    core.log.warn("URI: ", ctx.var.uri)
    core.log.warn("Method: ", ctx.var.request_method)
    core.log.warn("Client IP: ", ctx.var.remote_addr)
end
```

## 10. 总结

**Serverless 插件的调用本质**：

1. **插件系统统一管理**：serverless 插件和普通插件一样，通过插件系统加载和执行
2. **优先级控制执行顺序**：`priority = 10000` 确保早期执行
3. **动态代码编译**：使用 `loadstring` 将字符串编译为函数
4. **LRU 缓存优化性能**：避免重复编译
5. **阶段控制灵活性**：用户可选择在哪个阶段执行
6. **标准插件接口**：实现了所有标准阶段函数（rewrite、access 等）

**关键文件**：
- [init.lua](apisix/init.lua) - OpenResty 生命周期入口
- [plugin.lua](apisix/plugin.lua) - 插件系统核心
- [serverless/init.lua](apisix/plugins/serverless/init.lua) - Serverless 插件实现
- [serverless-pre-function.lua](apisix/plugins/serverless-pre-function.lua) - 插件定义
