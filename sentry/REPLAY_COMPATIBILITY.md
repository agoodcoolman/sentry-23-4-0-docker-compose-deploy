# Sentry 23.4.0 Self-Hosted Replay：支持情况、成功案例线索与版本建议

## 结论（基于可引用来源）
- **Self-hosted 是支持 Session Replay 的**：getsentry/self-hosted 的 Issue **#1873** 明确提到“让 Self-Hosted 也可用 Session Replay”，并在 2023-02-28 标记“Closed by #1990”（说明该能力通过 PR 合入 self-hosted 流水线/配置）。
  - 来源：<https://github.com/getsentry/self-hosted/issues/1873>
- **但 23.3.x~23.5.x 时期 Replay 在 self-hosted 仍有大量“200 但看不到/不处理”的社区报告**：Issue **#2057** 报告 self-hosted **23.3.1（也包含 23.4.0、23.5.0）** 的 replay 200 响应但后端不处理。
  - 来源：<https://github.com/getsentry/self-hosted/issues/2057>
- **Replay 的链路依赖多服务**，只要缺任意一个消费者/存储组件，会出现“请求进来了但 UI 没东西 / 详情 404”等现象。
  - 官方 self-hosted `docker-compose.yml`（master）明确包含：
    - `ingest-replay-recordings`（Sentry consumer）
    - `snuba-*-replays-consumer`（Snuba replays consumer，消费 replay 事件并写 ClickHouse）
    - `relay`（入口/鉴权/转发）
  - 来源：<https://raw.githubusercontent.com/getsentry/self-hosted/master/docker-compose.yml>

> 这份文档的目标是：在**不“乱改代码”**的前提下，给出你当前 23.4.0 环境“Replay 是否支持、需要哪些容器、前端 SDK 建议版本、排障方向”的一份可落地检查表。

---

## 你的环境（你提供的信息）
- **Sentry / Relay 镜像**：`getsentry/sentry:23.4.0`、`getsentry/relay:23.4.0`
- **Docker**：23.0.1
- **Docker Compose**：v2.15.1

对比社区案例（不是硬性要求，只是参考）：
- Issue #2057 报告的环境：Docker 20.10.12、Compose 1.29.2（仍出现 replay 不可用）
- Issue #2817 报告的环境：Docker 24.0.7、Compose v2.18.1（请求进来但 UI 不显示）
  - 来源：<https://github.com/getsentry/self-hosted/issues/2817>

**结论**：Docker/Compose 版本通常不是“Replay 不可用”的主要矛盾（社区跨版本都有问题报告）。更关键是：
- self-hosted 组件是否齐全
- Kafka topic/consumer 是否跑起来
- Snuba replays consumer 是否正常写入 ClickHouse
- Sentry web 是否能查询到 replay 数据并正确渲染

---

## Replay 在 self-hosted 的端到端链路（你排障必须对齐这个模型）
### 1) 浏览器 SDK 发出的 envelope 结构
Sentry 官方开发者文档给出了 replay envelope 的形式：一个 envelope 同时包含
- `replay_event` item
- `replay_recording` item（通常为 gzip 的 JSON payload）

来源：
- <https://develop.sentry.dev/sdk/telemetry/replays/>

这意味着：
- Relay/Sentry 入口必须能接受这两种 item
- Kafka/Snuba 后端必须能消费并落库

### 2) self-hosted 需要的关键服务（官方 compose 为准）
官方 self-hosted compose（master）中可明确看到 Replay 相关服务：
- `ingest-replay-recordings`: `run consumer ingest-replay-recordings ...`
- `snuba-...replays...consumer`: `rust-consumer --storage replays ...`

来源（官方 compose）：
- <https://raw.githubusercontent.com/getsentry/self-hosted/master/docker-compose.yml>

> 你现在的 `replay/docker-compose.yml` 里确实包含类似的 `sentry-ingest-replay-recordings` 与 `snuba-consumer-replays`，这方向是对的。

---

## 社区案例归纳（“别人确实跑过/也踩过坑”）
> 这里我只列“可引用的事实”，不编结论。

### Case A：23.3.1（也包含 23.4.0、23.5.0）Replay 200 但不处理
- 报告：replay session 200，但后端看不到/没处理
- 版本：23.3.1（also 23.4.0、23.5.0）
- SDK：Vue JS SDK
- 来源：<https://github.com/getsentry/self-hosted/issues/2057>

### Case B：23.3.0.dev0 Snuba replays consumer 写 ClickHouse 失败
- 报告：Sentry 说收到第一条 replay，但列表不显示；`snuba-replays-consumer` 报 ClickHouse JSON 解析错误
- 来源：<https://github.com/getsentry/self-hosted/issues/2002>

这说明 replay 在早期版本中属于“功能存在但稳定性/兼容性需跟版本走”的典型。

### Case C：23.11.1 请求进来但 UI 不显示/播放器无内容
- 报告：请求进来了，但 UI 看不到录像播放器
- 来源：<https://github.com/getsentry/self-hosted/issues/2817>

### Case D：24.2.0 Replay 详情 404（通常意味着缺容器/缺后端路由/缺数据）
- 维护者回复提到：“404 说明你可能没跑齐所有需要的容器”。
- 来源：<https://github.com/getsentry/self-hosted/issues/3274>

---

## 前端 SDK 版本建议（针对 23.4.0，自洽优先）
你之前的直觉“可能是前端问题”是合理的：Replay 的 envelope 结构、压缩格式、item 类型都受 SDK 版本影响。

### 建议原则（保守且可解释）
- **尽量使用与后端年代接近的 JS SDK 大版本**（避免出现后端不认识的新字段/新 item）。
- 从官方 replay envelope 示例可以看到 JS SDK `7.105.0` 在 2024 仍使用 replay_event + replay_recording；但不同版本可能在 payload 细节上有变化。
  - 来源：<https://develop.sentry.dev/sdk/telemetry/replays/>

### 可操作建议（你当前环境）
- **前端优先使用 `@sentry/*` 的 7.x 系列**（而不是 8.x/9.x）作为排障基线。
- 如果你需要我给出一个“可回退、可复现”的精确版本组合，我会：
  - 以 `getsentry/self-hosted` 在 23.4.0 时间窗口对应的文档/锁定依赖为准
  - 再结合社区 issue 中提到的 Vue SDK 版本范围，给出建议

> 这里我不会在没有你项目 `package.json`/锁文件上下文的情况下随口报一个“神奇版本号”。如果你愿意，我可以在下一步只做“文档化建议”，不改代码：读取你前端工程依赖并给出一组严格可解释的版本 pin。

---

## 你当前（23.4.0）要跑通 Replay 的最低检查表（不改代码版本）
按顺序排除：
1. **入口确认**：浏览器 → Nginx → Relay → Sentry ingest 走通
2. **Kafka topic 确认**：`ingest-replay-recordings` / `ingest-replay-events` 相关 topic 持续增长
3. **Consumer 确认**：
   - `sentry-ingest-replay-recordings` 容器稳定运行
   - `snuba-consumer-replays` 容器稳定运行（无持续 crash）
4. **ClickHouse 落库确认**：Snuba replays consumer 不报写入错误
5. **UI 查询确认**：项目 Replays 列表能拉到数据；详情页不 404

这 5 步里，**任何一步失败都会出现“200 但看不到”的错觉**。

---

## 下一步我建议你怎么推进（仍然不改代码）
- **先把你现在的 23.4.0 环境恢复启动并稳定运行**（你已经要求回退，我也已完成回退）。
- 然后我建议只做“观测/验证”而不是改逻辑：
  - Relay 日志（是否 dropped / rate limited / processing）
  - Kafka topic lag
  - Snuba replays consumer 是否报错

如果你确认要继续深挖，我会在文档里给出：
- 精确的“应该出现哪些 topic、哪些 consumer group、哪些 ClickHouse 表/数据集”的对照表
- 以及针对 23.4.0 的最小排障命令（只读）

---

## 引用来源清单
- self-hosted 支持 Replay 的里程碑：<https://github.com/getsentry/self-hosted/issues/1873>
- 23.4.0 相关 replay 不处理报告：<https://github.com/getsentry/self-hosted/issues/2057>
- Snuba replays consumer ClickHouse 写入错误案例：<https://github.com/getsentry/self-hosted/issues/2002>
- 23.11.1 请求进来但 UI 不显示案例：<https://github.com/getsentry/self-hosted/issues/2817>
- 24.2.0 replay 详情 404（可能缺容器）案例：<https://github.com/getsentry/self-hosted/issues/3274>
- 官方 Replay envelope/行为说明：<https://develop.sentry.dev/sdk/telemetry/replays/>
- 官方 self-hosted compose（服务清单参考）：<https://raw.githubusercontent.com/getsentry/self-hosted/master/docker-compose.yml>
