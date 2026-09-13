# DevContainer 配置更新说明

## 📝 更新内容

为支持 APISIX 队列插件，已对 DevContainer 配置进行以下更新：

### 1. docker-compose.yml

**新增 Redis 服务**：

```yaml
redis:
  image: redis:7-alpine
  command: redis-server --appendonly yes
  volumes:
    - redis_data:/data
  ports:
    - "6379:6379"
```

**新增数据卷**：

```yaml
volumes:
  etcd_data:
  redis_data:    # 新增
```

### 2. devcontainer.json

**新增端口转发**：

```json
"forwardPorts": [9080, 9180, 2379, 6379]
                                    ^^^^
                                    新增 Redis 端口
```

## 🎯 更新原因

队列插件（queue-request 和 queue-result）需要 Redis 来：
- 存储请求队列
- 缓存请求状态
- 保存处理结果

## 🚀 使用方法

### 重建 DevContainer

如果你已经在 DevContainer 中，需要重建容器以应用更改：

1. **方式 1: 使用 VS Code 命令**
   - 按 `F1` 或 `Ctrl+Shift+P`
   - 选择 `Dev Containers: Rebuild Container`

2. **方式 2: 手动重建**
   ```bash
   # 退出 DevContainer
   # 在宿主机执行
   cd /path/to/apisix
   docker-compose -f .devcontainer/docker-compose.yml down
   docker-compose -f .devcontainer/docker-compose.yml up -d
   ```

### 验证 Redis 可用

重建后，在 DevContainer 中验证：

```bash
# 检查 Redis 是否运行
redis-cli ping
# 应该返回: PONG

# 检查 Redis 版本
redis-cli --version

# 查看 Redis 信息
redis-cli info server
```

### 测试队列插件

```bash
# 1. 启动 APISIX
make init && make run

# 2. 配置路由（参考 docs/queue/QUEUE_QUICKSTART.md）

# 3. 启动 Worker
cd examples/queue
python3 queue-worker.py

# 4. 运行测试
cd ../../t/queue
./test-e2e.sh
```

## 📊 服务端口映射

| 服务 | 容器端口 | 宿主机端口 | 说明 |
|------|---------|-----------|------|
| APISIX HTTP | 9080 | 9080 | 数据平面 |
| APISIX Admin | 9180 | 9180 | 管理接口 |
| etcd | 2379 | 2379 | 配置中心 |
| Redis | 6379 | 6379 | 队列存储（新增） |

## 🔧 Redis 配置说明

### 镜像选择
- **镜像**: `redis:7-alpine`
- **版本**: Redis 7.x
- **基础镜像**: Alpine Linux（轻量级）

### 持久化配置
- **AOF 持久化**: 已启用（`--appendonly yes`）
- **数据目录**: `/data`（映射到 Docker volume）
- **数据卷**: `redis_data`

### 为什么使用 AOF？
- 更好的数据持久性
- 适合队列场景（频繁写入）
- 容器重启后数据不丢失

## 🌐 网络配置

### 当前网络模式

```yaml
apisix:
  network_mode: service:etcd
```

这意味着：
- APISIX 容器共享 etcd 的网络命名空间
- APISIX 可以通过 `127.0.0.1:2379` 访问 etcd
- APISIX 可以通过 `127.0.0.1:6379` 访问 Redis（因为 Redis 端口已映射）

### 访问 Redis

在 APISIX 插件配置中使用：

```yaml
plugins:
  queue-request:
    redis_host: "127.0.0.1"
    redis_port: 6379
```

## 📝 配置文件对比

### 更新前

```yaml
# docker-compose.yml
services:
  apisix: ...
  etcd: ...

volumes:
  etcd_data:
```

```json
// devcontainer.json
"forwardPorts": [9080, 9180, 2379]
```

### 更新后

```yaml
# docker-compose.yml
services:
  apisix: ...
  etcd: ...
  redis: ...        # 新增

volumes:
  etcd_data:
  redis_data:       # 新增
```

```json
// devcontainer.json
"forwardPorts": [9080, 9180, 2379, 6379]  // 新增 6379
```

## 🔍 故障排查

### Redis 无法连接

**检查 Redis 是否运行**：
```bash
docker ps | grep redis
```

**查看 Redis 日志**：
```bash
docker logs <redis-container-id>
```

**手动启动 Redis**：
```bash
docker-compose -f .devcontainer/docker-compose.yml up -d redis
```

### 端口冲突

如果宿主机 6379 端口已被占用：

**方式 1: 修改端口映射**
```yaml
redis:
  ports:
    - "6380:6379"  # 映射到宿主机 6380
```

**方式 2: 停止宿主机 Redis**
```bash
# Linux/Mac
sudo systemctl stop redis
# 或
sudo service redis stop
```

### 数据持久化问题

**查看数据卷**：
```bash
docker volume ls | grep redis
docker volume inspect <volume-name>
```

**清理数据卷**（谨慎操作）：
```bash
docker-compose -f .devcontainer/docker-compose.yml down -v
```

## 📖 相关文档

- [队列插件快速开始](../docs/queue/QUEUE_QUICKSTART.md)
- [队列插件架构设计](../docs/queue/QUEUE_ARCHITECTURE.md)
- [DevContainer 环境搭建](../docs/devcontainer/DEVCONTAINER_SETUP.md)
- [Worker 使用说明](../examples/queue/README.md)
- [测试指南](../t/queue/README.md)

## 🎉 总结

通过这些更新，DevContainer 现在完整支持队列插件的开发和测试：

✅ Redis 服务自动启动
✅ 数据持久化配置
✅ 端口自动转发
✅ 开箱即用的开发环境

---

**更新时间**: 2026-03-08
**更新人**: Claude Code

## ❓ 为什么不包含测试后端服务？

### test-backend-server.py 不在 DevContainer 中

**原因**：
1. **定位不同**: 这是测试工具，不是核心基础设施
2. **灵活性**: 用户可能使用自己的后端服务
3. **简洁性**: 保持 DevContainer 只包含必需组件

### DevContainer 包含的服务

| 服务 | 包含 | 原因 |
|------|------|------|
| etcd | ✅ | APISIX 配置中心，必需 |
| Redis | ✅ | 队列插件依赖，必需 |
| test-backend-server | ❌ | 测试工具，可选 |

### 如何使用测试后端服务？

**方式 1: 使用启动脚本**
```bash
./start-test-env.sh  # 一键启动所有服务
```

**方式 2: 手动启动**
```bash
cd examples/queue
python3 test-backend-server.py
```

详见 [TEST_BACKEND_SERVICE.md](../TEST_BACKEND_SERVICE.md)

