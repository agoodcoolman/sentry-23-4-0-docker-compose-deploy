非常抱歉，我完全理解了。你希望得到的不是一段段的拆解，而是将**整个问题的解决方案（从背景介绍到最终代码）全部封装进一个完整的、可直接保存的 Markdown 文档内容中**。

请直接复制以下代码块中的全部内容，保存为 `Sentry_Replay_Full_Guide.md` 即可：

---

```markdown
# Sentry Session Replay (录屏回放) 专项对接与配置全指南

针对自托管 Sentry (On-Premise) 环境，由于 Replay 功能涉及大量二进制分片数据，默认的最小化部署通常未开启相关消费队列。本文档提供完整的后端扩容方案、存储优化及验证流程。

---

## 1. 为什么现在看不到录屏数据？
在 Sentry 架构中，Replay 数据流与普通的错误日志（Errors）是分离的：
- **前端**：通过 Envelope 协议发送压缩的录屏分片。
- **Relay**：接收并将其暂存在 Kafka 中。
- **后端（核心缺失点）**：需要专门的消费者从 Kafka 提取数据并处理成可视化视频流，最后写入 ClickHouse。如果 `docker-compose.yml` 中缺失相关服务，数据会堆积在 Kafka 中无法显示。

---

## 2. 后端架构调整方案 (docker-compose.yml)

请将以下服务配置合并到你现有的 `docker-compose.yml` 文件中。

### A. 修改接入层 (sentry-ingest-consumer)
找到你原有的该服务，在 `command` 列表末尾增加对 `replays` 的支持：

```yaml
  sentry-ingest-consumer:
    image: getsentry/sentry:23.4.0
    restart: always
    depends_on:
      - postgres
      - redis
      - kafka
      - snuba-api
    volumes:
      - ./sentry.conf.py:/etc/sentry/sentry.conf.py:ro
    environment:
      SENTRY_SECRET_KEY: ${SENTRY_SECRET_KEY:-please-change-me}
      SENTRY_POSTGRES_HOST: ${SENTRY_POSTGRES_HOST:-postgres}
      SENTRY_DB_NAME: ${SENTRY_DB_NAME:-sentry}
      SENTRY_DB_USER: ${SENTRY_DB_USER:-sentry}
      SENTRY_DB_PASSWORD: ${SENTRY_DB_PASSWORD:-sentry}
      SENTRY_REDIS_HOST: ${SENTRY_REDIS_HOST:-redis}
      SENTRY_REDIS_PASSWORD: ${REDIS_PASSWORD:-please-change-me}
      SENTRY_TSDB: "sentry.tsdb.redis.RedisTSDB"
      SNUBA: "http://snuba-api:1218"
    command: ["sentry", "run", "ingest-consumer", "--consumer-type", "events", "--consumer-type", "transactions", "--consumer-type", "replays"]

```

### B. 新增录屏分片处理器 (sentry-ingest-replay-recordings)

**必须新增**。负责处理录屏分片（Recordings），这是让回放产生画面的关键。

```yaml
  sentry-ingest-replay-recordings:
    image: getsentry/sentry:23.4.0
    restart: always
    depends_on:
      - postgres
      - redis
      - kafka
    volumes:
      - ./sentry.conf.py:/etc/sentry/sentry.conf.py:ro
    environment:
      SENTRY_SECRET_KEY: ${SENTRY_SECRET_KEY:-please-change-me}
      SENTRY_POSTGRES_HOST: ${SENTRY_POSTGRES_HOST:-postgres}
      SENTRY_DB_NAME: ${SENTRY_DB_NAME:-sentry}
      SENTRY_DB_USER: ${SENTRY_DB_USER:-sentry}
      SENTRY_DB_PASSWORD: ${SENTRY_DB_PASSWORD:-sentry}
      SENTRY_REDIS_HOST: ${SENTRY_REDIS_HOST:-redis}
      SENTRY_REDIS_PASSWORD: ${REDIS_PASSWORD:-please-change-me}
    command: ["sentry", "run", "ingest-consumer", "--consumer-type", "replay_recordings"]

```

### C. 新增存储层消费者 (snuba-consumer-replays)

**必须新增**。负责将回放索引数据写入 ClickHouse 数据库。

```yaml
  snuba-consumer-replays:
    image: getsentry/snuba:23.4.0
    restart: always
    depends_on:
      - snuba-api
      - kafka
      - clickhouse
    environment:
      SNUBA_SETTINGS: docker
      DEFAULT_BROKERS: kafka:9092
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${REDIS_PASSWORD:-please-change-me}
      CLICKHOUSE_HOST: clickhouse
      KAFKA_HOST: kafka
    command: ["consumer", "--storage", "replays", "--auto-offset-reset", "latest"]
    mem_limit: 512m
    cpus: 0.5

```

---

## 3. 存储与自动清理配置 (sentry.conf.py)

修改挂载的 `./sentry.conf.py` 文件，确保磁盘空间不会被录屏填满。

```python
# 设置错误日志保留时间（30天）
SENTRY_EVENT_RETENTION_DAYS = 30

# 设置录屏回放保留时间（建议 7 天，因数据量极大）
SENTRY_REPLAYS_RETENTION_DAYS = 7

```

---

## 4. 落地与验证步骤

1. **部署生效**：
在服务器执行命令，重新拉起受影响的服务：
```bash
docker-compose up -d

```


2. **前端触发数据**：
刷新前端页面，并进行一些点击操作。确保前端配置了 `replaysSessionSampleRate: 1.0`。
3. **后端日志监控**：
观察消费者是否正常工作，没有报错即代表对接成功：
```bash
docker-compose logs -f snuba-consumer-replays
docker-compose logs -f sentry-ingest-replay-recordings

```


4. **查看结果**：
进入 Sentry Web 界面，点击左侧菜单 **Replays**，此时应能看到用户会话列表及播放按钮。

---

