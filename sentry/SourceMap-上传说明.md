# 前端 SourceMap 生成与上传（内网 + Docker）

## 1. 你的现状与目标

- 前端项目：`d:\workspace\jiwei-xunshixuncha\qianduan`（Vite）
- 你每次正式编译使用：`npm run build:prod`
- 内网环境：只有静态产物（Nginx）+ Docker，没有 npm
- 需求：
  - 正式构建产出 sourcemap（`.map`）
  - 把 sourcemap（以及必要的版本信息）搬到内网
  - Docker 重启/上线时执行脚本，把 sourcemap 上传到你们自建 Sentry

## 2. Vite 怎么“正式编译生成 SourceMap”

项目已经在 `qianduan/vite.config.js` 配置了：

- 仅当 `vite build` 且 `mode === 'production'`（或 `VITE_APP_ENV === 'production'`）时：`build.sourcemap = true`
- 其他模式（`npm run dev`、`build:test`、`build:stage`）默认不生成 `.map`

因此你的固定编译命令：

- `npm run build:prod`（等价于 `vite build`，默认 `mode=production`）

编译后产物通常在 `qianduan/dist/`：

- `dist/assets/*.js`
- `dist/assets/*.js.map`

> 注意：SourceMap 属于敏感资产，建议不要通过公网/Nginx 直接暴露访问。

## 3. 每次编译 sourcemap 不同，应该怎么处理（必须有 release）

Sentry 还原堆栈的核心是：**事件（event）的 `release` 和 sourcemap 上传时的 `release` 必须一致**。

推荐 release 规则：

- `ghhy-bi@<gitCommit>`（推荐）
- 或 `ghhy-bi@<版本号>+<构建时间>`

### 3.1 前端如何上报 release

前端入口 `qianduan/src/main.js` 已支持读取：

- `VITE_SENTRY_RELEASE`

你在构建时把它注入即可。

你已经在 `qianduan/.env.production` 增加了 `VITE_SENTRY_RELEASE=...`，当你用 `--mode production` 构建时，这个值会被 Vite 注入到产物中，最终被 Sentry SDK 当作 `release` 上报。

### 3.2 如何在编译时根据 git 自动生成 release

推荐使用 git commit 作为 release（可追溯、不会重复）：

- 例：`jiwei-xunshixuncha@<git-short-sha>`

你可以在构建机/CI 里执行构建前设置环境变量（不要写死在仓库里）：

- Windows PowerShell（示例）：
  - `$env:VITE_SENTRY_RELEASE = "jiwei-xunshixuncha@" + (git rev-parse --short HEAD)`
  - `npm run build:prod`

- Linux/macOS（示例）：
  - `export VITE_SENTRY_RELEASE="jiwei-xunshixuncha@$(git rev-parse --short HEAD)"`
  - `npm run build:prod`

## 4. 仅正式环境对接 Sentry；dev/test 关闭

`qianduan/src/main.js` 现在的逻辑是：

- 默认：只有 `import.meta.env.MODE === 'production'` 才会 `Sentry.init(...)`
- 可用 `VITE_SENTRY_ENABLED` 强制覆盖：
  - `true`：强制开启
  - `false`：强制关闭

这意味着：

- `npm run dev`：默认不接 Sentry（满足你“测试环境不对接 sentry”）

## 5. 内网无 npm：如何上传 sourcemap 到 Sentry（推荐方案）

推荐在内网机器（有 Docker）上使用 `getsentry/sentry-cli` 镜像上传 sourcemap。

你只需要把以下内容拷贝到内网：

- 前端静态产物：`dist/`（Nginx 用）
- sourcemap：`dist/**/*.map`（不要被 Nginx 暴露）
- 上传脚本：本目录的 `upload-sourcemaps.sh`

脚本会做：

- 创建 release（如果不存在）
- 上传 `dist` 下的 sourcemap 到对应的 org/project/release

## 6. Docker / docker-compose 重启时如何触发脚本

### 6.1 手动执行（最稳）

你每次在内网更新静态文件后：

- 先重启 Nginx 容器（或你前端容器）
- 再手动执行：`sh upload-sourcemaps.sh`

这种方式最简单，且不依赖 docker-compose 支持 post-start hook。

### 6.2 用 docker-compose 触发（可选，常见做法）

docker-compose 本身没有“容器启动完成后自动执行宿主机脚本”的官方 hook；但可以用以下折中方式：

- 方式 A：新增一个一次性服务（one-shot）
  - `depends_on: [nginx]`
  - command 里调用 `sh /scripts/upload-sourcemaps.sh`
  - 每次 `docker compose up -d` 后，再 `docker compose run --rm sourcemap-uploader`

- 方式 B：把上传脚本放到 Nginx 容器里做 entrypoint 包装
  - 先启动 Nginx
  - 再调用上传脚本
  - 风险：会把“上传失败”与“容器启动”强绑定，可能导致启动受影响

如果你把你的 compose 片段（nginx 服务名、挂载目录、dist 路径）贴我一下，我可以按你现有 compose 写一个最小改动的接法。

## 7. 你需要填写的参数（脚本顶部）

`upload-sourcemaps.sh` 顶部需要你填：

- `SENTRY_URL`（例如 `http://192.168.3.153:9006`）
- `SENTRY_AUTH_TOKEN`（你说的大概率用 token）
- `SENTRY_ORG`、`SENTRY_PROJECT`
- `RELEASE`（必须与前端 `VITE_SENTRY_RELEASE` 一致）
- `DIST_DIR`（内网 dist 目录路径）
- `URL_PREFIX`
  - 你现在的线上资源前缀是 `http://ip/assets`
  - 但 Sentry CLI 的 `--url-prefix` 通常应使用 `~/assets` 这种格式（不要带 host）
  - 本项目的 `upload-sourcemaps.sh` 已支持你直接填 `http://ip/assets`，脚本会自动归一化成 `~/assets`

> `org/project` 你可以在 Sentry Web 的 Project 设置里看到；如果不确定，把项目页面 URL 或截图发我，我帮你定位。
