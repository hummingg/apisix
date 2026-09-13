# APISIX 队列插件示例

本目录包含 APISIX 队列插件的 Worker 实现和测试工具。

## 📁 文件说明

### Worker 实现

#### queue-worker.py（推荐）
Python 版本的队列处理 Worker，功能完整，易于扩展。

**功能特性：**
- 从 Redis 队列取出请求
- 调用后端服务处理
- 更新处理状态和结果
- 支持错误处理和重连

**使用方法：**
```bash
# 安装依赖
pip3 install redis requests

# 启动 Worker
python3 queue-worker.py

# 后台运行
nohup python3 queue-worker.py > worker.log 2>&1 &
```

**配置参数：**
```python
CONFIG = {
    'redis_host': '127.0.0.1',
    'redis_port': 6379,
    'redis_password': None,
    'redis_db': 0,
    'queue_name': 'apisix:queue:requests',
    'backend_url': 'http://127.0.0.1:8080/api/process',
    'poll_interval': 1,  # 秒
    'request_timeout': 30,  # 秒
    'result_ttl': 3600,  # 秒
}
```

#### queue-worker.lua（可选）
Lua 版本的队列处理 Worker，适合 OpenResty 环境。

**使用方法：**
```bash
# 使用 OpenResty 运行
openresty -p /path/to/workspace -c queue-worker.lua
```

### 测试工具

#### test-backend-server.py
简单的 HTTP 测试服务器，用于模拟后端服务。

**功能：**
- 监听 8080 端口
- 接收 POST 请求
- 返回处理结果
- 模拟 1 秒处理时间

**使用方法：**
```bash
# 启动测试服务器
python3 test-backend-server.py

# 后台运行
nohup python3 test-backend-server.py > backend.log 2>&1 &

# 测试
curl -X POST http://127.0.0.1:8080/api/process \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'
```

## 🚀 快速开始

### 1. 启动所有服务

```bash
# 启动 Redis
redis-server --daemonize yes

# 启动 APISIX
make init && make run

# 启动测试后端服务
cd examples/queue
nohup python3 test-backend-server.py > backend.log 2>&1 &

# 启动 Worker
nohup python3 queue-worker.py > worker.log 2>&1 &
```

### 2. 配置路由

```bash
# 提交任务路由
curl http://127.0.0.1:9180/apisix/admin/routes/queue-submit \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -X PUT -d '{
  "uri": "/api/task",
  "methods": ["POST"],
  "plugins": {
    "queue-request": {
      "redis_host": "127.0.0.1",
      "redis_port": 6379
    }
  }
}'

# 查询结果路由
curl http://127.0.0.1:9180/apisix/admin/routes/queue-query \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -X PUT -d '{
  "uri": "/api/task/*",
  "methods": ["GET"],
  "plugins": {
    "queue-result": {
      "redis_host": "127.0.0.1",
      "redis_port": 6379
    }
  }
}'
```

### 3. 测试

```bash
# 提交任务
curl -X POST http://127.0.0.1:9080/api/task \
  -H "Content-Type: application/json" \
  -d '{"action": "test", "data": "hello"}'

# 查询结果（替换 {request_id}）
curl http://127.0.0.1:9080/api/task/{request_id}
```

## 📊 监控

### 查看日志

```bash
# Worker 日志
tail -f worker.log

# 后端服务日志
tail -f backend.log

# APISIX 日志
tail -f ../../logs/error.log
```

### 查看队列状态

```bash
# 队列长度
redis-cli LLEN apisix:queue:requests

# 查看队列内容
redis-cli LRANGE apisix:queue:requests 0 10

# 查看请求状态
redis-cli GET "apisix:queue:status:{request_id}"

# 查看请求结果
redis-cli GET "apisix:queue:result:{request_id}"
```

## 🔧 生产环境部署

### 使用 Systemd 管理 Worker

创建 `/etc/systemd/system/apisix-queue-worker.service`：

```ini
[Unit]
Description=APISIX Queue Worker
After=network.target redis.service

[Service]
Type=simple
User=apisix
WorkingDirectory=/usr/local/apisix/examples/queue
ExecStart=/usr/bin/python3 /usr/local/apisix/examples/queue/queue-worker.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启动服务：
```bash
sudo systemctl daemon-reload
sudo systemctl enable apisix-queue-worker
sudo systemctl start apisix-queue-worker
sudo systemctl status apisix-queue-worker
```

### 运行多个 Worker 实例

```bash
# 方式 1: 直接启动多个进程
for i in {1..4}; do
  nohup python3 queue-worker.py > worker-$i.log 2>&1 &
done

# 方式 2: 使用 Supervisor
# 在 /etc/supervisor/conf.d/apisix-queue-worker.conf 中配置
[program:apisix-queue-worker]
command=/usr/bin/python3 /usr/local/apisix/examples/queue/queue-worker.py
process_name=%(program_name)s_%(process_num)02d
numprocs=4
```

## 📖 更多文档

- [完整文档](../../docs/queue/README.md)
- [快速开始指南](../../docs/queue/QUEUE_QUICKSTART.md)
- [架构设计](../../docs/queue/QUEUE_ARCHITECTURE.md)
- [测试脚本](../../t/queue/)
