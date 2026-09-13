# Apache APISIX DevContainer 环境搭建指南

本文档记录在 DevContainer 环境中启动 APISIX 及相关服务的完整步骤。

## 〇、克隆项目

```bash
git clone https://github.com/apache/apisix.git
cd apisix
```

使用 VS Code 打开项目文件夹。

## 一、环境概述

| 服务 | 端口 | 说明 |
|------|------|------|
| APISIX HTTP | 9080 | 数据平面，处理业务请求 |
| APISIX Admin API | 9180 | 管理接口 |
| APISIX HTTPS | 9443 | SSL/TLS 流量 |
| etcd | 2379 | 配置中心 |
| Redis | 6379 | 队列存储（用于队列插件） |
| Dashboard | 9000 | Web 管理界面（宿主机 Docker） |

## 二、启动 DevContainer

1. 确保已安装 VS Code 插件：`Dev Containers`
2. 按 `F1` 选择 `Dev Containers: Reopen in Container`
3. 等待容器构建完成（首次约 5-10 分钟）
4. etcd 和 Redis 会自动启动

## 三、启动 APISIX

在 DevContainer 终端中执行：

```bash
# 初始化配置
make init

# 启动 APISIX
make run
```

验证服务：
```bash
# 检查进程
ps aux | grep nginx

# 测试 Admin API
curl -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://127.0.0.1:9180/apisix/admin/routes
```

## 四、配置 Admin API 访问权限

默认配置只允许 `127.0.0.0/24` 访问 Admin API。如需从 Dashboard 或外部访问，修改 `/workspace/conf/config.yaml`：

```yaml
deployment:
  admin:
    allow_admin:
    - 0.0.0.0/0  # 允许所有 IP（生产环境请限制具体 IP）
```

修改后重新加载：
```bash
/workspace/bin/apisix reload
```

## 五、启动 Dashboard（宿主机执行）

### 1. 创建配置文件

```bash
cat > /tmp/dashboard-conf.yaml << 'EOF'
conf:
  listen:
    host: 0.0.0.0
    port: 9000
  etcd:
    endpoints:
      - host.docker.internal:2379
  log:
    error_log:
      level: warn
      file_path: /dev/stderr
    access_log:
      file_path: /dev/stdout
authentication:
  secret: apisix-dashboard-secret-key-2024
  expire_time: 3600
  users:
    - username: admin
      password: admin
EOF
```

### 2. 启动 Dashboard 容器

```bash
docker run -d \
  --name apisix-dashboard \
  -p 9000:9000 \
  -v /tmp/dashboard-conf.yaml:/usr/local/apisix-dashboard/conf/conf.yaml \
  apache/apisix-dashboard:3.0.1-alpine
```

> **注意**：必须使用 `3.0.1-alpine` 版本，`latest` 版本是纯前端架构，无法正常代理 API。

### 3. 访问 Dashboard

- URL: `http://localhost:9000`
- 用户名: `admin`
- 密码: `admin`

## 六、常用操作

### APISIX 管理命令

```bash
# 启动
make run

# 停止
/workspace/bin/apisix stop

# 重启
/workspace/bin/apisix restart

# 重新加载配置
/workspace/bin/apisix reload

# 查看日志
tail -f /workspace/logs/error.log
tail -f /workspace/logs/access.log
```

### Dashboard 管理命令（宿主机）

```bash
# 查看日志
docker logs -f apisix-dashboard

# 重启
docker restart apisix-dashboard

# 停止
docker stop apisix-dashboard

# 删除
docker rm -f apisix-dashboard
```

### Admin API 示例

```bash
# 查看所有路由
curl -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://localhost:9180/apisix/admin/routes

# 创建路由
curl -X POST http://localhost:9180/apisix/admin/routes \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-route",
    "uri": "/api/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "192.168.31.2:8080": 1
      }
    }
  }'

# 删除路由
curl -X DELETE http://localhost:9180/apisix/admin/routes/{route_id} \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1"
```

## 七、端口转发说明

DevContainer 已配置以下端口转发（见 `.devcontainer/devcontainer.json`）：

```json
"forwardPorts": [9080, 9180, 2379]
```

这些端口可从宿主机直接访问：
- `http://localhost:9080` - APISIX 数据平面
- `http://localhost:9180` - Admin API
- `http://localhost:2379` - etcd

## 八、故障排查

### Dashboard 连接超时

1. 检查 `allow_admin` 配置是否允许外部访问
2. 确认使用 `3.0.1-alpine` 版本镜像
3. 检查 `host.docker.internal` 是否可解析

### APISIX 启动失败

```bash
# 查看错误日志
cat /workspace/logs/error.log

# 检查配置语法
/workspace/bin/apisix test
```

### etcd 连接问题

```bash
# 验证 etcd 运行状态
curl http://127.0.0.1:2379/version
```

## 九、关键配置文件

| 文件 | 说明 |
|------|------|
| `/workspace/conf/config.yaml` | APISIX 主配置 |
| `/workspace/conf/apisix.yaml` | Standalone 模式配置 |
| `/workspace/logs/error.log` | 错误日志 |
| `/workspace/logs/access.log` | 访问日志 |
| `/tmp/dashboard-conf.yaml` | Dashboard 配置（宿主机） |

## 十、Redis 服务（队列插件支持）

### 验证 Redis 运行

```bash
# 测试 Redis 连接
redis-cli ping
# 应该返回: PONG

# 查看 Redis 版本
redis-cli --version

# 查看 Redis 信息
redis-cli info server
```

### Redis 基本操作

```bash
# 查看所有键
redis-cli KEYS "*"

# 查看队列长度
redis-cli LLEN apisix:queue:requests

# 查看队列内容
redis-cli LRANGE apisix:queue:requests 0 10

# 查看请求状态
redis-cli GET "apisix:queue:status:{request_id}"

# 查看请求结果
redis-cli GET "apisix:queue:result:{request_id}"

# 清空所有数据（谨慎使用）
redis-cli FLUSHALL
```

### 使用队列插件

1. **启用插件**

编辑 `conf/config.yaml`，添加队列插件：

```yaml
plugins:
  - queue-request
  - queue-result
  # ... 其他插件
```

2. **配置路由**

参考 [队列插件快速开始指南](../queue/QUEUE_QUICKSTART.md)

3. **启动 Worker**

```bash
cd examples/queue
python3 queue-worker.py
```

4. **测试**

```bash
cd t/queue
./test-e2e.sh
```

### Redis 故障排查

#### Redis 未启动

```bash
# 检查 Redis 容器
docker ps | grep redis

# 查看 Redis 日志
docker logs <redis-container-id>

# 手动启动 Redis
docker-compose -f .devcontainer/docker-compose.yml up -d redis
```

#### 连接失败

```bash
# 检查 Redis 是否监听
netstat -tlnp | grep 6379

# 测试连接
telnet 127.0.0.1 6379
```

#### 数据持久化

Redis 配置了 AOF 持久化，数据保存在 Docker volume 中：

```bash
# 查看数据卷
docker volume ls | grep redis

# 查看数据卷详情
docker volume inspect <volume-name>
```

### 相关文档

- [Redis 配置更新说明](../../.devcontainer/REDIS_UPDATE.md)
- [队列插件文档](../queue/README.md)
- [队列插件快速开始](../queue/QUEUE_QUICKSTART.md)
