#!/bin/bash
# 系统状态检查

echo "=== 系统状态检查 ==="
echo ""
echo "1. APISIX 状态:"
ps aux | grep nginx | grep master | grep -v grep

echo ""
echo "2. Redis 状态:"
redis-cli ping

echo ""
echo "3. Queue Worker 状态:"
ps aux | grep queue-worker | grep -v grep

echo ""
echo "4. 后端服务状态:"
ps aux | grep test-backend-server | grep -v grep

echo ""
echo "5. 队列长度:"
redis-cli LLEN apisix:queue:requests

echo ""
echo "6. 已加载的队列插件:"
curl -s http://127.0.0.1:9180/apisix/admin/plugins/list -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' | grep -o 'queue-[^"]*'
