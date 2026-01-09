# 本周变更清单（周报素材）

> 说明：这份清单只记录“我们在仓库里实际动过的文件/配置方向”和“排障过程中的关键决策”。
> 由于你要求“不要再乱改”，目前状态以 **已回退到可启动** 为准。

---

## 1. 目标与背景
- **目标**：在 self-hosted Sentry 23.4.0 环境下启用/验证 Replay 链路，并解决 Relay 对 replay 数据的 rate limit（dropped）问题。
- **问题现象**：
  - Relay 报 `rate limited` 导致 replay envelope 被丢弃。
  - 试图通过 `SENTRY_DISABLE_QUOTAS_AND_RATELIMITS=true` 绕过配额时，出现 `NoopQuota/DummyRateLimiter not found` 之类错误。

---

## 2. 已改动（代码/配置）——并已全部回退
> 下面这些改动都曾做过，但**目前已回退**，以保证环境可正常启动。

### 2.1 `d:/project/sentry/replay/sentry.conf.py`
- **做过的改动（已回退）**
  - 注入自定义的 `sentry_noop_backends` 模块，尝试提供：
    - `NoopRateLimiter`
    - `NoopQuota`
    - `ReplayAwareRedisQuota`（对 replay 类别做精细化 quota 控制）
  - 增加环境变量逻辑：
    - `SENTRY_DISABLE_QUOTAS_AND_RATELIMITS`
    - `SENTRY_REPLAY_KEY_RATE_LIMIT`
    - `SENTRY_REPLAY_KEY_RATE_WINDOW`
    - `SENTRY_REPLAY_SKIP_KEY_QUOTA`
  - 为排障临时打印注入失败原因（init errors）。

- **回退后的当前状态**
  - `SENTRY_RATELIMITER = "sentry.ratelimits.redis.RedisRateLimiter"`
  - `SENTRY_QUOTAS = "sentry.quotas.redis.RedisQuota"`
  - 不再包含 `sentry_noop_backends` 动态注入逻辑。

### 2.2 `d:/project/sentry/sentry.conf.py`
- **做过的改动（已回退）**
  - 与 `replay/sentry.conf.py` 同步：注入 `sentry_noop_backends`、加入 replay quota 控制逻辑。

- **回退后的当前状态**
  - 恢复默认 `RedisRateLimiter + RedisQuota`。

### 2.3 `d:/project/sentry/replay/docker-compose.yml`
- **做过的改动（已回退）**
  - 给多个 sentry 服务容器注入 replay/quota 相关 env：
    - `SENTRY_DISABLE_QUOTAS_AND_RATELIMITS`
    - `SENTRY_REPLAY_SKIP_KEY_QUOTA`
    - `SENTRY_REPLAY_KEY_RATE_LIMIT`
    - `SENTRY_REPLAY_KEY_RATE_WINDOW`

- **回退后的当前状态**
  - 已移除上述 env，compose 回到 baseline。

---

## 3. 排障过程中的关键发现（非改动，但可写周报）
### 3.1 Replay 链路是“多段管道”，不是只看 Relay
- 浏览器 SDK 发 replay envelope（`replay_event` + `replay_recording`），Relay 只是入口。
- 后端还需要：Kafka topic + `ingest-replay-recordings` consumer + `snuba-...replays...consumer` + ClickHouse + UI 查询。
- 官方 self-hosted compose（master）明确包含 replay 相关 consumer：
  - `ingest-replay-recordings`
  - `rust-consumer --storage replays`

来源：
- <https://raw.githubusercontent.com/getsentry/self-hosted/master/docker-compose.yml>

### 3.2 社区对 23.4.0 Replay 的稳定性有大量 issue
- 有报告指出 23.3.1（也包含 23.4.0、23.5.0）会出现 replay 200 但不处理。
  - <https://github.com/getsentry/self-hosted/issues/2057>
- 也有 snuba replays consumer 写入 ClickHouse 报错导致 UI 无数据的案例。
  - <https://github.com/getsentry/self-hosted/issues/2002>

### 3.3 “禁用 quota”在 23.4.0 不是一个开箱即用的开关
- 你遇到的 `NoopQuota` / `DummyRateLimiter` 缺失，说明 23.4.0 并没有提供这些类作为公共配置项。
- 我们尝试用 Python 动态注入实现，但引发了循环导入等启动不稳定问题，因此最终选择回退。

---

## 4. 当前状态
- 已完成：
  - 所有“自定义 quota/Replay 控制”的代码与 compose 改动全部回退
  - 环境应可恢复正常启动（回到默认 RedisQuota/RedisRateLimiter）
- 进行中：
  - 收集可引用的 Replay 支持/成功案例/版本建议，并整理成单独文档（`REPLAY_COMPATIBILITY.md`）

---

## 5. 下周计划（建议写在周报里）
- **只做观测与验证，不改逻辑**：
  - 核对 replay 相关 consumer 是否齐全、Kafka topic 是否持续增长
  - 若 Relay rate limited，先确认 ProjectConfig 下发 quotas 的内容与类别匹配
- **根据可引用案例与官方配置清单**，确定：
  - 23.4.0 在 self-hosted 下 Replay 是否需要额外的 feature flag（以及具体 flag）
  - 前端 SDK 版本 pin 的基线组合（以“可解释/可回退”为原则）
