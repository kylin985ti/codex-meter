# Codex Meter

一个轻量的 macOS 菜单栏工具，同时提供可拖动的桌面浮动卡片，用来显示：

- Codex 短周期与周周期额度的剩余百分比和重置时间
- Codex 今天的 Token 活动和本机估算明细
- Ollama Cloud 的 5 小时 / 7 天额度剩余、重置时间与请求次数

## 数据来源

1. 额度优先通过 Codex 官方 App Server 的 `account/rateLimits/read` 读取。
   为避免 Codex 启动阶段的插件同步造成误判，官方读取最多等待 30 秒；界面会标明
   额度来自实时官方接口还是上次成功的官方快照。Codex 额度不再使用本机日志回退，
   避免旧日志被误当成当前剩余额度。
2. 今日 Token 优先通过官方 `account/usage/read` 读取。
3. 如果当前 Codex CLI 版本还没有 `account/usage/read`，会自动读取
   `~/.codex/sessions` 和 `~/.codex/archived_sessions` 中的 `token_count`
   数字字段进行本机估算。

本机回退模式不会读取会话正文，也不会访问 `~/.codex/auth.json`。本机估算不包含
其他设备、未写入本机日志的云任务或已删除的日志，因此界面会明确标注“本机日志估算”。

### Ollama Cloud

Ollama 部分走官方接口，需要 `OLLAMA_API_KEY`：

- `GET https://ollama.com/api/balance` —— 5 小时与 7 天窗口的剩余百分比、重置时间、随用余额
- `GET https://ollama.com/api/usage?range=24h|7d&scope=self` —— 请求次数

注意线上返回与官方文档存在偏差：`balance` 实际返回 `included.session` / `included.weekly`
的 `remaining_percent`，`usage` 只提供 `request_count`，不含 token 数或美元消耗。
因此 Ollama 区块显示的是剩余百分比与调用次数，不是 token 明细。

API Key 的解析顺序：

1. 环境变量 `OLLAMA_API_KEY`
2. `~/.dsh/.env` 中的 `OLLAMA_API_KEY=...`
3. `~/.codexmeter/config.json` 的 `{"ollamaApiKey": "..."}`

缺少 Key 或 Key 失效时，卡片会显示一行提示，不影响 Codex 部分的显示。

## 使用

1. 从 [Releases](https://github.com/kylin985ti/codex-meter/releases/latest) 下载并解压 `Codex-Meter-macOS-arm64.zip`。
2. 可直接双击 `Codex Meter.app` 试用；也可以双击 `安装 Codex Meter.command`，将它复制到 `~/Applications` 后启动。
3. 首次启动后，菜单栏会出现仪表图标；桌面卡片默认显示在右上角，可随意拖动。
4. 点击菜单栏图标可以刷新、显示/隐藏桌面卡片、打开 Codex 用量页或退出。

当前预编译版本面向 Apple Silicon Mac，并使用 ad-hoc 签名、未经 Apple 公证。如果 macOS 首次启动时拦截，请在 Finder 中右键应用并选择“打开”。

Codex 部分需要本机已安装并登录 Codex CLI。
Codex Meter 会自动寻找常见 Codex CLI 安装位置，包括：

- `~/.npm-global/bin/codex`
- `~/.local/bin/codex`
- `/opt/homebrew/bin/codex`
- `/usr/local/bin/codex`

如 Codex 位于其他位置，可在启动应用前设置环境变量 `CODEX_METER_CODEX_PATH`。

## 从源码构建

只需要 macOS 13 或更高版本和 Apple Command Line Tools，无需完整 Xcode：

```bash
./scripts/build.sh
open "build/Codex Meter.app"
```

构建产物使用本机 ad-hoc 签名，不需要 Apple 开发者账号或证书，适合在这台 Mac 上运行。

## 注意

- “剩余额度”是滚动窗口的百分比，不是可换算的固定剩余 Token 数。
- 官方今日 Token 字段是账号 Token 活动；OpenAI 文档没有承诺日期桶时区。
- 本机日志结构可能随 Codex 版本升级而变化，解析器已对空字段和未知字段做容错。
