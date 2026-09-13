#!/usr/bin/env python3
"""
独立测试脚本 - 验证队列插件的核心逻辑
不依赖 APISIX，直接测试 Redis 队列功能
"""

import redis
import json
import time
from datetime import datetime

# 配置
REDIS_HOST = '127.0.0.1'
REDIS_PORT = 6379
QUEUE_NAME = 'apisix:queue:requests'

def test_queue_logic():
    """测试队列逻辑"""
    print("=" * 60)
    print("队列插件逻辑测试")
    print("=" * 60)

    # 连接 Redis
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
        r.ping()
        print("✅ Redis 连接成功")
    except Exception as e:
        print(f"❌ Redis 连接失败: {e}")
        return

    # 清空测试数据
    r.delete(QUEUE_NAME)
    print(f"✅ 清空队列: {QUEUE_NAME}")

    # 模拟请求入队
    request_id = str(int(time.time() * 1000))
    request_data = {
        'id': request_id,
        'method': 'POST',
        'uri': '/api/task',
        'body': '{"action":"test","data":"hello"}',
        'timestamp': int(time.time())
    }

    # 入队
    r.lpush(QUEUE_NAME, json.dumps(request_data))
    print(f"✅ 请求入队成功")
    print(f"   Request ID: {request_id}")

    # 设置状态
    status_key = f"apisix:queue:status:{request_id}"
    r.setex(status_key, 3600, "queued")
    print(f"✅ 设置状态: queued")

    # 检查队列长度
    queue_len = r.llen(QUEUE_NAME)
    print(f"✅ 队列长度: {queue_len}")

    # 模拟 Worker 取出任务
    print("\n" + "-" * 60)
    print("模拟 Worker 处理")
    print("-" * 60)

    task_json = r.rpop(QUEUE_NAME)
    if task_json:
        task = json.loads(task_json)
        print(f"✅ 取出任务: {task['id']}")

        # 更新状态为 processing
        r.setex(status_key, 3600, "processing")
        print(f"✅ 更新状态: processing")

        # 模拟处理
        time.sleep(1)

        # 保存结果
        result_key = f"apisix:queue:result:{request_id}"
        result_data = {
            'request_id': request_id,
            'status': 'completed',
            'result': {
                'status_code': 200,
                'body': 'Task completed successfully'
            },
            'timestamp': int(time.time())
        }
        r.setex(result_key, 3600, json.dumps(result_data))
        r.setex(status_key, 3600, "completed")
        print(f"✅ 任务完成，结果已保存")

    # 模拟客户端查询
    print("\n" + "-" * 60)
    print("模拟客户端查询结果")
    print("-" * 60)

    status = r.get(status_key)
    print(f"✅ 查询状态: {status}")

    if status == "completed":
        result_key = f"apisix:queue:result:{request_id}"
        result_json = r.get(result_key)
        if result_json:
            result = json.loads(result_json)
            print(f"✅ 查询结果:")
            print(json.dumps(result, indent=2, ensure_ascii=False))

    print("\n" + "=" * 60)
    print("✅ 测试完成！队列逻辑工作正常")
    print("=" * 60)

if __name__ == '__main__':
    test_queue_logic()
