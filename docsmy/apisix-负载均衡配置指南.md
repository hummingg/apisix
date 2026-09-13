# APISIX 负载均衡配置与实现指南

## 目录

1. [配置方式](#1-配置方式)
2. [支持的负载均衡算法](#2-支持的负载均衡算法)
3. [核心实现逻辑](#3-核心实现逻辑)
4. [配置示例](#4-配置示例)
5. [高级特性](#5-高级特性)

---

## 1. 配置方式

### 1.1 核心配置文件

**Schema 定义**：
- [apisix/schema_def.lua](apisix/schema_def.lua) - 定义 upstream 的配置 schema
- [conf/config.yaml](conf/config.yaml) - APISIX 主配置文件

### 1.2 通过 Admin API 配置

**基本配置结构**：
```json
{
  "type": "roundrobin",           // 负载均衡算法类型
  "nodes": {                       // 上游节点列表
    "127.0.0.1:1980": 1,          // 节点地址:权重
    "127.0.0.1:1981": 2
  },
  "hash_on": "vars",              // 哈希键类型（chash 算法用）
  "key": "remote_addr",           // 哈希键名称
  "checks": {                     // 健康检查配置
    "active": {
      "http_path": "/status",
      "healthy": {
        "interval": 2,
        "successes": 1
      }
    }
  },
  "retries": 2,                   // 重试次数
  "timeout": {                    // 超时配置
    "connect": 6,
    "send": 6,
    "read": 6
  }
}
```

### 1.3 关键配置参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `type` | string | "roundrobin" | 负载均衡算法类型 |
| `nodes` | object/array | - | 上游节点列表（IP:端口 + 权重）|
| `hash_on` | string | "vars" | 哈希键类型（chash 用）|
| `key` | string | - | 哈希键名称 |
| `checks` | object | - | 健康检查配置 |
| `retries` | integer | nodes-1 | 重试次数 |
| `retry_timeout` | number | 0 | 重试超时时间（秒）|
| `timeout` | object | - | 连接/发送/读取超时 |
| `keepalive_pool` | object | - | 连接池配置 |
| `scheme` | string | "http" | 协议类型 |
| `pass_host` | string | "pass" | Host 头传递方式 |

---

## 2. 支持的负载均衡算法

APISIX 支持 **5 种**负载均衡策略：

### 2.1 roundrobin（加权轮询）

**实现文件**：[apisix/balancer/roundrobin.lua](apisix/balancer/roundrobin.lua)

**特点**：
- 使用 `resty.roundrobin` 库实现
- 按权重比例循环分配请求
- 适用于节点性能相近的场景

**配置示例**：
```json
{
  "type": "roundrobin",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 2,
    "127.0.0.1:1982": 3
  }
}
```

**权重说明**：
- 权重为 1:2:3 时，请求分配比例为 1:2:3
- 权重越大，分配的请求越多

### 2.2 chash（一致性哈希）

**实现文件**：[apisix/balancer/chash.lua](apisix/balancer/chash.lua)

**特点**：
- 使用 `resty.chash` 库，支持 160 个虚拟节点
- 基于请求特征哈希到固定节点
- 保证相同特征的请求路由到同一节点
- 适用于需要会话保持的场景

**支持的 hash_on 类型**：

| hash_on 类型 | 说明 | key 示例 |
|--------------|------|----------|
| `vars` | Nginx 变量 | `remote_addr`, `uri`, `request_uri` |
| `header` | HTTP 请求头 | `X-User-ID`, `Authorization` |
| `cookie` | Cookie 值 | `session_id`, `user_token` |
| `consumer` | 认证的消费者名称 | - |
| `vars_combinations` | 多个变量组合 | `["remote_addr", "uri"]` |

**配置示例 1 - 基于客户端 IP**：
```json
{
  "type": "chash",
  "key": "remote_addr",
  "hash_on": "vars",
  "nodes": {
    "127.0.0.1:80": 1,
    "httpbin.org:80": 2
  }
}
```

**配置示例 2 - 基于请求头**：
```json
{
  "type": "chash",
  "key": "X-User-ID",
  "hash_on": "header",
  "nodes": {
    "192.168.1.10:8080": 1,
    "192.168.1.11:8080": 1
  }
}
```

**配置示例 3 - 基于 Cookie**：
```json
{
  "type": "chash",
  "key": "session_id",
  "hash_on": "cookie",
  "nodes": {
    "192.168.1.10:8080": 1,
    "192.168.1.11:8080": 1
  }
}
```

**配置示例 4 - 基于多个变量组合**：
```json
{
  "type": "chash",
  "key": ["remote_addr", "uri"],
  "hash_on": "vars_combinations",
  "nodes": {
    "192.168.1.10:8080": 1,
    "192.168.1.11:8080": 1
  }
}
```

### 2.3 ewma（指数加权移动平均）

**实现文件**：[apisix/balancer/ewma.lua](apisix/balancer/ewma.lua)

**特点**：
- 基于 Twitter Finagle 的 Peak EWMA 算法
- 选择延迟最小的节点
- 使用指数衰减计算平均响应时间
- 适用于节点性能差异较大的场景

**核心参数**：
- `DECAY_TIME = 10` 秒（衰减时间）
- 使用共享内存存储 EWMA 值和最后访问时间

**算法公式**：
```lua
ewma = ewma * weight + rtt * (1.0 - weight)
-- weight = exp(-td / DECAY_TIME)
-- td = 当前时间 - 最后更新时间
-- rtt = 本次请求的响应时间
```

**配置示例**：
```json
{
  "type": "ewma",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 1,
    "127.0.0.1:1982": 1
  }
}
```

**工作原理**：
1. 每次请求记录响应时间（RTT）
2. 使用指数衰减更新节点的 EWMA 值
3. 选择 EWMA 值最小的节点（延迟最低）
4. 自动适应节点性能变化

### 2.4 least_conn（最少连接）

**实现文件**：[apisix/balancer/least_conn.lua](apisix/balancer/least_conn.lua)

**特点**：
- 使用二叉堆（binaryheap）维护节点得分
- 选择 `(活跃连接数 + 1) / 权重` 值最小的节点
- 适用于长连接场景

**算法逻辑**：
```lua
-- 节点得分计算
score = (active_connections + 1) / weight

-- 选择得分最低的节点
selected_node = min_heap.pop()

-- 请求开始：增加得分
node.score = node.score + (1 / weight)

-- 请求结束：减少得分
node.score = node.score - (1 / weight)
```

**配置示例**：
```json
{
  "type": "least_conn",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 2,
    "127.0.0.1:1982": 3
  }
}
```

**适用场景**：
- WebSocket 连接
- 长轮询（Long Polling）
- 流式传输
- 数据库连接池

### 2.5 自定义负载均衡器

**扩展方式**：
```lua
-- 创建自定义负载均衡器
-- apisix/balancer/my_balancer.lua
local _M = {}

function _M.new(nodes, upstream)
    local picker = {
        upstream = upstream,
    }

    function picker.get(ctx)
        -- 实现自定义选择逻辑
        return selected_server
    end

    function picker.after_balance(ctx, before_retry)
        -- 请求后处理逻辑
    end

    return picker
end

return _M
```

**使用自定义负载均衡器**：
```json
{
  "type": "my_balancer",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 1
  }
}
```

---

## 3. 核心实现逻辑

### 3.1 动态加载算法

**实现位置**：[apisix/balancer.lua:98-132](apisix/balancer.lua#L98-L132)

```lua
local function create_server_picker(upstream, checker)
    -- 动态加载负载均衡算法模块
    local picker = pickers[upstream.type]
    if not picker then
        pickers[upstream.type] = require("apisix.balancer." .. upstream.type)
        picker = pickers[upstream.type]
    end

    -- 获取健康节点
    local up_nodes = fetch_health_nodes(upstream, checker)

    -- 根据优先级数量选择负载均衡器
    if #up_nodes._priority_index > 1 then
        -- 多优先级：使用优先级负载均衡器
        return priority_balancer.new(up_nodes, upstream, picker)
    else
        -- 单优先级：使用简单负载均衡器
        return picker.new(up_nodes[up_nodes._priority_index[1]], upstream)
    end
end
```

### 3.2 节点选择流程

**实现位置**：[apisix/balancer.lua:194-267](apisix/balancer.lua#L194-L267)

```lua
local function pick_server(route, ctx)
    local up_conf = ctx.upstream_conf

    -- 1. 单节点直接返回
    if #up_conf.nodes == 1 then
        return up_conf.nodes[1]
    end

    -- 2. 获取或创建 server_picker（使用 LRU 缓存）
    local server_picker = lrucache_server_picker(key, version,
                                                 create_server_picker, up_conf, checker)

    -- 3. 调用算法选择服务器
    local server, err = server_picker.get(ctx)

    -- 4. 解析地址（使用 LRU 缓存）
    local res = lrucache_addr(server, nil, parse_addr, server)

    -- 5. 设置上下文
    ctx.balancer_ip = res.host
    ctx.balancer_port = res.port
    ctx.server_picker = server_picker

    return res
end
```

### 3.3 健康检查集成

**实现位置**：[apisix/balancer.lua:63-95](apisix/balancer.lua#L63-L95)

```lua
local function fetch_health_nodes(upstream, checker)
    if not checker then
        -- 无健康检查，返回所有节点
        return all_nodes
    end

    -- 过滤健康节点
    for _, node in ipairs(nodes) do
        local ok = healthcheck_manager.fetch_node_status(checker,
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

### 3.4 重试机制

**实现位置**：[apisix/balancer.lua:216-229](apisix/balancer.lua#L216-L229)

```lua
-- 重试时报告失败状态
if ctx.balancer_try_count > 1 then
    if checker then
        local state, code = get_last_failure()

        if state == "failed" then
            if code == 504 then
                checker:report_timeout(ctx.balancer_ip, port, host)
            else
                checker:report_tcp_failure(ctx.balancer_ip, port, host)
            end
        else
            checker:report_http_status(ctx.balancer_ip, port, host, code)
        end
    end
end
```

### 3.5 连接池管理

**实现位置**：[apisix/balancer.lua:279-331](apisix/balancer.lua#L279-L331)

```lua
function set_current_peer(server, ctx)
    if enable_keepalive then
        -- 配置连接池
        pool_opt.pool_size = keepalive_pool.size

        -- 构建连接池键
        local pool = scheme .. "#" .. server.host .. "#" .. server.port

        -- HTTPS/gRPCS 需要包含 SNI
        if scheme == "https" or scheme == "grpcs" then
            pool = pool .. "#" .. ctx.var.upstream_host

            -- mTLS 需要包含客户端证书
            if up_conf.tls and up_conf.tls.client_cert then
                pool = pool .. "#" .. up_conf.tls.client_cert
            end
        end

        pool_opt.pool = pool

        -- 设置对等节点并启用 keepalive
        balancer.set_current_peer(server.host, server.port, pool_opt)
        return balancer.enable_keepalive(idle_timeout, requests)
    end

    -- 不使用 keepalive
    return balancer.set_current_peer(server.host, server.port)
end
```

---

## 4. 配置示例

### 4.1 基本配置

**创建 Upstream**：
```bash
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "type": "roundrobin",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 2
  }
}'
```

**创建 Route 并关联 Upstream**：
```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "uri": "/api/*",
  "upstream_id": 1
}'
```

### 4.2 带健康检查的配置

```bash
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "type": "roundrobin",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 1
  },
  "checks": {
    "active": {
      "type": "http",
      "http_path": "/status",
      "healthy": {
        "interval": 2,
        "successes": 1
      },
      "unhealthy": {
        "interval": 1,
        "http_failures": 2
      }
    },
    "passive": {
      "healthy": {
        "http_statuses": [200, 201],
        "successes": 3
      },
      "unhealthy": {
        "http_statuses": [500, 502, 503, 504],
        "http_failures": 3,
        "tcp_failures": 3
      }
    }
  }
}'
```

### 4.3 一致性哈希配置（会话保持）

```bash
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "type": "chash",
  "key": "remote_addr",
  "hash_on": "vars",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 1,
    "127.0.0.1:1982": 1
  }
}'
```

### 4.4 优先级负载均衡

```bash
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "type": "roundrobin",
  "nodes": [
    {"host": "127.0.0.1", "port": 1980, "weight": 1, "priority": 0},
    {"host": "127.0.0.1", "port": 1981, "weight": 1, "priority": 0},
    {"host": "127.0.0.1", "port": 1982, "weight": 1, "priority": 1}
  ]
}'
```

**优先级说明**：
- `priority` 值越小，优先级越高
- 只有当高优先级节点全部不健康时，才会使用低优先级节点
- 适用于主备切换场景

### 4.5 带重试和超时的配置

```bash
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "type": "roundrobin",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 1
  },
  "retries": 2,
  "retry_timeout": 0.5,
  "timeout": {
    "connect": 6,
    "send": 6,
    "read": 6
  }
}'
```

### 4.6 连接池配置

```bash
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
-H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' -X PUT -d '
{
  "type": "roundrobin",
  "nodes": {
    "127.0.0.1:1980": 1,
    "127.0.0.1:1981": 1
  },
  "keepalive_pool": {
    "size": 320,
    "idle_timeout": 60,
    "requests": 1000
  }
}'
```

---

## 5. 高级特性

### 5.1 服务发现集成

APISIX 支持与多种服务发现系统集成：

**Consul**：
```json
{
  "service_name": "my-service",
  "discovery_type": "consul",
  "type": "roundrobin"
}
```

**Eureka**：
```json
{
  "service_name": "MY-SERVICE",
  "discovery_type": "eureka",
  "type": "roundrobin"
}
```

**Nacos**：
```json
{
  "service_name": "my-service",
  "discovery_type": "nacos",
  "type": "roundrobin"
}
```

### 5.2 Pass Host 配置

控制如何传递 Host 头到上游：

| pass_host 值 | 说明 |
|--------------|------|
| `pass` | 透传客户端的 Host 头（默认）|
| `node` | 使用上游节点的地址作为 Host |
| `rewrite` | 使用指定的值重写 Host |

**示例**：
```json
{
  "type": "roundrobin",
  "nodes": {
    "127.0.0.1:1980": 1
  },
  "pass_host": "rewrite",
  "upstream_host": "api.example.com"
}
```

### 5.3 TLS/mTLS 配置

**客户端证书认证**：
```json
{
  "type": "roundrobin",
  "scheme": "https",
  "nodes": {
    "127.0.0.1:1980": 1
  },
  "tls": {
    "client_cert": "-----BEGIN CERTIFICATE-----\n...",
    "client_key": "-----BEGIN PRIVATE KEY-----\n..."
  }
}
```

### 5.4 负载均衡算法对比

| 算法 | 适用场景 | 优点 | 缺点 |
|------|----------|------|------|
| **roundrobin** | 通用场景 | 简单、高效 | 不考虑节点负载 |
| **chash** | 会话保持 | 请求固定路由 | 节点变化影响较大 |
| **ewma** | 性能差异大 | 自动适应性能 | 需要响应时间统计 |
| **least_conn** | 长连接 | 负载均衡好 | 需要维护连接状态 |

### 5.5 性能调优建议

**LRU 缓存调优**：
```lua
-- apisix/balancer.lua
local lrucache_server_picker = core.lrucache.new({
    ttl = 300,    -- 根据 upstream 变更频率调整
    count = 256   -- 根据 upstream 数量调整
})
```

**连接池调优**：
```json
{
  "keepalive_pool": {
    "size": 320,           // 根据并发量调整
    "idle_timeout": 60,    // 根据上游超时策略调整
    "requests": 1000       // 根据连接复用需求调整
  }
}
```

**健康检查调优**：
```json
{
  "checks": {
    "active": {
      "healthy": {
        "interval": 2,      // 检查间隔，越小越及时
        "successes": 1      // 成功次数，越小恢复越快
      },
      "unhealthy": {
        "interval": 1,      // 检查间隔
        "http_failures": 2  // 失败次数，越小隔离越快
      }
    }
  }
}
```

---

## 6. 相关文档

- [APISIX Balancer 流程图](apisix-balancer-flowchart.md)
- [APISIX Balancer 设计原理](apisix-balancer-设计原理.md)
- [负载均衡配置指南（官方）](docs/zh/latest/getting-started/load-balancing.md)
- [Upstream 术语](docs/en/latest/terminology/upstream.md)
- [健康检查配置](docs/en/latest/tutorials/health-check.md)

---

## 7. 常见问题

### Q1: 如何选择合适的负载均衡算法？

**决策树**：
```
需要会话保持？
├─ 是 → chash（一致性哈希）
└─ 否 → 节点性能差异大？
    ├─ 是 → ewma（指数加权移动平均）
    └─ 否 → 长连接场景？
        ├─ 是 → least_conn（最少连接）
        └─ 否 → roundrobin（轮询）
```

### Q2: 健康检查失败后多久恢复？

取决于 `checks.active.healthy.interval` 和 `successes` 配置：
- 恢复时间 = `interval × successes`
- 例如：`interval=2, successes=1` → 2 秒后恢复

### Q3: 如何实现灰度发布？

使用权重配置：
```json
{
  "nodes": {
    "old-version:8080": 9,  // 90% 流量
    "new-version:8080": 1   // 10% 流量
  }
}
```

### Q4: 如何实现主备切换？

使用优先级配置：
```json
{
  "nodes": [
    {"host": "primary", "port": 8080, "priority": 0},
    {"host": "backup", "port": 8080, "priority": 1}
  ]
}
```

### Q5: 负载均衡器何时重新创建？

当以下情况发生时，LRU 缓存失效，重新创建：
- Upstream 配置变更（版本号变化）
- 健康检查状态变更（status_ver 变化）
- 缓存 TTL 过期（默认 300 秒）
