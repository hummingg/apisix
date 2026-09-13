#!/bin/bash
#
# 队列插件功能演示脚本
#

set -e

echo "=================================="
echo "APISIX 队列插件功能测试"
echo "=================================="

# 1. 提交任务
echo ""
echo "[1] 提交测试任务..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:9080/api/task \
  -H "Content-Type: application/json" \
  -d '{"action": "test", "data": "hello world"}')

echo "响应: $RESPONSE"

REQUEST_ID=$(echo "$RESPONSE" | grep -o '"request_id":"[^"]*"' | cut -d'"' -f4)
echo "✅ 任务已提交，request_id: $REQUEST_ID"

# 2. 检查 Redis 队列
echo ""
echo "[2] 检查 Redis 队列状态..."
QUEUE_LEN=$(redis-cli LLEN apisix:queue:requests)
echo "队列长度: $QUEUE_LEN"

# 3. 查询任务状态
echo ""
echo "[3] 查询任务状态..."
for i in {1..5}; do
  echo "  尝试 $i/5..."
  sleep 2

  RESULT=$(curl -s "http://127.0.0.1:9080/api/task/${REQUEST_ID}")
  echo "  响应: $RESULT"

  STATUS=$(echo "$RESULT" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
  echo "  状态: $STATUS"

  if [ "$STATUS" == "completed" ] || [ "$STATUS" == "failed" ]; then
    echo "✅ 任务已处理完成"
    break
  fi
done

# 4. 查看 Redis 数据
echo ""
echo "[4] 查看 Redis 中的数据..."
echo "状态键:"
redis-cli GET "apisix:queue:status:${REQUEST_ID}"

echo ""
echo "结果键:"
redis-cli GET "apisix:queue:result:${REQUEST_ID}"

# 5. 查看 Worker 日志
echo ""
echo "[5] Worker 日志（最后 10 行）:"
tail -10 /workspace/worker.log

echo ""
echo "=================================="
echo "测试完成"
echo "=================================="
