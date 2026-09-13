# APISIX 队列插件测试

本目录包含 APISIX 队列插件的测试脚本和工具。

## 📁 测试脚本

### test-queue-plugin.sh
完整的自动化测试脚本，测试插件的所有功能。

**功能：**
- 配置测试路由
- 提交测试任务
- 查询任务状态
- 验证 Redis 数据
- 检查处理结果

**使用方法：**
```bash
./test-queue-plugin.sh
```

### test-e2e.sh
端到端测试脚本，验证完整的请求处理流程。

**功能：**
- 提交任务并获取 request_id
- 等待处理完成
- 查询并显示最终结果

**使用方法：**
```bash
./test-e2e.sh
```

**示例输出：**
```
提交新任务...
响应: {"request_id":"177297990516671627","status":"queued",...}
Request ID: 177297990516671627

等待处理...

查询结果:
{"status":"completed","result":{...}}
```

### test-queue-demo.sh
完整的功能演示脚本，展示所有关键步骤。

**功能：**
- 提交任务
- 检查 Redis 队列状态
- 轮询查询任务状态
- 显示 Redis 中的数据
- 显示 Worker 日志

**使用方法：**
```bash
./test-queue-demo.sh
```

### test-queue-logic.sh & test-queue-logic.py
队列逻辑单元测试，测试核心功能。

**使用方法：**
```bash
# Bash 版本
./test-queue-logic.sh

# Python 版本
python3 test-queue-logic.py
```

### check-status.sh
系统状态检查脚本，快速诊断问题。

**功能：**
- 检查 APISIX 状态
- 检查 Redis 状态
- 检查 Worker 状态
- 检查后端服务状态
- 显示队列长度
- 显示已加载的插件

**使用方法：**
```bash
./check-status.sh
```

**示例输出：**
```
=== 系统状态检查 ===

1. APISIX 状态:
root  5642  nginx: master process

2. Redis 状态:
PONG

3. Queue Worker 状态:
root  4959  python3 queue-worker.py

4. 后端服务状态:
root  6420  python3 test-backend-server.py

5. 队列长度:
0

6. 已加载的队列插件:
queue-request
queue-result
```

## 🚀 快速测试

### 前置条件

确保以下服务已启动：
```bash
# 1. Redis
redis-server --daemonize yes

# 2. APISIX
make init && make run

# 3. 测试后端服务
cd ../../examples/queue
nohup python3 test-backend-server.py > backend.log 2>&1 &

# 4. Queue Worker
nohup python3 queue-worker.py > worker.log 2>&1 &
```

### 运行测试

```bash
# 1. 检查系统状态
./check-status.sh

# 2. 运行端到端测试
./test-e2e.sh

# 3. 运行完整演示
./test-queue-demo.sh

# 4. 运行自动化测试
./test-queue-plugin.sh
```

## 📊 测试场景

### 场景 1: 正常流程测试
测试请求从提交到完成的完整流程。

```bash
# 提交任务
curl -X POST http://127.0.0.1:9080/api/task \
  -H "Content-Type: application/json" \
  -d '{"action": "test", "data": "hello"}'

# 查询结果
curl http://127.0.0.1:9080/api/task/{request_id}
```

### 场景 2: 错误处理测试
测试后端服务失败时的错误处理。

```bash
# 停止后端服务
pkill -f test-backend-server

# 提交任务（会失败）
curl -X POST http://127.0.0.1:9080/api/task \
  -H "Content-Type: application/json" \
  -d '{"action": "test", "data": "error test"}'

# 查询结果（应该返回 failed 状态）
curl http://127.0.0.1:9080/api/task/{request_id}
```

### 场景 3: 队列限流测试
测试队列长度限制功能。

```bash
# 停止 Worker（让队列堆积）
pkill -f queue-worker

# 提交大量任务
for i in {1..100}; do
  curl -X POST http://127.0.0.1:9080/api/task \
    -H "Content-Type: application/json" \
    -d "{\"action\": \"test\", \"data\": \"task-$i\"}"
done

# 检查队列长度
redis-cli LLEN apisix:queue:requests

# 重启 Worker
cd ../../examples/queue
nohup python3 queue-worker.py > worker.log 2>&1 &
```

### 场景 4: 并发测试
测试系统在高并发下的表现。

```bash
# 使用 ab 或 wrk 进行压力测试
ab -n 1000 -c 10 -p task.json -T application/json \
  http://127.0.0.1:9080/api/task

# 或使用 wrk
wrk -t4 -c100 -d30s --latency \
  -s post.lua http://127.0.0.1:9080/api/task
```

## 🔍 故障排查

### 问题 1: 任务一直处于 queued 状态

**检查：**
```bash
# 1. 检查 Worker 是否运行
ps aux | grep queue-worker

# 2. 查看 Worker 日志
tail -f ../../examples/queue/worker.log

# 3. 检查队列长度
redis-cli LLEN apisix:queue:requests
```

**解决：**
```bash
# 启动 Worker
cd ../../examples/queue
python3 queue-worker.py
```

### 问题 2: 查询结果返回 404

**检查：**
```bash
# 1. 检查路由配置
curl http://127.0.0.1:9180/apisix/admin/routes \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1'

# 2. 检查插件是否加载
curl http://127.0.0.1:9180/apisix/admin/plugins/list \
  -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' | grep queue
```

### 问题 3: Redis 连接失败

**检查：**
```bash
# 1. 检查 Redis 是否运行
redis-cli ping

# 2. 检查 Redis 配置
redis-cli CONFIG GET bind
redis-cli CONFIG GET port
```

**解决：**
```bash
# 启动 Redis
redis-server --daemonize yes
```

## 📖 更多信息

- [完整文档](../../docs/queue/README.md)
- [快速开始指南](../../docs/queue/QUEUE_QUICKSTART.md)
- [Worker 实现](../../examples/queue/README.md)
- [故障排查指南](../../docs/queue/QUEUE_QUICKSTART.md#故障排查)

## 🤝 贡献

欢迎提交新的测试用例和改进建议！
