# APISIX 插件系统设计

APISIX 插件系统采用了**优先级驱动的责任链模式**，结合动态加载和阶段式执行。

## 1. 插件生命周期

### 加载阶段

插件加载流程 ([plugin.lua:132-203](apisix/plugin.lua#L132-L203))：

```lua
-- 动态加载插件模块
local pkg_name = "apisix.plugins." .. name
ok, plugin = pcall(require, pkg_name)

-- 验证必需字段
- priority (优先级)
- version (版本)
- schema (配置 schema)

-- 调用插件初始化
if plugin.init then
    plugin.init()
end
```

### 排序机制

插件按优先级降序排列 ([plugin.lua:242-244](apisix/plugin.lua#L242-L244))：

```lua
-- 数字越大越先执行
sort_tab(local_plugins, sort_plugin)
```

## 2. 插件执行模型

### 阶段式执行

插件在 OpenResty 的不同阶段执行 ([plugin.lua:1161-1239](apisix/plugin.lua#L1161-L1239))：

```
rewrite → access → header_filter → body_filter → log
```

**执行流程**：

1. 遍历已排序的插件列表（存储为 `[plugin_obj, plugin_conf, ...]` 交替数组）
2. 检查插件是否有对应阶段的处理函数
3. 应用 **meta_filter** 条件过滤
4. 执行 **pre_function**（可选的前置钩子）
5. 调用插件的阶段函数
6. 处理返回值（HTTP 状态码/响应体）

### 条件执行

支持基于表达式的条件执行 ([plugin.lua:432-466](apisix/plugin.lua#L432-L466))：

```lua
-- 使用 resty.expr 评估条件
if plugin_conf._meta and plugin_conf._meta.filter then
    ok = expr:eval(ctx.var)
end
```

## 3. 插件配置合并策略

### 多层级配置

配置合并顺序 ([plugin.lua:589-774](apisix/plugin.lua#L589-L774))：

```
Route Plugins
    ↓ (merge)
Service Plugins
    ↓ (merge)
Consumer Plugins
    ↓ (merge)
Consumer Group Plugins
```

**合并规则**：

- Route 配置优先级最高
- Consumer 插件标记 `_from_consumer = true`
- 使用 LRU 缓存合并结果

## 4. 核心设计模式

### 责任链模式

```lua
-- 插件按优先级顺序执行
for i = 1, #plugins, 2 do
    local phase_func = plugins[i][phase]
    if phase_func then
        local code, body = phase_func(conf, api_ctx)
        if code or body then
            -- 中断链，返回响应
            core.response.exit(code, body)
        end
    end
end
```

### 策略模式

每个插件实现标准接口：

```lua
{
    name = "plugin-name",
    priority = 1000,
    schema = {...},

    -- 生命周期方法
    init = function() end,           -- 初始化
    destroy = function() end,        -- 清理

    -- 配置验证
    check_schema = function(conf, schema_type) end,

    -- OpenResty 阶段处理函数
    rewrite = function(conf, ctx) end,
    access = function(conf, ctx) end,
    header_filter = function(conf, ctx) end,
    body_filter = function(conf, ctx) end,
    log = function(conf, ctx) end
}
```

### 对象池模式

复用 table 减少 GC 压力 ([plugin.lua:481](apisix/plugin.lua#L481))：

```lua
-- 从对象池获取
plugins = core.tablepool.fetch("plugins", 32, 0)

-- 使用后释放
core.tablepool.release("plugins", plugins)
```

## 5. 高级特性

### 数据加密

支持敏感字段自动加密/解密 ([plugin.lua:972-1061](apisix/plugin.lua#L972-L1061))：

- 基于插件 schema 的 `encrypt_fields` 配置
- 使用 AES 加密存储在 etcd 中
- 运行时自动解密

### 热重载

动态更新插件 ([plugin.lua:342-375](apisix/plugin.lua#L342-L375))：

1. 监听 etcd `/plugins` 配置变化
2. 卸载旧插件（调用 `destroy()`）
3. 加载新插件
4. 重新排序

### 自定义优先级

支持在配置中覆盖插件优先级 ([plugin.lua:512-558](apisix/plugin.lua#L512-L558))：

```lua
{
    "plugin-name": {
        "_meta": {
            "priority": 2000  -- 覆盖默认优先级
        },
        "config_key": "value"
    }
}
```

### 条件过滤

使用表达式控制插件执行：

```lua
{
    "plugin-name": {
        "_meta": {
            "filter": [
                ["arg_debug", "==", "true"]  -- 仅当 query 参数 debug=true 时执行
            ]
        }
    }
}
```

## 6. 数据结构

### 插件存储

```lua
-- 数组（已按优先级排序）
local_plugins = [plugin1, plugin2, ...]

-- 哈希表（快速查找）
local_plugins_hash = {
    ["plugin-name"] = plugin_obj
}
```

### 执行时插件列表

```lua
-- 交替存储插件对象和配置，减少内存分配
plugins = [
    plugin_obj1, conf1,
    plugin_obj2, conf2,
    ...
]
```

## 7. 插件类型

### HTTP 插件

位置：`apisix/plugins/*.lua`

加载：`require("apisix.plugins." .. name)`

### Stream 插件

位置：`apisix/stream/plugins/*.lua`

加载：`require("apisix.stream.plugins." .. name)`

### WASM 插件

支持 WebAssembly 插件，通过 `wasm.require()` 加载。

## 8. 性能优化

### LRU 缓存

```lua
-- 合并后的路由配置缓存
merged_route = core.lrucache.new({
    ttl = 300, count = 512
})

-- 表达式缓存
expr_lrucache = core.lrucache.new({
    ttl = 300, count = 512
})
```

### 预排序

插件在加载时就按优先级排序，运行时无需重复排序。

### 对象池

复用 Lua table，减少 GC 开销。

## 9. 设计优势

1. **高性能**
   - 优先级预排序
   - LRU 缓存
   - 对象池

2. **灵活性**
   - 条件执行
   - 动态优先级
   - 多层配置合并

3. **可扩展**
   - 标准接口
   - 热重载
   - WASM 支持

4. **安全性**
   - Schema 验证
   - 字段加密
   - 错误隔离

## 10. 架构模式

APISIX 插件系统是典型的**微内核架构**：

- **核心**：插件管理和调度（[plugin.lua](apisix/plugin.lua)）
- **插件**：具体功能实现（`apisix/plugins/` 目录）
- **接口**：标准化的插件接口

这种设计使得：
- 核心保持简洁稳定
- 功能通过插件扩展
- 插件可独立开发和测试
- 支持第三方插件生态

## 相关文件

- [apisix/plugin.lua](apisix/plugin.lua) - 插件系统核心
- [apisix/plugins/](apisix/plugins/) - HTTP 插件目录
- [apisix/stream/plugins/](apisix/stream/plugins/) - Stream 插件目录
- [apisix/init.lua](apisix/init.lua) - OpenResty 生命周期入口
