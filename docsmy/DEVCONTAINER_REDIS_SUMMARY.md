# DevContainer Redis 配置 - 更新总结

## ✅ 已完成的更改

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
                                    Redis 端口
```

### 3. 文档更新
- ✅ 创建 [.devcontainer/REDIS_UPDATE.md](.devcontainer/REDIS_UPDATE.md) - Redis 配置详细说明
- ✅ 更新 [docs/devcontainer/DEVCONTAINER_SETUP.md](docs/devcontainer/DEVCONTAINER_SETUP.md) - 添加 Redis 章节

## 📋 更改清单

| 文件 | 更改内容 | 状态 |
|------|---------|------|
| `.devcontainer/docker-compose.yml` | 添加 Redis 服务和数据卷 | ✅ |
| `.devcontainer/devcontainer.json` | 添加 6379 端口转发 | ✅ |
| `.devcontainer/REDIS_UPDATE.md` | 创建 Redis 配置说明文档 | ✅ |
| `docs/devcontainer/DEVCONTAINER_SETUP.md` | 添加 Redis 使用章节 | ✅ |

## 🎯 为什么需要这些更改？

队列插件（queue-request 和 queue-result）依赖 Redis 来：
1. **存储请求队列** - 使用 Redis List 实现 FIFO 队列
2. **缓存请求状态** - 存储 queued/processing/completed/failed 状态
3. **保存处理结果** - 缓存最终的处理结果供客户端查询

## 🚀 如何应用这些更改？

### 方式 1: 重建 DevContainer（推荐）

在 VS Code 中：
1. 按 `F1` 或 `Ctrl+Shift+P`
2. 选择 `Dev Containers: Rebuild Container`
3. 等待容器重建完成

### 方式 2: 手动重启容器

```bash
# 在宿主机执行
cd /path/to/apisix
docker-compose -f .devcontainer/docker-compose.yml down
docker-compose -f .devcontainer/docker-compose.yml up -d
```

## ✅ 验证步骤

重建后，在 DevContainer 中执行：

```bash
# 1. 验证 Redis 运行
redis-cli ping
# 应该返回: PONG

# 2. 查看 Redis 版本
redis-cli --version

# 3. 测试队列插件
cd t/queue
./check-status.sh
```

## 📊 服务端口总览

| 服务 | 容器端口 | 宿主机端口 | 说明 |
|------|---------|-----------|------|
| APISIX HTTP | 9080 | 9080 | 数据平面 |
| APISIX Admin | 9180 | 9180 | 管理接口 |
| etcd | 2379 | 2379 | 配置中心 |
| **Redis** | **6379** | **6379** | **队列存储（新增）** |

## 🔧 Redis 配置详情

### 镜像和版本
- **镜像**: redis:7-alpine
- **版本**: Redis 7.x
- **大小**: ~30MB（Alpine 基础镜像）

### 持久化配置
- **AOF 持久化**: 已启用
- **数据目录**: /data
- **数据卷**: redis_data（Docker volume）

### 为什么选择 AOF？
- ✅ 更好的数据持久性
- ✅ 适合队列场景（频繁写入）
- ✅ 容器重启后数据不丢失

## 📖 相关文档

### 配置说明
- [Redis 配置更新详细说明](.devcontainer/REDIS_UPDATE.md)
- [DevContainer 环境搭建指南](docs/devcontainer/DEVCONTAINER_SETUP.md)

### 队列插件文档
- [队列插件文档索引](docs/queue/README.md)
- [快速开始指南](docs/queue/QUEUE_QUICKSTART.md)
- [架构设计](docs/queue/QUEUE_ARCHITECTURE.md)

### 使用指南
- [Worker 使用说明](examples/queue/README.md)
- [测试指南](t/queue/README.md)

## 🔍 常见问题

### Q1: 为什么不在 Dockerfile 中安装 Redis？
**A**: 使用独立的 Redis 容器更符合微服务架构，便于：
- 独立管理和扩展
- 数据持久化
- 多个服务共享

### Q2: Redis 数据会丢失吗？
**A**: 不会。配置了：
- AOF 持久化
- Docker volume 存储
- 容器重启后数据保留

### Q3: 可以使用外部 Redis 吗？
**A**: 可以。修改插件配置中的 `redis_host` 和 `redis_port` 即可。

### Q4: 如何清理 Redis 数据？
**A**:
```bash
# 方式 1: 清空所有数据
redis-cli FLUSHALL

# 方式 2: 删除数据卷（会丢失所有数据）
docker-compose -f .devcontainer/docker-compose.yml down -v
```

## 🎉 总结

通过这些更改，DevContainer 现在完整支持队列插件：

✅ **自动启动** - Redis 随 DevContainer 自动启动
✅ **数据持久化** - AOF + Docker volume
✅ **端口转发** - 6379 端口自动映射
✅ **开箱即用** - 无需额外配置

现在你可以在 DevContainer 中直接开发和测试队列插件了！

---

**更新时间**: 2026-03-08
**更新人**: Claude Code
