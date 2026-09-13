#!/bin/bash
#
# 停止测试环境
#

echo "==================================="
echo "停止 APISIX 队列插件测试环境"
echo "==================================="

# 停止 Worker
echo ""
echo "[1/3] 停止 Queue Worker..."
if pkill -f queue-worker.py; then
    echo "✅ Queue Worker 已停止"
else
    echo "ℹ️  Queue Worker 未运行"
fi

# 停止测试后端服务
echo ""
echo "[2/3] 停止测试后端服务..."
if pkill -f test-backend-server.py; then
    echo "✅ 测试后端服务已停止"
else
    echo "ℹ️  测试后端服务未运行"
fi

# 停止 APISIX
echo ""
echo "[3/3] 停止 APISIX..."
if /workspace/bin/apisix stop; then
    echo "✅ APISIX 已停止"
else
    echo "ℹ️  APISIX 未运行"
fi

echo ""
echo "==================================="
echo "✅ 测试环境已停止"
echo "==================================="
