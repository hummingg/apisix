#!/usr/bin/env python3
"""
APISIX 队列处理 Worker (Python 版本)

功能：
- 从 Redis 队列取出请求
- 调用后端服务处理
- 更新处理状态和结果

依赖：
    pip install redis requests

使用：
    python3 queue-worker.py
"""

import json
import time
import logging
import signal
import sys
from typing import Optional, Dict, Any

import redis
import requests

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

# 配置
CONFIG = {
    'redis_host': '127.0.0.1',
    'redis_port': 6379,
    'redis_password': None,
    'redis_db': 0,
    'queue_name': 'apisix:queue:requests',
    'backend_url': 'http://127.0.0.1:8080/api/process',
    'poll_interval': 1,  # 队列为空时的等待时间（秒）
    'process_interval': 30,  # 处理请求的间隔时间（秒），设为0表示无限制
    'request_timeout': 30,  # 秒
    'result_ttl': 3600,  # 秒
}

# 全局变量
running = True


def signal_handler(signum, frame):
    """处理退出信号"""
    global running
    logger.info(f"Received signal {signum}, shutting down...")
    running = False


def connect_redis() -> redis.Redis:
    """连接 Redis"""
    return redis.Redis(
        host=CONFIG['redis_host'],
        port=CONFIG['redis_port'],
        password=CONFIG['redis_password'],
        db=CONFIG['redis_db'],
        decode_responses=True
    )


def update_status(
    red: redis.Redis,
    request_id: str,
    status: str,
    result: Optional[Dict[str, Any]] = None
):
    """更新请求状态和结果"""
    status_key = f"apisix:queue:status:{request_id}"
    result_key = f"apisix:queue:result:{request_id}"
    ttl = CONFIG['result_ttl']

    # 更新状态
    red.setex(status_key, ttl, status)

    # 更新结果
    if result:
        result_json = json.dumps(result, ensure_ascii=False)
        red.setex(result_key, ttl, result_json)


def process_request(request_data: Dict[str, Any]) -> Dict[str, Any]:
    """处理单个请求"""
    try:
        # 构造请求
        method = request_data.get('method', 'POST')
        headers = {
            'Content-Type': 'application/json',
            'X-Request-ID': str(request_data.get('id')),
            'X-Original-URI': request_data.get('uri', ''),
        }

        # 发送请求到后端服务
        response = requests.request(
            method=method,
            url=CONFIG['backend_url'],
            data=request_data.get('body'),
            headers=headers,
            timeout=CONFIG['request_timeout']
        )

        # 返回结果
        return {
            'status_code': response.status_code,
            'headers': dict(response.headers),
            'body': response.text
        }

    except requests.Timeout:
        raise Exception('Request timeout')
    except requests.RequestException as e:
        raise Exception(f'Request failed: {str(e)}')


def worker_loop():
    """Worker 主循环"""
    logger.info("Starting queue worker...")
    logger.info(f"Redis: {CONFIG['redis_host']}:{CONFIG['redis_port']}")
    logger.info(f"Queue: {CONFIG['queue_name']}")
    logger.info(f"Backend: {CONFIG['backend_url']}")
    logger.info(f"Process interval: {CONFIG['process_interval']}s")
    logger.info("=" * 50)

    red = connect_redis()
    last_process_time = 0  # 上次处理请求的时间

    while running:
        try:
            # 从队列右侧取出请求（FIFO）
            result = red.rpop(CONFIG['queue_name'])

            if not result:
                # 队列为空，等待
                time.sleep(CONFIG['poll_interval'])
                continue

            # 检查是否需要等待处理间隔
            if CONFIG['process_interval'] > 0:
                current_time = time.time()
                time_since_last = current_time - last_process_time

                if last_process_time > 0 and time_since_last < CONFIG['process_interval']:
                    # 还没到处理时间，将请求放回队列
                    red.rpush(CONFIG['queue_name'], result)
                    wait_time = CONFIG['process_interval'] - time_since_last
                    logger.info(f"Rate limiting: waiting {wait_time:.1f}s before next request")
                    time.sleep(wait_time)
                    continue

            # 解析请求数据
            try:
                request_data = json.loads(result)
            except json.JSONDecodeError as e:
                logger.error(f"Failed to decode request: {e}")
                continue

            request_id = request_data.get('id')
            logger.info(f"Processing request: {request_id}")

            # 更新状态为 processing
            update_status(red, request_id, 'processing')

            # 处理请求
            try:
                response = process_request(request_data)
                logger.info(f"Request completed: {request_id}")

                # 更新状态为 completed
                update_status(red, request_id, 'completed', {
                    'request_id': request_id,
                    'status': 'completed',
                    'result': response,
                    'timestamp': int(time.time())
                })

            except Exception as e:
                logger.error(f"Request processing failed: {e}")

                # 更新状态为 failed
                update_status(red, request_id, 'failed', {
                    'request_id': request_id,
                    'status': 'failed',
                    'error': str(e),
                    'timestamp': int(time.time())
                })

            # 记录本次处理时间
            last_process_time = time.time()

        except redis.RedisError as e:
            logger.error(f"Redis error: {e}")
            time.sleep(CONFIG['poll_interval'])
            # 重新连接
            try:
                red = connect_redis()
            except Exception as e:
                logger.error(f"Failed to reconnect to Redis: {e}")
                time.sleep(5)

        except Exception as e:
            logger.error(f"Unexpected error: {e}")
            time.sleep(CONFIG['poll_interval'])

    logger.info("Worker stopped")


def main():
    """主函数"""
    # 注册信号处理
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # 启动 Worker
    try:
        worker_loop()
    except Exception as e:
        logger.error(f"Worker crashed: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
