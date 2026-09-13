# APISIX Balancer 设计原理：如何避免 TCP 连接

## 问题背景

在 Nginx/OpenResty 的 **balancer 阶段**，存在严格的限制：
- ❌ 不能建立新的 TCP 连接
- ❌ 不能访问外部服务（数据库、Redis 等）
- ❌ 不能执行阻塞操作

但负载均衡需要：
- ✅ 健康检查（需要 TCP 连接）
- ✅ 动态更新节点状态
- ✅ 实时获取节点健康信息

**APISIX 如何解决这个矛盾？**

---

## 核心设计思想

> **将所有需要 TCP 连接的操作移到后台异步执行，balancer 阶段只做纯内存操作**

---

## 1. 异步健康检查 + 共享内存

### 1.1 健康检查在后台运行

**实现文件**：
- [apisix/healthcheck_manager.lua](apisix/healthcheck_manager.lua)
- `deps/share/lua/5.1/resty/healthcheck.lua`

**后台定时器**：
```lua
-- healthcheck_manager.lua:265-292
ngx.timer.every(1, timer_create_checker)      -- 每秒创建新检查器
ngx.timer.every(1, timer_working_pool_check)  -- 每秒清理过期检查器
```

**主动健康检查**：
```lua
-- healthcheck.lua:1728-1796
-- 每 0.1 秒评估一次
local CHECK_INTERVAL = 0.1

-- 使用分布式锁确保只有一个 worker 执行
-- 10% 抖动分散各 worker 的启动时间
```

**关键特性**：
- 完全独立于请求处理流程
- 在后台持续运行
- 所有 worker 协同工作（分布式锁）

### 1.2 共享内存存储健康状态

**共享内存配置**：
```lua
-- apisix/cli/ngx_tpl.lua:81
lua_shared_dict upstream-healthcheck 10m;
```

**存储的数据结构**：
```lua
-- healthcheck.lua:1666-1671
self.TARGET_STATE     = "lua-resty-healthcheck:<name>:state"
self.TARGET_COUNTER   = "lua-resty-healthcheck:<name>:counter"
self.TARGET_LIST      = "lua-resty-healthcheck:<name>:target_list"
self.TARGET_LIST_LOCK = "lua-resty-healthcheck:<name>:target_list_lock"
self.TARGET_LOCK      = "lua-resty-healthcheck:<name>:target_lock"
self.PERIODIC_LOCK    = "lua-resty-healthcheck::period_lock:"
```

**健康状态值**：
- `"healthy"` - 健康
- `"unhealthy"` - 不健康
- `"mostly_healthy"` - 大部分健康
- `"mostly_unhealthy"` - 大部分不健康

### 1.3 Balancer 阶段只读取共享内存

**关键代码** - [balancer.lua:77](apisix/balancer.lua#L77)：
```lua
local function fetch_health_nodes(upstream, checker)
    if not checker then
        return all_nodes  -- 无健康检查，返回所有节点
    end

    -- 遍历所有节点，查询健康状态
    for _, node in ipairs(nodes) do
        -- ⭐ 只从共享内存读取，无 TCP 连接
        local ok, err = healthcheck_manager.fetch_node_status(checker,
                                             node.host, port or node.port, host)
        if ok then
            up_nodes = transform_node(up_nodes, node)
        end
    end

    -- 如果所有节点都不健康，使用全部节点
    if core.table.nkeys(up_nodes) == 0 then
        core.log.warn("all upstream nodes is unhealthy, use default")
        return all_nodes
    end

    return up_nodes
end
```

**`fetch_node_status` 实现** - [healthcheck_manager.lua:110-117](apisix/healthcheck_manager.lua#L110-L117)：
```lua
function _M.fetch_node_status(checker, ip, port, host)
    -- 只调用 checker:get_target_status()
    -- 该方法只从共享内存读取，返回布尔值
    return checker:get_target_status(ip, port, host)
end
```

---

## 2. 两层 LRU 缓存机制

**定义位置** - [balancer.lua:34-39](apisix/balancer.lua#L34-L39)：

```lua
-- 缓存负载均衡器实例
local lrucache_server_picker = core.lrucache.new({
    ttl = 300,    -- 5 分钟过期
    count = 256   -- 最多 256 个
})

-- 缓存地址解析结果
local lrucache_addr = core.lrucache.new({
    ttl = 300,         -- 5 分钟过期
    count = 1024 * 4   -- 最多 4096 个
})
```

### 2.1 server_picker 缓存

**缓存键** - [balancer.lua:233-240](apisix/balancer.lua#L233-L240)：
```lua
local version = ctx.upstream_version
local key = ctx.upstream_key

if checker then
    version = version .. "#" .. checker.status_ver
end

local server_picker = lrucache_server_picker(key, version,
                                             create_server_picker, up_conf, checker)
```

**缓存内容**：
- 负载均衡器实例（roundrobin、chash、ewma、least_conn）
- 包含节点列表、权重、算法状态

**优势**：
- 避免每次请求都创建负载均衡器
- 版本号机制自动失效（upstream 配置变更或健康状态变更）

### 2.2 地址解析缓存

**使用位置** - [balancer.lua:254](apisix/balancer.lua#L254)：
```lua
local res, err = lrucache_addr(server, nil, parse_addr, server)
-- server 格式: "192.168.1.1:8080"
-- 返回: {host = "192.168.1.1", port = 8080, domain = nil}
```

**优势**：
- 避免重复解析 "host:port" 字符串
- 纯字符串操作，无系统调用

---

## 3. 延迟创建 + 后台初始化

### 3.1 健康检查器的创建流程

**两个池的设计** - [healthcheck_manager.lua:34-35](apisix/healthcheck_manager.lua#L34-L35)：
```lua
local waiting_pool = {}  -- 等待创建的检查器
local working_pool = {}  -- 已创建的检查器
```

**流程图**：
```
Access 阶段                后台定时器                Balancer 阶段
    │                          │                          │
    ├─ fetch_checker()         │                          │
    │  (不阻塞)                │                          │
    │                          │                          │
    ├─ 加入 waiting_pool ──────┼─ timer_create_checker   │
    │                          │  (异步创建)              │
    │                          │                          │
    │                          ├─ create_checker()        │
    │                          │  (建立 TCP 连接)         │
    │                          │                          │
    │                          ├─ 移到 working_pool ──────┼─ 使用 checker
    │                          │                          │  (只读共享内存)
    └─ 继续处理请求            └─ 每秒循环               └─ 选择服务器
```

**关键代码** - [healthcheck_manager.lua:93-107](apisix/healthcheck_manager.lua#L93-L107)：
```lua
function _M.fetch_checker(up_conf)
    local checker = working_pool[key]
    if checker then
        return checker  -- 已创建，直接返回
    end

    -- 未创建，加入等待队列（不阻塞）
    waiting_pool[key] = {
        up_conf = up_conf,
        create_time = now,
    }

    return nil  -- 返回 nil，balancer 会使用所有节点
end
```

### 3.2 健康检查器的创建

**创建函数** - [healthcheck_manager.lua:47-90](apisix/healthcheck_manager.lua#L47-L90)：
```lua
local function create_checker(up_conf)
    local checker = healthcheck.new({
        name = get_healthchecker_name(up_conf),
        shm_name = "upstream-healthcheck",
        checks = up_conf.checks,
        events_module = "resty.events",
    })

    -- 添加目标节点
    for _, node in ipairs(up_conf.nodes) do
        local ok, err = checker:add_target(node.host, port or node.port,
                                           host, true, host_hdr)
        if not ok then
            core.log.error("failed to add new health check target: ", err)
        end
    end

    return checker
end
```

**在后台定时器中调用** - [healthcheck_manager.lua:151-213](apisix/healthcheck_manager.lua#L151-L213)：
```lua
local function timer_create_checker(premature)
    -- 遍历 waiting_pool
    for key, waiting_item in pairs(waiting_pool) do
        local checker, err = create_checker(waiting_item.up_conf)
        if checker then
            working_pool[key] = checker
            waiting_pool[key] = nil
        end
    end
end
```

---

## 4. 被动健康检查机制

### 4.1 在 Balancer 阶段报告失败

**报告位置** - [balancer.lua:216-229](apisix/balancer.lua#L216-L229)：
```lua
if ctx.balancer_try_count > 1 then
    -- 重试时报告上次失败
    if checker then
        local state, code = get_last_failure()
        local host = up_conf.checks and up_conf.checks.active
                     and up_conf.checks.active.host
        local port = up_conf.checks and up_conf.checks.active
                     and up_conf.checks.active.port

        if state == "failed" then
            if code == 504 then
                checker:report_timeout(ctx.balancer_ip,
                                      port or ctx.balancer_port, host)
            else
                checker:report_tcp_failure(ctx.balancer_ip,
                                          port or ctx.balancer_port, host)
            end
        else
            checker:report_http_status(ctx.balancer_ip,
                                      port or ctx.balancer_port, host, code)
        end
    end
end
```

### 4.2 report_* 方法只更新共享内存

**实现原理** - `healthcheck.lua`：
```lua
function _M:report_timeout(ip, port, hostname)
    -- 只更新共享内存中的计数器
    local key = self:_get_target_key(ip, port, hostname)
    local counter = shm:get(self.TARGET_COUNTER .. key) or 0
    shm:set(self.TARGET_COUNTER .. key, counter + 1)

    -- 判断是否需要标记为不健康
    if counter >= self.checks.passive.unhealthy.timeouts then
        shm:set(self.TARGET_STATE .. key, "unhealthy")
    end
end
```

**关键点**：
- ✅ 只操作共享内存
- ✅ 无 TCP 连接
- ✅ 无阻塞操作
- ✅ 利用实际请求结果更新健康状态

---

## 5. 数据流向图

```
┌─────────────────────────────────────────────────────────────────┐
│                        后台异步层                                │
│  ┌──────────────────┐         ┌──────────────────┐             │
│  │  ngx.timer.every │         │  主动健康检查     │             │
│  │  (每秒)          │────────▶│  (每 0.1 秒)     │             │
│  │                  │         │  建立 TCP 连接    │             │
│  └──────────────────┘         └──────────────────┘             │
│           │                            │                         │
│           │ 创建 checker               │ 检查结果                │
│           ▼                            ▼                         │
│  ┌─────────────────────────────────────────────────────┐        │
│  │         共享内存: upstream-healthcheck (10MB)        │        │
│  │  - TARGET_STATE: 健康状态                            │        │
│  │  - TARGET_COUNTER: 失败计数                          │        │
│  │  - TARGET_LIST: 节点列表                             │        │
│  └─────────────────────────────────────────────────────┘        │
└──────────────────────────┬──────────────────────────────────────┘
                           │ 只读
                           │
┌──────────────────────────┴──────────────────────────────────────┐
│                      请求处理层 (Balancer 阶段)                  │
│  ┌──────────────────┐         ┌──────────────────┐             │
│  │  fetch_health_   │         │  LRU 缓存         │             │
│  │  nodes()         │────────▶│  - server_picker  │             │
│  │  (读共享内存)    │         │  - addr           │             │
│  └──────────────────┘         └──────────────────┘             │
│           │                            │                         │
│           │ 健康节点列表               │ 缓存的 picker           │
│           ▼                            ▼                         │
│  ┌─────────────────────────────────────────────────────┐        │
│  │         server_picker.get(ctx)                       │        │
│  │         选择服务器 (纯内存操作)                      │        │
│  └─────────────────────────────────────────────────────┘        │
│           │                                                       │
│           │ 选中的服务器                                         │
│           ▼                                                       │
│  ┌─────────────────────────────────────────────────────┐        │
│  │         set_current_peer()                           │        │
│  │         设置代理目标                                 │        │
│  └─────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. 完整的执行时序

### 6.1 初始化阶段（Worker 启动）

```
1. init_worker()
   └─ healthcheck_manager.init_worker()
      ├─ 启动 timer_create_checker (每秒)
      └─ 启动 timer_working_pool_check (每秒)

2. 等待第一个请求到来
```

### 6.2 第一个请求（Access 阶段）

```
1. upstream.lua:set_upstream()
   └─ healthcheck_manager.fetch_checker(up_conf)
      ├─ working_pool 中没有 checker
      ├─ 加入 waiting_pool
      └─ 返回 nil

2. 继续处理请求（使用所有节点）
```

### 6.3 后台创建 Checker（1 秒内）

```
1. timer_create_checker() 被触发
   └─ 遍历 waiting_pool
      ├─ create_checker(up_conf)
      │  ├─ healthcheck.new()
      │  └─ checker:add_target() for each node
      ├─ 移到 working_pool
      └─ 删除 waiting_pool 条目

2. checker 启动主动健康检查定时器
   └─ 每 0.1 秒检查一次
      ├─ 建立 TCP 连接到上游节点
      ├─ 发送 HTTP 请求
      └─ 更新共享内存中的健康状态
```

### 6.4 后续请求（Balancer 阶段）

```
1. balancer.run()
   └─ pick_server()
      ├─ 获取 checker (从 working_pool)
      ├─ lrucache_server_picker.get()
      │  └─ create_server_picker()
      │     └─ fetch_health_nodes()
      │        ├─ checker:get_target_status() (读共享内存)
      │        └─ 过滤健康节点
      ├─ server_picker.get(ctx)
      │  └─ 调用具体算法 (roundrobin/chash/ewma/least_conn)
      └─ lrucache_addr.get() (解析地址)

2. set_current_peer()
   └─ balancer.set_current_peer(host, port)
      └─ 设置 Nginx 代理目标
```

### 6.5 请求失败重试

```
1. Nginx 检测到上游失败
   └─ 再次调用 balancer.run()

2. balancer_try_count > 1
   └─ 报告失败给 checker
      ├─ checker:report_timeout() 或
      ├─ checker:report_tcp_failure() 或
      └─ checker:report_http_status()
         └─ 更新共享内存计数器

3. 选择下一个服务器
   └─ server_picker.get(ctx)
      └─ 跳过已尝试的服务器
```

---

## 7. 关键文件索引

| 文件 | 作用 | 关键函数 |
|------|------|----------|
| [apisix/balancer.lua](apisix/balancer.lua) | 负载均衡主入口 | `_M.run()`, `pick_server()`, `fetch_health_nodes()` |
| [apisix/healthcheck_manager.lua](apisix/healthcheck_manager.lua) | 健康检查管理器 | `fetch_checker()`, `create_checker()`, `timer_create_checker()` |
| [apisix/upstream.lua](apisix/upstream.lua) | Upstream 管理 | `set_upstream()`, `init_worker()` |
| `deps/.../resty/healthcheck.lua` | 健康检查底层实现 | `new()`, `add_target()`, `get_target_status()`, `report_*()` |
| [apisix/cli/ngx_tpl.lua](apisix/cli/ngx_tpl.lua) | Nginx 配置模板 | 定义共享内存 |
| [apisix/core/lrucache.lua](apisix/core/lrucache.lua) | LRU 缓存实现 | `new()`, `get()`, `refresh_stale_objs()` |

---

## 8. 性能优化总结

### 8.1 零阻塞设计

| 操作 | 传统方式 | APISIX 方式 |
|------|----------|-------------|
| 健康检查 | 每次请求检查 | 后台异步检查 |
| 节点状态 | 实时查询 | 共享内存读取 |
| 负载均衡器 | 每次创建 | LRU 缓存复用 |
| 地址解析 | 每次解析 | LRU 缓存复用 |

### 8.2 内存使用

- **共享内存**: 10MB (`upstream-healthcheck`)
- **LRU 缓存**:
  - server_picker: 256 个对象
  - addr: 4096 个对象
- **每个 worker 独立**: LRU 缓存
- **所有 worker 共享**: 共享内存

### 8.3 时间复杂度

- **fetch_health_nodes**: O(n) - n 为节点数
- **server_picker.get**:
  - roundrobin: O(1)
  - chash: O(log n)
  - ewma: O(n)
  - least_conn: O(log n)
- **LRU 缓存查询**: O(1)
- **共享内存读取**: O(1)

---

## 9. 设计优势

✅ **高性能**: Balancer 阶段纯内存操作，无阻塞
✅ **高可用**: 健康检查失败不影响请求处理
✅ **可扩展**: 支持自定义负载均衡算法
✅ **资源高效**: 后台定时器共享，避免重复检查
✅ **状态一致**: 共享内存确保所有 worker 看到相同状态
✅ **优雅降级**: 所有节点不健康时使用全部节点

---

## 10. 相关文档

- [APISIX Balancer 流程图](apisix-balancer-flowchart.md)
- [负载均衡配置指南](docs/zh/latest/getting-started/load-balancing.md)
- [Upstream 术语](docs/en/latest/terminology/upstream.md)
- [健康检查配置](docs/en/latest/tutorials/health-check.md)
