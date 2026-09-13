#!/bin/bash
# 完整端到端测试

echo "提交新任务..."
RESPONSE=$(curl -s -X POST http://127.0.0.1:9080/api/task \
  -H "Content-Type: application/json" \
  -d '{"action": "test", "data": "完整测试"}')

echo "响应: $RESPONSE"

REQUEST_ID=$(echo "$RESPONSE" | grep -o '"request_id":"[^"]*"' | cut -d'"' -f4)
echo "Request ID: $REQUEST_ID"

echo ""
echo "等待处理..."
sleep 3

echo ""
echo "查询结果:"
curl -s "http://127.0.0.1:9080/api/task/${REQUEST_ID}"
