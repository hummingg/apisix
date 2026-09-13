# Apache APISIX 项目目录结构

基于 Lua 和 OpenResty/Nginx 的高性能 API 网关。

## 主要目录

### `apisix/` - 核心代码

| 子目录 | 说明 |
|--------|------|
| `admin/` | Admin API 实现（路由、服务、上游、消费者等管理接口） |
| `balancer/` | 负载均衡策略（轮询、一致性哈希、最少连接等） |
| `cli/` | 命令行工具（启动、停止、重载等） |
| `control/` | 控制面 API |
| `core/` | 核心模块（配置、日志、DNS、JSON、schema 等） |
| `discovery/` | 服务发现（Consul、Nacos、Eureka、DNS 等） |
| `http/` | HTTP 相关功能 |
| `include/` | C 头文件 |
| `inspect/` | 调试检查工具 |
| `plugins/` | 121 个插件 |
| `pubsub/` | 发布订阅功能 |
| `secret/` | 密钥管理（Vault 等） |
| `ssl/` | SSL 证书管理 |
| `stream/` | TCP/UDP 流代理 |
| `utils/` | 工具函数（Redis、批处理等） |

### `conf/` - 配置

| 子目录/文件 | 说明 |
|-------------|------|
| `cert/` | SSL 证书目录 |
| `config.yaml` | 主配置文件 |
| `nginx.conf` | Nginx 配置模板 |

### `t/` - 测试

| 子目录 | 说明 |
|--------|------|
| `admin/` | Admin API 测试 |
| `plugin/` | 插件测试 |
| `core/` | 核心功能测试 |
| `cli/` | CLI 测试 |
| `router/` | 路由测试 |
| `stream-plugin/` | 流插件测试 |
| `discovery/` | 服务发现测试 |
| `wasm/` | WebAssembly 测试 |
| `node/` | 节点测试 |
| `lib/` | 测试库 |
| `certs/` | 测试证书 |
| `grpc_server_example/` | gRPC 测试服务 |
| `xrpc/` | xRPC 测试 |

### `docs/` - 文档

| 子目录 | 说明 |
|--------|------|
| `en/` | 英文文档 |
| `zh/` | 中文文档 |
| `assets/` | 文档资源 |

### `ci/` - CI/CD

| 子目录 | 说明 |
|--------|------|
| `pod/` | Pod 配置 |

### `docker/` - Docker

| 子目录 | 说明 |
|--------|------|
| `compose/` | Docker Compose 配置 |
| `debian-dev/` | Debian 开发镜像 |
| `utils/` | Docker 工具脚本 |

### `benchmark/` - 性能测试

| 子目录 | 说明 |
|--------|------|
| `fake-apisix/` | 模拟 APISIX 用于基准测试 |
| `server/` | 测试服务器 |

### 其他目录

| 目录 | 说明 |
|------|------|
| `bin/` | 可执行脚本入口 |
| `utils/` | 项目工具脚本 |
| `example/apisix/` | 示例配置 |
| `logos/` | 项目 Logo |
| `deps/` | 依赖（lib、share） |
| `logs/` | 日志目录 |

## 关键特性

- 插件化架构，支持热加载
- 多协议支持（HTTP、gRPC、MQTT、WebSocket、HTTP/3）
- RESTful Admin API 管理网关资源
- 内置 AI 网关能力（LLM 代理）

## 路由实现

### 架构概览

APISIX 使用基于 **Radixtree（基数树）** 的多层路由系统，支持可插拔的路由后端。

### 核心文件

| 文件 | 说明 |
|------|------|
| `apisix/router.lua` | 路由编排器，初始化和管理各类路由 |
| `apisix/http/route.lua` | HTTP 路由匹配逻辑 |
| `apisix/utils/router.lua` | Radixtree 封装工具 |
| `apisix/http/router/radixtree_uri.lua` | URI 路由（默认） |
| `apisix/http/router/radixtree_host_uri.lua` | Host + URI 路由 |
| `apisix/http/router/radixtree_uri_with_parameter.lua` | 带参数的 URI 路由 |

### 路由匹配流程

```
请求进入 → init.lua (HTTP Access 阶段)
    ↓
URI 规范化（去除尾部斜杠等）
    ↓
router.router_http.match(api_ctx)
    ↓
Radixtree 分发（dispatch）
    ↓
匹配成功 → 设置 api_ctx.matched_route
    ↓
合并插件/服务配置 → 执行插件 → 转发到上游
```

### 路由匹配实现

```lua
-- apisix/http/route.lua:106-117
function _M.match_uri(uri_router, api_ctx)
    local match_opts = core.tablepool.fetch("route_match_opts", 0, 4)
    match_opts.method = api_ctx.var.request_method
    match_opts.host = api_ctx.var.host
    match_opts.remote_addr = api_ctx.var.remote_addr
    match_opts.vars = api_ctx.var

    local ok = uri_router:dispatch(api_ctx.var.uri, match_opts, api_ctx)
    return ok
end
```

### 三种路由模式

1. **radixtree_uri**（默认）- 仅按 URI 匹配，性能最优
2. **radixtree_host_uri** - 两级匹配：Host → URI，支持无 Host 路由回退
3. **radixtree_uri_with_parameter** - 支持路径参数提取（如 `/users/{id}`）

### 路由定义结构

路由转换为 radixtree 兼容格式：
- `paths` - URI 模式
- `methods` - HTTP 方法
- `priority` - 优先级
- `hosts` - Host 头匹配
- `remote_addrs` - 客户端 IP
- `vars` - 自定义表达式条件
- `filter_fun` - 自定义过滤函数

### 性能优化

- **表池化**：复用 match_opts 等表对象
- **版本缓存**：路由仅在配置变更时重建
- **Radixtree**：O(k) 复杂度（k 为键长度，与路由数量无关）
- **LRU 缓存**：API 路由缓存

### 其他路由类型

- **SSL 路由** (`apisix/ssl/router/radixtree_sni.lua`) - 基于 SNI 匹配证书
- **Stream 路由** (`apisix/stream/router/ip_port.lua`) - TCP/UDP 按 IP/端口匹配

## AI 网关实现

APISIX 通过 AI 插件生态系统实现了向 AI 网关的转型。

### AI 插件列表

| 插件 | 优先级 | 功能 |
|------|--------|------|
| `ai-proxy` | 1040 | 核心 LLM 代理，支持 OpenAI、DeepSeek、Azure 等 |
| `ai-proxy-multi` | 1041 | 多 LLM 提供商负载均衡和故障转移 |
| `ai-rag` | 1060 | RAG 检索增强生成 |
| `ai-prompt-template` | 1071 | 预定义提示词模板 |
| `ai-prompt-decorator` | 1072 | 添加系统提示词（前置/后置） |
| `ai-prompt-guard` | 1072 | 提示词安全校验（正则白名单/黑名单） |
| `ai-request-rewrite` | 1073 | 请求重写（认证、模型选择） |
| `ai-rate-limiting` | - | 基于 Token 的限流 |
| `ai-aws-content-moderation` | - | AWS 内容审核 |

### AI 请求处理流程

```
客户端请求
    ↓
ai-prompt-template → 应用提示词模板
    ↓
ai-prompt-decorator → 添加系统提示词
    ↓
ai-prompt-guard → 提示词安全校验
    ↓
ai-rag → 检索增强（向量搜索 + 上下文注入）
    ↓
ai-proxy → 转换为 LLM 提供商格式，发送请求
    ↓
LLM 提供商（OpenAI/DeepSeek/Azure...）
    ↓
ai-rate-limiting → Token 限流
    ↓
返回客户端
```

### LLM 提供商驱动

位于 `apisix/plugins/ai-drivers/`：
- `openai.lua` - OpenAI
- `azure-openai.lua` - Azure OpenAI
- `deepseek.lua` - DeepSeek
- `openai-compatible.lua` - 通用 OpenAI 兼容 API

### 核心能力

- **提供商抽象** - 统一接口对接多个 LLM
- **流式响应** - SSE 支持实时 Token 流
- **多提供商故障转移** - 自动切换备用 LLM
- **Token 计量** - 跟踪 prompt_tokens、completion_tokens
- **安全防护** - 提示词校验、内容审核

### Token 限流策略

`ai-rate-limiting` 支持三种限流维度：
- `total_tokens` - 总 Token
- `prompt_tokens` - 输入 Token
- `completion_tokens` - 输出 Token

### Prometheus 指标

- `llm_latency` - LLM 响应延迟
- `llm_prompt_tokens` - 输入 Token 计数
- `llm_completion_tokens` - 输出 Token 计数
- `llm_active_connections` - 活跃连接数

### ai-request-rewrite 插件详解

该插件用 LLM 来重写客户端请求，将原始请求体发送给 LLM，根据配置的 prompt 进行转换，然后用 LLM 响应替换原始请求。

**配置 Schema**：

```lua
{
    prompt = "string",           -- 必填，指导 LLM 如何重写请求的提示词
    provider = "openai|deepseek|aimlapi|openai-compatible",  -- 必填
    auth = {                     -- 必填，认证信息
        header = { ["Authorization"] = "Bearer xxx" },
        query = { ["api-key"] = "xxx" }
    },
    options = { model = "gpt-3.5-turbo" },  -- 模型选项
    timeout = 30000,             -- 超时（毫秒）
    ssl_verify = true,
    override = { endpoint = "https://..." }  -- openai-compatible 必填
}
```

**工作流程**：

```
1. access 阶段获取客户端请求体
    ↓
2. 构造 LLM 请求：
   { messages: [
       { role: "system", content: conf.prompt },
       { role: "user", content: 原始请求体 }
   ]}
    ↓
3. 调用 ai-driver 发送请求到 LLM
    ↓
4. 解析 LLM 响应，提取 choices[0].message.content
    ↓
5. 返回重写后的请求给下游
```

**使用场景**：
- 请求格式转换
- 请求增强（补充缺失字段）
- 请求规范化
- 智能路由预处理

### 双 LLM 架构

ai-request-rewrite 和 ai-proxy 可以配置**不同的 LLM**：

```
客户端请求
    ↓
┌─────────────────────────────────────┐
│ ai-request-rewrite                  │
│ 调用 LLM-A（如 GPT-3.5）重写请求     │
└─────────────────────────────────────┘
    ↓
重写后的请求
    ↓
┌─────────────────────────────────────┐
│ ai-proxy                            │
│ 调用 LLM-B（如 GPT-4）处理业务请求   │
└─────────────────────────────────────┘
    ↓
最终响应
```

**配置示例**：

```yaml
plugins:
  - name: ai-request-rewrite
    config:
      provider: openai
      options:
        model: "gpt-3.5-turbo"  # 便宜模型做重写
      prompt: "规范化以下请求格式..."

  - name: ai-proxy
    config:
      provider: openai
      options:
        model: "gpt-4"  # 强模型做业务处理
```

分开配置的好处是可以按需选择不同模型，优化成本和性能。

### ai-proxy 的 Provider 和 Model 选择

**Provider 选择**：在路由配置中静态指定

```yaml
plugins:
  ai-proxy:
    provider: "openai"  # 必填，枚举值
    auth:
      header:
        Authorization: "Bearer sk-xxx"
```

支持的 provider：
- `openai`
- `deepseek`
- `aimlapi`
- `openai-compatible`
- `azure-openai`

**Model 选择**：有两个来源，配置优先

```lua
-- base.lua:79
local model = ai_instance.options.model or request_body.model
```

1. **配置优先**：`conf.options.model` - 路由配置中指定的模型
2. **请求兜底**：`request_body.model` - 客户端请求体中的模型

**示例**：

```yaml
plugins:
  ai-proxy:
    provider: openai
    options:
      model: "gpt-4"  # 强制使用 gpt-4，忽略客户端请求的模型
```

### ai-proxy-multi 多实例负载均衡

支持配置多个 LLM 实例，通过负载均衡和故障转移选择：

```yaml
plugins:
  ai-proxy-multi:
    balancer:
      algorithm: "roundrobin"  # 或 chash
    instances:
      - name: "openai-primary"
        provider: openai
        weight: 80
        priority: 0
        auth: { header: { Authorization: "Bearer sk-xxx" } }
        options: { model: "gpt-4" }
      - name: "deepseek-backup"
        provider: deepseek
        weight: 20
        priority: 1
        auth: { header: { Authorization: "Bearer xxx" } }
        options: { model: "deepseek-chat" }
    fallback_strategy: "http_5xx"  # 5xx 时切换到下一个实例
```

**选择逻辑**：
- `weight` - 权重，用于负载均衡
- `priority` - 优先级，用于故障转移
- `fallback_strategy` - 触发切换的条件（429、5xx 等）

## 配置 LLM 接口实战

以本地 Ollama（`http://127.0.0.1:11434`）为例，配置 APISIX 代理 LLM 接口。

### 1. 创建路由

```bash
curl http://127.0.0.1:9180/apisix/admin/routes/1 -X PUT \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -d '{
    "uri": "/v1/chat/completions",
    "plugins": {
      "ai-proxy": {
        "provider": "openai-compatible",
        "auth": {
          "header": {}
        },
        "options": {
          "model": "llama3.2"
        },
        "override": {
          "endpoint": "http://host.docker.internal:11434/v1/chat/completions"
        },
        "timeout": 60000,
        "ssl_verify": false
      }
    }
  }'
```

### 2. 客户端调用

```bash
curl http://127.0.0.1:9080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2",
    "max_tokens": 1000,
    "messages": [
        {"role": "system", "content": "你是一个得力助手。"},
        {"role": "user", "content": "你好"}
    ],
    "stream": false
  }'
```

### 3. 关键配置说明

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `provider` | `openai-compatible` | Ollama 兼容 OpenAI API |
| `override.endpoint` | 见下表 | **必填**，LLM 服务地址 |
| `auth.header` | `{}` | Ollama 本地无需认证 |
| `options.model` | `llama3.2` | 指定模型 |
| `ssl_verify` | `false` | 本地 HTTP 无需 SSL |
| `timeout` | `60000` | 本地模型响应慢，建议 60 秒 |

### 4. Docker 网络配置

APISIX 在 Docker 中时，访问宿主机服务需要特殊地址：

| 环境 | endpoint |
|------|----------|
| macOS/Windows Docker | `http://host.docker.internal:11434/v1/chat/completions` |
| Linux Docker | `http://172.17.0.1:11434/v1/chat/completions` |
| 本地直接运行 | `http://127.0.0.1:11434/v1/chat/completions` |

### 5. 常见问题排查

**Admin API 认证失败**：
```
{"description":"wrong apikey","error_msg":"failed to check token"}
```
- 检查 `conf/config.yaml` 中的 `admin_key`
- 默认 key：`edd1c9f034335f136f87ad84b625c8f1`

**500 Internal Server Error**：
```bash
# 查看错误日志
tail -100 logs/error.log | grep -i error
```

常见原因：
- Ollama 未启动
- Docker 网络不通（改用 `host.docker.internal`）
- ai-proxy 插件未启用

**启用插件**：检查 `conf/config.yaml`：
```yaml
plugins:
  - ai-proxy
  - ai-prompt-decorator
  # ...
```

重载配置：
```bash
apisix reload
```

### 6. Dashboard 看不到路由问题

**现象**：通过 Admin API 创建的路由在 Dashboard 中不显示。

**原因**：Dashboard 容器无法连接到 DevContainer 中的 etcd。`host.docker.internal` 在 Dashboard 容器内解析到 `127.0.0.1`，指向容器自身而非宿主机。

**解决方案**：将 Dashboard 连接到 DevContainer 网络

```bash
# 1. 查找 DevContainer 网络和 etcd 容器名
docker network ls | grep devcontainer
docker ps | grep etcd

# 2. 删除旧 Dashboard 容器
docker rm -f apisix-dashboard

# 3. 修改配置，使用 etcd 容器名
cat > /tmp/dashboard-conf.yaml << 'EOF'
conf:
  listen:
    host: 0.0.0.0
    port: 9000
  etcd:
    endpoints:
      - apisix_devcontainer-etcd-1:2379
  log:
    error_log:
      level: warn
      file_path: /dev/stderr
    access_log:
      file_path: /dev/stdout
authentication:
  secret: apisix-dashboard-secret-key-2024
  expire_time: 3600
  users:
    - username: admin
      password: admin
EOF

# 4. 启动 Dashboard 并连接到 DevContainer 网络
docker run -d \
  --name apisix-dashboard \
  --network apisix_devcontainer_default \
  -p 9000:9000 \
  -v /tmp/dashboard-conf.yaml:/usr/local/apisix-dashboard/conf/conf.yaml \
  apache/apisix-dashboard:3.0.1-alpine
```

**关键点**：
- `--network apisix_devcontainer_default` - 连接到 DevContainer 网络
- etcd 地址使用容器名 `apisix_devcontainer-etcd-1:2379`
- 容器间通过 Docker 网络直接通信

**验证**：
```bash
# 查看 Dashboard 日志
docker logs apisix-dashboard

# 访问 Dashboard
open http://localhost:9000
```
