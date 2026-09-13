# APISIX Consumer 机制详解

> 文档版本：1.0.0
> 创建日期：2026-03-30

## 一、什么是 Consumer

### 1.1 概念

**Consumer（消费者）** 是 APISIX 中用于表示 API 使用者的实体。可以理解为：
- **用户账号**：代表一个 API 的使用者
- **身份标识**：用于认证和授权
- **配置载体**：可以为不同用户配置不同的插件策略

### 1.2 为什么需要 Consumer

在没有 Consumer 的情况下，限流等策略只能基于：
- IP 地址（`remote_addr`）
- 请求路径（`uri`）
- 请求头（`http_*`）

但实际业务中，我们需要：
- ✅ 为不同用户设置不同的限流策略
- ✅ 为 VIP 用户提供更高的配额
- ✅ 跟踪用户的 API 使用情况
- ✅ 实现基于用户的认证和授权

**Consumer 就是为了解决这些问题而设计的。**

---

## 二、Consumer 的工作原理

### 2.1 架构流程

```
客户端请求
    ↓
携带认证凭证（API Key / JWT / Basic Auth 等）
    ↓
APISIX 认证插件（key-auth / jwt-auth / basic-auth）
    ↓
根据凭证查找对应的 Consumer
    ↓
将 Consumer 信息附加到 ctx 上下文
    ↓
后续插件（如 limit-count）可以使用 $consumer_name 变量
    ↓
转发到后端服务（携带 X-Consumer-Username 等头）
```

### 2.2 核心代码分析

#### 认证插件查找 Consumer

```lua
-- key-auth.lua:84
local consumer, consumer_conf, err = consumer_mod.find_consumer(
    plugin_name,  -- "key-auth"
    "key",        -- 查找字段名
    key           -- API Key 值
)
```

#### 将 Consumer 附加到上下文

```lua
-- key-auth.lua:119
consumer_mod.attach_consumer(ctx, consumer, consumer_conf)
```

#### attach_consumer 的实现

```lua
-- consumer.lua:212-221
function _M.attach_consumer(ctx, consumer, conf)
    -- 设置 Consumer 信息到 ctx
    ctx.consumer = consumer
    ctx.consumer_name = consumer.consumer_name
    ctx.consumer_group_id = consumer.group_id
    ctx.consumer_ver = conf.conf_version

    -- 设置请求头，转发到后端
    core.request.set_header(ctx, "X-Consumer-Username", consumer.username)
    core.request.set_header(ctx, "X-Credential-Identifier", consumer.credential_id)
    core.request.set_header(ctx, "X-Consumer-Custom-ID", consumer.custom_id)
end
```

---

## 三、$consumer_name 变量

### 3.1 什么是 $consumer_name

`$consumer_name` 是 APISIX 提供的内置变量，用于获取当前请求对应的 Consumer 名称。

**特点：**
- ✅ 只在 APISIX 内部使用
- ✅ 不会作为请求头转发到后端
- ✅ 可以在插件配置中使用（如 `key: "$consumer_name"`）
- ✅ 由认证插件自动设置

### 3.2 变量来源

```lua
-- consumer.lua:138
consumer.consumer_name = consumer.id
```

Consumer 的 `id` 字段（即创建 Consumer 时的 `username`）会被设置为 `consumer_name`。

### 3.3 可用的 Consumer 变量

| 变量名 | 说明 | 示例值 |
|--------|------|--------|
| `$consumer_name` | Consumer 的用户名 | `user123` |
| `$consumer_group_id` | Consumer 所属的组 ID | `vip-group` |

---

## 四、完整使用示例

### 4.1 创建 Consumer

#### 步骤 1：创建 Consumer

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "username": "user_vip",
    "desc": "VIP 用户"
  }'
```

#### 步骤 2：为 Consumer 配置认证插件

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers/user_vip/plugins \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "key-auth": {
      "key": "vip-api-key-123456"
    }
  }'
```

#### 步骤 3：创建普通用户

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "username": "user_normal",
    "desc": "普通用户"
  }'

curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers/user_normal/plugins \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "key-auth": {
      "key": "normal-api-key-789012"
    }
  }'
```

### 4.2 在路由上配置认证和限流

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "uri": "/api/*",
    "plugins": {
      "key-auth": {},
      "limit-count": {
        "count": 1000,
        "time_window": 60,
        "key": "$consumer_name",
        "key_type": "var",
        "policy": "local"
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "httpbin.org:80": 1
      }
    }
  }'
```

### 4.3 测试请求

#### VIP 用户请求

```bash
curl -H "apikey: vip-api-key-123456" http://127.0.0.1:9080/api/get
```

**限流 key：** `route_1:v1:user_vip`
**配额：** 1000 次/分钟

#### 普通用户请求

```bash
curl -H "apikey: normal-api-key-789012" http://127.0.0.1:9080/api/get
```

**限流 key：** `route_1:v1:user_normal`
**配额：** 1000 次/分钟（与 VIP 用户独立计数）

### 4.4 查看响应头

```bash
curl -i -H "apikey: vip-api-key-123456" http://127.0.0.1:9080/api/get
```

响应头：
```
HTTP/1.1 200 OK
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 999
X-RateLimit-Reset: 1711785660
X-Consumer-Username: user_vip
```

---

## 五、高级用法

### 5.1 为不同 Consumer 配置不同限流策略

#### 方式 1：使用多规则（推荐）

```json
{
  "plugins": {
    "key-auth": {},
    "limit-count": {
      "rules": [
        {
          "count": 10000,
          "time_window": 60,
          "key": "$consumer_name"
        }
      ],
      "policy": "redis",
      "redis_host": "127.0.0.1"
    }
  }
}
```

所有 Consumer 共享同一个限流配置，但每个 Consumer 有独立的计数器。

#### 方式 2：在 Consumer 上配置限流插件

```bash
# VIP 用户：10000 次/分钟
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers/user_vip/plugins \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "key-auth": {
      "key": "vip-api-key-123456"
    },
    "limit-count": {
      "count": 10000,
      "time_window": 60,
      "key": "$consumer_name",
      "policy": "local"
    }
  }'

# 普通用户：1000 次/分钟
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers/user_normal/plugins \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "key-auth": {
      "key": "normal-api-key-789012"
    },
    "limit-count": {
      "count": 1000,
      "time_window": 60,
      "key": "$consumer_name",
      "policy": "local"
    }
  }'
```

每个 Consumer 有独立的限流配置。

### 5.2 Consumer Group（消费者组）

APISIX 还支持 Consumer Group，可以为一组 Consumer 配置相同的插件：

```bash
# 创建 Consumer Group
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumer_groups/vip_group \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "plugins": {
      "limit-count": {
        "count": 10000,
        "time_window": 60,
        "key": "$consumer_name",
        "policy": "local"
      }
    }
  }'

# 将 Consumer 加入 Group
curl -X PUT http://127.0.0.1:9180/apisix/admin/consumers/user_vip \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -d '{
    "username": "user_vip",
    "group_id": "vip_group",
    "plugins": {
      "key-auth": {
        "key": "vip-api-key-123456"
      }
    }
  }'
```

### 5.3 结合其他变量使用

```json
{
  "plugins": {
    "key-auth": {},
    "limit-count": {
      "count": 1000,
      "time_window": 60,
      "key": "$consumer_name$uri",
      "key_type": "var_combination",
      "policy": "local"
    }
  }
}
```

限流 key 为：`user_vip/api/users`，实现按用户 + 路径的细粒度限流。

---

## 六、Consumer 与后端服务的集成

### 6.1 后端接收到的请求头

当请求通过认证后，APISIX 会自动添加以下请求头转发到后端：

```
X-Consumer-Username: user_vip
X-Credential-Identifier: vip-api-key-123456
X-Consumer-Custom-ID: custom_id_value
```

### 6.2 后端服务使用示例

```javascript
// Node.js 后端示例
app.get('/api/users', (req, res) => {
  const consumerName = req.headers['x-consumer-username'];
  const credentialId = req.headers['x-credential-identifier'];

  console.log(`请求来自用户: ${consumerName}`);
  console.log(`使用凭证: ${credentialId}`);

  // 根据用户身份返回不同的数据
  if (consumerName === 'user_vip') {
    res.json({ data: 'VIP 用户专属数据' });
  } else {
    res.json({ data: '普通数据' });
  }
});
```

### 6.3 隐藏凭证信息

如果不想将 API Key 转发到后端，可以使用 `hide_credentials` 选项：

```json
{
  "plugins": {
    "key-auth": {
      "hide_credentials": true
    }
  }
}
```

这样 `apikey` 请求头不会转发到后端，但 `X-Consumer-Username` 等头仍然会转发。

---

## 七、支持的认证插件

以下认证插件都支持 Consumer 机制：

| 插件名 | 认证方式 | 凭证位置 |
|--------|---------|---------|
| `key-auth` | API Key | 请求头或查询参数 |
| `jwt-auth` | JWT Token | 请求头或查询参数 |
| `basic-auth` | HTTP Basic Auth | Authorization 头 |
| `hmac-auth` | HMAC 签名 | 请求头 |
| `ldap-auth` | LDAP | Authorization 头 |
| `oauth2` | OAuth 2.0 | Authorization 头 |

---

## 八、最佳实践

### 8.1 限流策略设计

**推荐方式：**
```json
{
  "plugins": {
    "key-auth": {},
    "limit-count": {
      "count": 1000,
      "time_window": 60,
      "key": "$consumer_name",
      "policy": "redis",
      "redis_host": "127.0.0.1"
    }
  }
}
```

**优点：**
- ✅ 每个 Consumer 独立计数
- ✅ 配置简单，易于维护
- ✅ 支持分布式限流（Redis）
- ✅ 自动隔离不同用户的配额

### 8.2 安全建议

1. **使用强 API Key**：至少 32 位随机字符串
2. **启用 HTTPS**：防止 API Key 被窃取
3. **定期轮换凭证**：定期更新 API Key
4. **监控异常请求**：记录认证失败的请求
5. **使用 hide_credentials**：避免凭证泄露到后端日志

### 8.3 性能优化

1. **使用 LRU 缓存**：Consumer 信息会自动缓存
2. **选择合适的存储策略**：
   - 单机：使用 `local` 策略
   - 集群：使用 `redis` 或 `redis-cluster` 策略
3. **避免过多 Consumer**：建议单个 APISIX 实例管理的 Consumer 数量不超过 10000

---

## 九、常见问题

### Q1: Consumer 和 Route 的关系？

**答：** Consumer 和 Route 是独立的：
- **Route**：定义 API 路由和插件配置
- **Consumer**：定义 API 使用者和认证信息
- **关系**：Route 上配置认证插件后，请求必须携带有效的 Consumer 凭证才能访问

### Q2: 一个 Consumer 可以访问多个 Route 吗？

**答：** 可以。只要 Route 上配置了对应的认证插件，Consumer 就可以访问。

### Q3: $consumer_name 变量什么时候可用？

**答：** 只有在请求通过认证插件（如 key-auth）后，`$consumer_name` 变量才会被设置。如果请求未认证或认证失败，该变量为空。

### Q4: Consumer 信息存储在哪里？

**答：** Consumer 配置存储在 etcd 中，APISIX 启动时会加载到内存，并使用 LRU 缓存提高查询性能。

### Q5: 如何删除 Consumer？

```bash
curl -X DELETE http://127.0.0.1:9180/apisix/admin/consumers/user_vip \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1'
```

---

## 十、总结

**Consumer 机制的核心价值：**

1. ✅ **用户身份管理**：为每个 API 使用者创建独立的身份
2. ✅ **差异化策略**：为不同用户配置不同的限流、权限等策略
3. ✅ **安全认证**：支持多种认证方式（API Key、JWT、OAuth 等）
4. ✅ **使用追踪**：通过 `$consumer_name` 变量跟踪用户行为
5. ✅ **后端集成**：自动将用户信息传递给后端服务

**$consumer_name 变量的作用：**

- 🔑 在插件配置中引用当前用户名
- 🔑 实现基于用户的限流、日志、统计等功能
- 🔑 APISIX 内部变量，不会转发到后端
- 🔑 由认证插件自动设置，无需手动配置

---

## 参考资料

- [APISIX 官方文档 - Consumer](https://apisix.apache.org/docs/apisix/terminology/consumer/)
- [APISIX 官方文档 - key-auth](https://apisix.apache.org/docs/apisix/plugins/key-auth/)
- APISIX 源码：`apisix/consumer.lua`
- APISIX 源码：`apisix/plugins/key-auth.lua`
