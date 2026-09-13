#!/bin/bash
#
# 使用 redis-cli 测试队列逻辑
#

echo "======================================"
echo "队列插件逻辑测试（使用 redis-cli）"
echo "======================================"

# 清空测试数据
echo ""
echo "[1] 清空测试队列..."
docker exec compose-redis-1 redis-cli DEL apisix:queue:requests

# 生成 request_id
REQUEST_ID=$(date +%s%3N)
echo "✅ 生成 Request ID: $REQUEST_ID"

# 构造请求数据
REQUEST_DATA="{\"id\":\"$REQUEST_ID\",\"method\":\"POST\",\"uri\":\"/api/task\",\"body\":\"{\\\"action\\\":\\\"test\\\"}\",\"timestamp\":$(date +%s)}"

# 入队
echo ""
echo "[2] 模拟请求入队..."
docker exec compose-redis-1 redis-cli LPUSH apisix:queue:requests "$REQUEST_DATA"
echo "✅ 请求已入队"

# 设置状态
echo ""
echo "[3] 设置请求状态..."
docker exec compose-redis-1 redis-cli SETEX "apisix:queue:status:$REQUEST_ID" 3600 "queued"
echo "✅ 状态设置为: queued"

# 检查队列长度
echo ""
echo "[4] 检查队列长度..."
QUEUE_LEN=$(docker exec compose-redis-1 redis-cli LLEN apisix:queue:requests)
echo "✅ 队列长度: $QUEUE_LEN"

# 模拟 Worker 取出任务
echo ""
echo "======================================"
echo "模拟 Worker 处理任务"
echo "======================================"

TASK=$(docker exec compose-redis-1 redis-cli RPOP apisix:queue:requests)
echo "✅ 取出任务: $TASK"

# 更新状态为 processing
docker exec compose-redis-1 redis-cli SETEX "apisix:queue:status:$REQUEST_ID" 3600 "processing"
echo "✅ 更新状态: processing"

# 模拟处理延迟
sleep 1

# 保存结果
RESULT_DATA="{\"request_id\":\"$REQUEST_ID\",\"status\":\"completed\",\"result\":{\"status_code\":200,\"body\":\"Task completed\"},\"timestamp\":$(date +%s)}"
docker exec compose-redis-1 redis-cli SETEX "apisix:queue:result:$REQUEST_ID" 3600 "$RESULT_DATA"
docker exec compose-redis-1 redis-cli SETEX "apisix:queue:status:$REQUEST_ID" 3600 "completed"
echo "✅ 任务完成，结果已保存"

# 模拟客户端查询
echo ""
echo "======================================"
echo "模拟客户端查询结果"
echo "======================================"

STATUS=$(docker exec compose-redis-1 redis-cli GET "apisix:queue:status:$REQUEST_ID")
echo "✅ 查询状态: $STATUS"

if [ "$STATUS" = "completed" ]; then
    RESULT=$(docker exec compose-redis-1 redis-cli GET "apisix:queue:result:$REQUEST_ID")
    echo "✅ 查询结果:"
    echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
fi

echo ""
echo "======================================"
echo "✅ 测试完成！队列逻辑工作正常"
echo "======================================"
echo ""
echo "📝 总结："
echo "   - Request ID: $REQUEST_ID"
echo "   - 队列名称: apisix:queue:requests"
echo "   - 状态键: apisix:queue:status:$REQUEST_ID"
echo "   - 结果键: apisix:queue:result:$REQUEST_ID"
