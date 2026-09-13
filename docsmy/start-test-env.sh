#!/bin/bash
#
# 启动完整的测试环境
# 包括：APISIX、Redis、Worker、测试后端服务
#

set -e

echo "==================================="
echo "启动 APISIX 队列插件测试环境"
echo "==================================="

# 检查是否在 workspace 目录
if [ ! -f "Makefile" ]; then
    echo "❌ 错误: 请在项目根目录运行此脚本"
    exit 1
fi

# 1. 启动 APISIX
echo ""
echo "[1/4] 启动 APISIX..."
if ! ps aux | grep -v grep | grep nginx > /dev/null; then
    make init && make run
    echo "✅ APISIX 已启动"
else
    echo "✅ APISIX 已在运行"
fi

# 2. 检查 Redis
echo ""
echo "[2/4] 检查 Redis..."
if redis-cli ping > /dev/null 2>&1; then
    echo "✅ Redis 已运行"
else
    echo "❌ Redis 未运行，请先启动 Redis"
    exit 1
fi

# 3. 启动测试后端服务
echo ""
echo "[3/4] 启动测试后端服务..."
if ps aux | grep -v grep | grep test-backend-server > /dev/null; then
    echo "✅ 测试后端服务已在运行"
else
    cd examples/queue
    nohup python3 test-backend-server.py > ../../logs/backend.log 2>&1 &
    BACKEND_PID=$!
    cd ../..
    sleep 2
    if ps -p $BACKEND_PID > /dev/null; then
        echo "✅ 测试后端服务已启动 (PID: $BACKEND_PID)"
    else
        echo "❌ 测试后端服务启动失败"
        exit 1
    fi
fi

# 4. 启动 Worker
echo ""
echo "[4/4] 启动 Queue Worker..."
if ps aux | grep -v grep | grep queue-worker.py > /dev/null; then
    echo "✅ Queue Worker 已在运行"
else
    cd examples/queue
    nohup python3 queue-worker.py > ../../logs/worker.log 2>&1 &
    WORKER_PID=$!
    cd ../..
    sleep 2
    if ps -p $WORKER_PID > /dev/null; then
        echo "✅ Queue Worker 已启动 (PID: $WORKER_PID)"
    else
        echo "❌ Queue Worker 启动失败"
        exit 1
    fi
fi

# 显示状态
echo ""
echo "==================================="
echo "✅ 测试环境启动完成"
echo "==================================="
echo ""
echo "📊 服务状态:"
echo "- APISIX:        http://127.0.0.1:9080"
echo "- Admin API:     http://127.0.0.1:9180"
echo "- Redis:         127.0.0.1:6379"
echo "- 测试后端:      http://127.0.0.1:8080"
echo ""
echo "📝 日志文件:"
echo "- APISIX:        logs/error.log"
echo "- Worker:        logs/worker.log"
echo "- 测试后端:      logs/backend.log"
echo ""
echo "🧪 运行测试:"
echo "  cd t/queue && ./test-e2e.sh"
echo ""
echo "🛑 停止服务:"
echo "  ./stop-test-env.sh"
