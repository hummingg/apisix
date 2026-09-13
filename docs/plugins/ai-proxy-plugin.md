# APISIX ai-proxy 插件介绍

## 核心功能

ai-proxy 是 APISIX 的 AI 代理插件，用于将请求转发到各种 AI 大模型服务（如 OpenAI、DeepSeek、Azure OpenAI 等）。

## 架构组成

```
apisix/plugins/
├── ai-proxy.lua              # 单 Provider 插件入口
├── ai-proxy-multi.lua        # 多 Provider (负载均衡)
├── ai-proxy/
│   ├── schema.lua            # 配置 Schema
│   └── base.lua              # 共享的请求处理逻辑
└── ai-drivers/
    ├── openai-base.lua       # 基类，所有驱动继承它
    ├── openai.lua            # OpenAI 驱动
    ├── deepseek.lua          # DeepSeek 驱动
    ├── azure-openai.lua      # Azure OpenAI 驱动
    └── sse.lua               # SSE 流式响应解析
```

## 支持的 AI Provider

| Provider | 驱动文件 | 默认 Endpoint |
|----------|---------|---------------|
| OpenAI | `openai.lua` | `https://api.openai.com/v1/chat/completions` |
| DeepSeek | `deepseek.lua` | `https://api.deepseek.com/chat/completions` |
| Azure OpenAI | `azure-openai.lua` | 自定义 endpoint |
| AIMLAPI | `aimlapi.lua` | `https://api.aimlapi.com/chat/completions` |
| OpenAI-Compatible | `openai-compatible.lua` | 可配置 |

## 实现原理

### 1. 驱动工厂模式

所有 AI Provider 驱动都继承 `openai-base.lua` 基类：

```lua
-- deepseek.lua 示例
return require("apisix.plugins.ai-drivers.openai-base").new({
    host = "api.deepseek.com",
    path = "/chat/completions",
    port = 443
})
```

### 2. 插件生命周期

```lua
local _M = {
    version = 0.5,
    priority = 1040,
    name = "ai-proxy",
    schema = schema.ai_proxy_schema,
}

function _M.check_schema(conf)   -- 校验配置
function _M.access(conf, ctx)    -- 设置上下文，选择 AI 实例
function _M.before_proxy(conf, ctx) -- 请求转换
function _M.log(conf, ctx)       -- 日志记录
```

### 3. 请求处理流程

```
User Request
    ↓
access() → 设置 ctx.picked_ai_instance
    ↓
before_proxy() → base.before_proxy()
    ↓
校验请求 (JSON content-type, 解析 body)
    ↓
构建带认证的请求头/参数
    ↓
合并 model options 到请求体
    ↓
POST 到 AI provider endpoint
    ↓
读取响应 (SSE 流式 或 JSON)
    ↓
提取 token usage 和响应内容
    ↓
设置 context variables 用于日志
    ↓
返回响应给客户端
    ↓
log() → 记录 summary/payload
```

### 4. 响应处理

支持两种响应格式：

- **SSE 流式** (`text/event-stream`): 逐行解析 SSE 事件，提取 token usage
- **JSON**: 标准非流式响应，直接解析

```lua
-- Token 统计
ctx.ai_token_usage = {
    prompt_tokens = data.usage.prompt_tokens or 0,
    completion_tokens = data.usage.completion_tokens or 0,
    total_tokens = data.usage.total_tokens or 0,
}
```

## 关键特性

### 认证处理

- **Header 认证**: `auth.header` - 如 `{"authorization": "Bearer <token>"}`
- **Query 认证**: `auth.query` - 如 `{"apikey": "<token>"}`

### 流式支持

- 检测请求中的 `stream: true`
- 自动添加 `stream_options: { include_usage: true }` 用于 token 统计
- 使用 `sse.lua` 解析 SSE 事件

### 负载均衡 (ai-proxy-multi)

- **Roundrobin**: 轮询选择
- **Consistent Hash (chash)**: 一致性哈希，同一客户端路由到同一 provider
- **优先级**: 优先使用高优先级实例，失败后 fallback

### 健康检查

- 集成 APISIX 健康检查机制
- 支持主动健康检查配置
- 自动 fallback 到健康实例

### 日志与指标

- **Summary 日志**: model, duration, token counts
- **Payload 日志**: 完整请求/响应体
- **Context 变量** (可用于 access log):
  - `llm_model`
  - `llm_prompt_tokens`
  - `llm_completion_tokens`
  - `llm_time_to_first_token`
  - `llm_response_text`

## 配置示例

### 单 Provider (ai-proxy)

```json
{
    "provider": "openai",
    "auth": {
        "header": {
            "authorization": "Bearer sk-xxx"
        }
    },
    "options": {
        "model": "gpt-4",
        "temperature": 0.7,
        "stream": true
    },
    "timeout": 30000,
    "ssl_verify": true,
    "logging": {
        "summaries": true,
        "payloads": false
    }
}
```

### 多 Provider (ai-proxy-multi)

```json
{
    "instances": [
        {
            "name": "openai-primary",
            "provider": "openai",
            "weight": 10,
            "priority": 0,
            "auth": { "header": { "authorization": "Bearer sk-xxx" } },
            "options": { "model": "gpt-4" }
        },
        {
            "name": "deepseek-backup",
            "provider": "deepseek",
            "weight": 5,
            "priority": 1,
            "auth": { "header": { "authorization": "Bearer ds-xxx" } },
            "options": { "model": "deepseek-chat" }
        }
    ],
    "balancer": {
        "algorithm": "roundrobin"
    },
    "fallback_strategy": "instance_health_and_rate_limiting"
}
```

## 错误处理

- **HTTP 429 (Rate Limited)**: 使用 fallback 实例重试
- **HTTP 5xx**: 使用 fallback 实例重试
- **连接超时**: 返回 504 Gateway Timeout
- **无效 Provider**: schema 校验时返回 400
