#!/bin/bash
#
# APISIX 队列请求插件测试脚本
#

set -e

APISIX_ADMIN_URL="http://127.0.0.1:9180"
APISIX_GATEWAY_URL="http://127.0.0.1:9080"
ADMIN_KEY="edd1c9f034335f136f87ad84b625c8f1"

echo "=================================="
echo "APISIX 队列请求插件测试"
echo "=================================="

# 1. 配置提交任务路由
echo ""
echo "[1] 配置提交任务路由..."
curl -s "${APISIX_ADMIN_URL}/apisix/admin/routes/queue-submit" \
  -H "X-API-KEY: ${ADMIN_KEY}" \
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
}' | jq .

# 2. 配置查询结果路由
echo ""
echo "[2] 配置查询结果路由..."
curl -s "${APISIX_ADMIN_URL}/apisix/admin/routes/queue-query" \
  -H "X-API-KEY: ${ADMIN_KEY}" \
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
}' | jq .

# 等待配置生效
echo ""
echo "[3] 等待配置生效..."
sleep 2

# 3. 提交测试任务
echo ""
echo "[4] 提交测试任务..."
RESPONSE=$(curl -s -w "\n%{http_code}" "${APISIX_GATEWAY_URL}/api/task" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "action": "test",
    "data": "hello world"
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "HTTP 状态码: $HTTP_CODE"
echo "响应内容: $BODY"

if [ "$HTTP_CODE" != "202" ]; then
  echo "❌ 错误: 期望状态码 202，实际 $HTTP_CODE"
  exit 1
fi

REQUEST_ID=$(echo "$BODY" | jq -r '.request_id')
echo "✅ 任务已提交，request_id: $REQUEST_ID"

# 4. 查询任务状态
echo ""
echo "[5] 查询任务状态..."
for i in {1..5}; do
  echo "  尝试 $i/5..."
  RESULT=$(curl -s "${APISIX_GATEWAY_URL}/api/task/${REQUEST_ID}")
  echo "  响应: $RESULT"

  STATUS=$(echo "$RESULT" | jq -r '.status')
  echo "  状态: $STATUS"

  if [ "$STATUS" == "completed" ]; then
    echo "✅ 任务已完成"
    echo "$RESULT" | jq .
    break
  elif [ "$STATUS" == "failed" ]; then
    echo "❌ 任务失败"
    echo "$RESULT" | jq .
    exit 1
  fi

  sleep 2
done

# 5. 检查 Redis 数据
echo ""
echo "[6] 检查 Redis 数据..."
echo "队列长度:"
redis-cli LLEN apisix:queue:requests

echo ""
echo "状态键:"
redis-cli GET "apisix:queue:status:${REQUEST_ID}"

echo ""
echo "结果键:"
redis-cli GET "apisix:queue:result:${REQUEST_ID}"

echo ""
echo "=================================="
echo "测试完成"
echo "=================================="
