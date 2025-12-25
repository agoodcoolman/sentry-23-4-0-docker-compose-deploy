# Sentry 23.4.0（Docker Compose 部署后）使用与对接指南（中文）

本文档面向你当前这套 **Sentry 23.4.0 + Docker Compose** 的部署方式（Web 默认地址：`http://<server-ip>:9006`），讲清楚：

- 如何在 Sentry UI 创建项目并获取 DSN
- 如何在常见应用中接入（前端/Node）并验证上报
- （可选）如何做 Release/Commit 关联与 SourceMap
- 如何对接 GitHub（含 self-hosted 场景需要的配置要点）

---

## 1. 前置条件

- 你已经启动了 Sentry（可以打开 `http://<server-ip>:9006`）
- 你已经创建了管理员用户：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm sentry-web sentry createuser
```

---

## 2. 在 Sentry UI 创建项目（Project）

1. 使用管理员账号登录 Sentry Web。
2. 在 UI 中创建 Project（一般会让你选择平台，例如 `JavaScript`、`Node.js`、`Python` 等）。
3. 创建后，Sentry 会在“安装向导/配置片段”里显示 DSN。

> 官方文档要点：DSN 用来告诉 SDK 把事件发到哪个项目。

---

## 3. 获取 DSN（Data Source Name）

### 3.1 去哪里找 DSN

你随时可以在项目设置里找到 DSN：

- **Project** -> **Settings** -> **SDK Setup** -> **Client Keys (DSN)**

### 3.2 DSN 是否可以公开

- DSN **只允许写入（上报事件）**，不允许读取项目数据
- 一般认为 DSN 可以放在前端代码里
- 如果担心被滥用，可以：
  - 在项目设置里 **Rotate / Revoke**（轮换或撤销 DSN）
  - 配合 IP 限制/防火墙/反代层面做限制

### 3.3 DSN 结构（理解用）

DSN 典型格式：

```text
{PROTOCOL}://{PUBLIC_KEY}@{HOST}{PATH}/{PROJECT_ID}
```

---

## 4. 前端接入示例（Browser JavaScript）

### 4.1 安装

```bash
npm i @sentry/browser
```

### 4.2 初始化（最小可用）

在应用入口尽早初始化（例如 `main.js` / `app.js`）：

```js
import * as Sentry from "@sentry/browser";

Sentry.init({
  dsn: "___PUBLIC_DSN___",
});
```

### 4.3 验证是否上报成功

在某个按钮点击、或启动时主动制造一个错误：

```js
throw new Error("Sentry Browser test error");
```

然后回到 Sentry UI：

- **Issues** 页面应该能看到新事件

---

## 5. Node.js 接入示例

### 5.1 安装

```bash
npm i @sentry/node
```

### 5.2 初始化（官方推荐：尽可能早）

在项目根目录创建 `instrument.js`（或 `instrument.mjs`），并确保它在加载其它模块之前执行：

```js
// instrument.js
const Sentry = require("@sentry/node");

Sentry.init({
  dsn: "___PUBLIC_DSN___",
});
```

然后在你的应用启动文件最顶部引入：

```js
require("./instrument");
// ...再 require/import 你的业务代码
```

### 5.3 验证上报

```js
const Sentry = require("@sentry/node");

try {
  throw new Error("Sentry Node test error");
} catch (e) {
  Sentry.captureException(e);
}
```

---

## 6. 常见接入注意事项（强烈建议你做）

- **[release]**
  - 建议设置 `release`（例如 `my-app@1.2.3`），便于回溯版本、做回归分析
- **[environment]**
  - 建议区分环境：`dev` / `staging` / `prod`
- **[采样率]**
  - 性能监控（tracing）建议在生产降低 `tracesSampleRate`（不要长期 1.0）

---

## 7. （可选）Release / Commit 关联 与 SourceMap

把 Release、提交（commits）、SourceMap（前端）关联起来后，你能获得：

- Suspect Commits（嫌疑提交）
- 直接从堆栈跳转到代码行（Stack Trace Linking，需要 SCM 集成）
- 前端线上压缩代码还原（SourceMap）

### 7.1 关键点：Auth Token

通常需要一个 Sentry 的 **Auth Token**（请当作密钥对待，不要提交到仓库）：

- 建议放在 CI 的 Secret，或放在环境变量（例如 `SENTRY_AUTH_TOKEN`）

### 7.2 Webpack（示例思路）

如果你使用 `@sentry/webpack-plugin`，可以配置自动创建 release 并自动关联 commits（示例逻辑）：

- `release.create: true`
- `release.setCommits.auto: true`

> 这部分更推荐在 CI（GitHub Actions）里做，这样 release/commits 能和部署流程绑定。

---

## 8. GitHub 对接（核心：两件事）

- **（A）在 Sentry 中安装 GitHub Integration**：让 Sentry 能读取你的仓库/提交/PR，并实现 Stack Trace Linking、Suspect Commits 等
- **（B）把 release/commit 信息“发给 Sentry”**：否则仅安装集成，Sentry 也很难知道“哪个 commit 在哪个 release 里”

---

## 9. GitHub Integration（github.com）在 UI 中安装（推荐优先尝试）

官方安装流程要点（从 Sentry UI 发起更顺滑）：

1. Sentry -> **Settings** -> **Integrations** -> **GitHub**
2. 点击 **Install**（或从 legacy Upgrade）
3. 在弹窗中点 **Add Installation**
4. 跳转到 GitHub 的安装页面，选择要授权的 repos（或 all）
5. 回到 Sentry 集成页，点 **Configure**
6. 默认会添加所有仓库；如只选部分仓库，在下拉里选择

常见问题：

- 如果仓库列表不出现：检查 GitHub 侧是否已给 **Sentry GitHub App** 访问权限

---

## 10. self-hosted 场景下 GitHub Integration 的关键配置点（你这种自建 Sentry 也适用）

当你的 Sentry 不在 sentry.io，而是在你自己的域名/服务器上时，GitHub 侧会涉及回调与 webhook，关键在于：

### 10.1 必须有一个外部可访问的 URL（url-prefix / system.url-prefix）

- 你的 Sentry 必须用一个 **外部可访问的完整 URL**（FQDN，建议 HTTPS）
- 否则常见现象：
  - DSN 域名为空
  - 邮件里的链接点不开
  - 配置集成时出现 CSRF/回调失败

在 self-hosted 的官方部署里，这个配置叫：

- `system.url-prefix`

> 你当前是“简化 compose 方案”，没有 `self-hosted` 仓库的 `sentry/config.yml`，但原理一样：需要让 Sentry 知道它对外的访问地址，并保证反代/HTTPS 正确。

### 10.2 创建 GitHub App（用于 SSO & Integration）

官方 self-hosted 文档强调：

- GitHub App 的 **名称不能包含空格**
- `url-prefix` 需要替换成你自己的地址，例如：`https://sentry.example.com`

GitHub App 常见需要的 URL（文档给出的模板）：

- Homepage URL: `${url-prefix}`
- Callback URL: `${url-prefix}/auth/sso/`
- Setup URL: `${url-prefix}/extensions/github/setup/`
- Webhook URL: `${url-prefix}/extensions/github/webhook/`

### 10.3 在 Sentry 侧配置 GitHub App 凭据

官方 self-hosted 文档给的配置项（在 `config.yml` 或 `sentry.conf.py` 的 `SENTRY_OPTIONS`）包括：

- `github-app.id`
- `github-app.name`
- `github-app.client-id`
- `github-app.client-secret`
- `github-app.webhook-secret`
- `github-app.private-key`（注意要多行字符串，且每行行首不要有多余空格）

> 你当前 compose 方案已经在挂载 `./sentry.conf.py`。如果你要走“self-hosted GitHub App”这条路，建议把对应的 `SENTRY_OPTIONS[...]` 写到你挂载的 `sentry.conf.py` 里，然后重建 `sentry-web`/`sentry-worker`。

---

## 11. GitHub 对接后的使用方式（最有价值的 2 个点）

### 11.1 Suspect Commits（嫌疑提交）

当你配置了 commit tracking，并且 release 包含 commits 时，Issue 详情里会显示：

- 可疑提交
- 提交作者（可作为建议指派人）

### 11.2 通过 Commit / PR 自动关闭 Issue

官方推荐格式：在 commit message 或 PR 描述中包含：

```text
fixes <SENTRY-SHORT-ID>
```

Sentry 会在看到该提交/PR 并且它进入某个 release 后，把对应 Issue 标记为已解决。

---

## 12. GitHub 集成排错清单（你用自建 Sentry 时最常用）

- **[外网可访问]**
  - GitHub 需要能访问你的 `${url-prefix}`（用于回调与 webhook）
  - 不能只是在内网 IP 或 localhost
- **[域名/证书/HTTPS]**
  - 强烈建议用 HTTPS + 反向代理
  - 回调 URL 的 scheme/host 必须与你在 Sentry 中配置的一致
- **[Webhook 收不到]**
  - 检查防火墙/安全组是否放行
  - 检查反代是否把 `/extensions/github/webhook/` 转发到了 Sentry
- **[仓库列表不出现]**
  - 检查 GitHub App 安装时是否授予了对应仓库权限
- **[需要代理才能访问外网]**
  - 如果容器无法直连外网，需要配置 HTTP 代理，并正确设置 `no_proxy`（至少包含 `redis/postgres/kafka/clickhouse/snuba-api/symbolicator` 等服务名）

---

## 13. 你下一步建议怎么做（按顺序）

1. 先在 UI 创建一个测试 Project，拿到 DSN
1. 先接入最简单的 `@sentry/browser` 或 `@sentry/node`，确认 Issues 能收得到
1. 再安装 GitHub Integration（优先走 UI 安装）
1. 最后再做 release/commit/source map 自动化（CI 里做）

---

## 14. （重要）Relay + Nginx 与 Tunnel/DSN（避免 CSRF 403）

当你使用浏览器 SDK 或通过后端 tunnel 转发 envelope 时，建议使用 `nginx -> relay -> sentry-web` 的链路作为对外入口。

本仓库已提供对应的 `docker-compose.yml` 改造与配置文件，执行步骤见：

- `README-RELAY-NGINX.md`
