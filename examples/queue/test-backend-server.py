#!/usr/bin/env python3
"""
测试用的简单 HTTP 服务器
监听 8080 端口，接收请求并返回处理结果
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import time

class TestHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        # 读取请求体
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')

        # 模拟处理时间
        time.sleep(1)

        # 构造响应
        response = {
            'status': 'success',
            'message': 'Request processed successfully',
            'received_data': body,
            'timestamp': int(time.time())
        }

        # 发送响应
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response, ensure_ascii=False).encode('utf-8'))

        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Processed request")

    def log_message(self, format, *args):
        # 自定义日志格式
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {format % args}")

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 8080), TestHandler)
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Test backend server started on http://127.0.0.1:8080")
    print("Press Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped")
