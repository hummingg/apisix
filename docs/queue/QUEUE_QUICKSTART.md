# 快速开始指南

## 前置要求

- APISIX 已安装并运行
- Redis 已安装并运行
- Python 3.7+ (用于运行 Worker)

## 安装步骤

### 1. 安装 Python 依赖

```bash
pip3 install redis requests
```

### 2. 复制插件文件

```bash
# 确保插件文件在正确位置
ls -l apisix/plugins/queue-request.lua
ls -l apisix/plugins/queue-result.lua
```

### 3. 启用插件

编辑 `conf/config.yaml`，在 `plugins` 部分添加：

```yaml
plugins:
  - queue-request
  - queue-result
  # ... 其他插件
```

### 4. 重启 APISIX

```bash
apisix reload
# 或
apisix stop && apisix start
```

### 5. 配置路由

运行配置脚本：

```bash
# 提交任务路由
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -X PUT -d '
{
  "uri": "/api/task",
  "methods": ["POST"],
  "plugins": {
    "queue-request": {
      "redis_host": "127.0.0.1",
      "redis_port": 6379,
      "queue_name": "apisix:queue:requests",
      "result_ttl": 3600,
      "max_queue_size": 10000
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "httpbin.org:80": 1
    }
  }
}'

# 查询结果路由
curl http://127.0.0.1:9180/apisix/admin/routes/2 \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  -X PUT -d '
{
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

### 6. 启动 Worker

```bash
# 前台运行（用于测试）
python3 queue-worker.py

# 后台运行
nohup python3 queue-worker.py > worker.log 2>&1 &

# 查看日志
tail -f worker.log
```

## 测试

### 方式 1: 使用测试脚本

```bash
./test-queue-plugin.sh
```

### 方式 2: 手动测试

#### 1. 提交任务

```bash
curl -X POST http://127.0.0.1:9080/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "action": "test",
    "data": "hello world"
  }'
```

响应示例：
```json
{
  "request_id": "1234567890",
  "status": "queued",
  "message": "request has been queued for processing",
  "poll_url": "/apisix/admin/queue/result/1234567890"
}
```

#### 2. 查询结果

```bash
# 替换 {request_id} 为实际的 request_id
curl http://127.0.0.1:9080/api/task/{request_id}
```

处理中的响应：
```json
{
  "request_id": "1234567890",
  "status": "processing",
  "message": "request is still being processed"
}
```

完成后的响应：
```json
{
  "request_id": "1234567890",
  "status": "completed",
  "result": {
    "status_code": 200,
    "body": "..."
  },
  "timestamp": 1234567890
}
```

### 方式 3: 使用客户端代码

#### JavaScript/Node.js

```javascript
const axios = require('axios');

async function submitAndPoll() {
  // 提交任务
  const submitRes = await axios.post('http://localhost:9080/api/task', {
    action: 'test',
    data: 'hello'
  });

  const requestId = submitRes.data.request_id;
  console.log('Task submitted:', requestId);

  // 轮询结果
  for (let i = 0; i < 30; i++) {
    const queryRes = await axios.get(`http://localhost:9080/api/task/${requestId}`);

    if (queryRes.data.status === 'completed') {
      console.log('Task completed:', queryRes.data.result);
      return;
    }

    if (queryRes.data.status === 'failed') {
      console.error('Task failed:', queryRes.data.error);
      return;
    }

    await new Promise(resolve => setTimeout(resolve, 2000));
  }

  console.error('Timeout');
}

submitAndPoll();
```

#### Python

```python
import requests
import time

def submit_and_poll():
    # 提交任务
    response = requests.post('http://localhost:9080/api/task', json={
        'action': 'test',
        'data': 'hello'
    })
    request_id = response.json()['request_id']
    print(f'Task submitted: {request_id}')

    # 轮询结果
    for _ in range(30):
        response = requests.get(f'http://localhost:9080/api/task/{request_id}')
        result = response.json()

        if result['status'] == 'completed':
            print(f'Task completed: {result["result"]}')
            return

        if result['status'] == 'failed':
            print(f'Task failed: {result["error"]}')
            return

        time.sleep(2)

    print('Timeout')

submit_and_poll()
```

## 监控

### 查看队列状态

```bash
# 队列长度
redis-cli LLEN apisix:queue:requests

# 查看队列内容（不移除）
redis-cli LRANGE apisix:queue:requests 0 10

# 查看特定请求状态
redis-cli GET "apisix:queue:status:{request_id}"

# 查看特定请求结果
redis-cli GET "apisix:queue:result:{request_id}"
```

### 查看 Worker 日志

```bash
tail -f worker.log
```

### 查看 APISIX 日志

```bash
tail -f logs/error.log
```

## 故障排查

### 问题 1: 插件未生效

**检查**:
```bash
# 查看已加载的插件
curl http://127.0.0.1:9180/apisix/admin/plugins/list \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1'
```

**解决**:
- 确认 `conf/config.yaml` 中已添加插件
- 重启 APISIX: `apisix reload`

### 问题 2: Redis 连接失败

**检查**:
```bash
# 测试 Redis 连接
redis-cli ping
```

**解决**:
- 确认 Redis 正在运行: `redis-server --version`
- 检查 Redis 配置中的 host 和 port
- 检查防火墙设置

### 问题 3: Worker 无法处理请求

**检查**:
```bash
# 查看 Worker 进程
ps aux | grep queue-worker

# 查看 Worker 日志
tail -f worker.log
```

**解决**:
- 确认 Worker 正在运行
- 检查后端服务 URL 配置
- 查看日志中的错误信息

### 问题 4: 队列堆积

**检查**:
```bash
# 查看队列长度
redis-cli LLEN apisix:queue:requests
```

**解决**:
- 启动更多 Worker 实例
- 优化后端服务性能
- 增加 `max_queue_size` 限制

## 生产环境部署建议

### 1. 使用 Systemd 管理 Worker

创建 `/etc/systemd/system/apisix-queue-worker.service`:

```ini
[Unit]
Description=APISIX Queue Worker
After=network.target redis.service

[Service]
Type=simple
User=apisix
WorkingDirectory=/usr/local/apisix
ExecStart=/usr/bin/python3 /usr/local/apisix/queue-worker.py
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

### 2. 使用 Supervisor 管理 Worker

创建 `/etc/supervisor/conf.d/apisix-queue-worker.conf`:

```ini
[program:apisix-queue-worker]
command=/usr/bin/python3 /usr/local/apisix/queue-worker.py
directory=/usr/local/apisix
user=apisix
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/apisix/queue-worker.log
```

启动服务：
```bash
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start apisix-queue-worker
```

### 3. 运行多个 Worker 实例

```bash
# 方式 1: 直接启动多个进程
for i in {1..4}; do
  nohup python3 queue-worker.py > worker-$i.log 2>&1 &
done

# 方式 2: 使用 Supervisor 配置多个实例
[program:apisix-queue-worker]
command=/usr/bin/python3 /usr/local/apisix/queue-worker.py
process_name=%(program_name)s_%(process_num)02d
numprocs=4
```

### 4. 配置 Redis 持久化

编辑 `redis.conf`:

```conf
# 启用 AOF
appendonly yes
appendfsync everysec

# 启用 RDB
save 900 1
save 300 10
save 60 10000
```

### 5. 监控和告警

- 使用 Prometheus + Grafana 监控队列长度
- 配置告警规则（队列长度、Worker 健康状态）
- 记录详细日志用于问题排查

## 下一步

- 阅读完整设计文档: [QUEUE_REQUEST_DESIGN.md](QUEUE_REQUEST_DESIGN.md)
- 根据实际需求调整配置参数
- 实现自定义的后端处理逻辑
- 添加监控和告警
