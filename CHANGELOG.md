# Changelog

本仓库只发布"转换工程"本身的版本号，**不重发上游 WorkBuddy 安装包**。
"目标上游版本"列出了每次工程改动验证过的官方 macOS DMG 版本，patch 锚点都按这些版本定。
当上游发新版本导致锚点失配时，patcher 会通过 `markRequired/markOptional` 报错或降级，
具体见 `workbuddy-app/.workbuddy-linux/patch-report.json`。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。
版本号采用 `<上游版本>+wb<工程迭代号>`。

---

## [5.0.3+wb3] — 2026-06-13

目标上游版本：WorkBuddy `5.0.3.30150715`（macOS x64 DMG）。

主要解决"装好之后第一条聊天卡死、连接器永远 connecting、Wayland / 现代面板下托盘看不见"
三类问题。所有改动都集成在 `scripts/lib/apply-linux-patches.js` 与 `install.sh` 模板里，
重新执行 `make build-app` 会自动生成。

### Added

- **`scripts/build-appimage.sh`** — 新增 AppImage 打包脚本，自动下载 appimagetool
  并生成 `dist/WorkBuddy-*.AppImage` 便携包。AppRun 自动处理 `--no-sandbox`
  （FUSE 无法使用 setuid sandbox）、`XDG_CURRENT_DESKTOP=Unity` 托盘兼容、
  `MCP_TIMEOUT=3000` 超时兜底，与原生 start.sh 一致。
- **`package.json` 版本自动同步** — `install.sh` 新增 `write_package_version()` 函数，
  在构建时自动从 DMG 的 `Info.plist` 读取 `CFBundleShortVersionString`（如 `5.0.3`），
  同步写入项目级 `package.json` 的 `version` 字段和 `workbuddy-app/.workbuddy-linux/version` 文件，
  并 `export PACKAGE_VERSION` 供下游打包脚本使用。所有打包脚本（deb/rpm/pacman/AppImage）的
  版本号默认从此读取，不再回退到构建时间戳。
- **`build-info.json` 增加 `fullVersion` 字段** — 同时记录 `CFBundleVersion`（构建号），
  如 `5.0.3.30150715`，用于 GitHub Release 的唯一 tag 标识。
- **`.github/workflows/build-release.yml`** — 全自动构建 + 发布工作流：
  - 手动触发，接收官方 DMG 直链作为输入
  - 云端下载 DMG → 构建 Linux 移植版 → 打包 deb/rpm/AppImage
  - 自动读取 DMG 版本号作为 GitHub Release 的 tag（`v5.0.3.30150715`）和标题（`WorkBuddy v5.0.3`）
  - Release 为 Draft 状态，发布前可人工审核

- **`scripts/lib/apply-linux-patches.js` Patch 7A — `ConnectorMcpProxy.maybeInjectNodeRuntime`**
  给 `prepareNodeRuntimeEnv()` 加 5s `Promise.race` 兜底。`BinaryManager.doInitialize()`
  在某些 Linux 环境会永远 pending（即使 24h cache 命中也照样阻塞），
  超时后回退到继承 PATH（系统 node 已就绪），跟原 catch 分支语义一致，避免 stdio MCP 启动卡到上游 122s connect timeout。
- **`scripts/lib/apply-linux-patches.js` Patch 7B — `ConnectorCliExecutor.buildCommandEnv`**
  对 CLI preAuth 路径（tcb / cnpm 等）也加同样的 5s race 兜底。
- **`scripts/lib/apply-linux-patches.js` Patch 7C — `CliExecutor.isCliInstalled`**
  在外层加 6s `Promise.race` 硬超时。已观察到 Electron + Linux 上
  `child_process.exec()` 自带的 `timeout` 选项对 hang 在 syscall 里的子进程不生效
  （`which 'tcb'` 80s+ 不返回，UI 整个卡死）。超时后视为"未安装"，让上层走 install 路径或返回友好错误。
- **`scripts/lib/apply-linux-patches.js` Patch 7D — `ConnectorService.connect`**
  把 `runPreCliAuth()` 整体包进 30s race。preAuth 仅为 CLI 登录态准备，stdio MCP server 本身不强依赖，
  超时后跳过 preAuth 继续走 stdio 启动。
- **`scripts/lib/apply-linux-patches.js` Patch 7E — `SessionManager.composePromptForBackend`**
  对远端 `userPromptComposer.composeUserPrompt()` 加 5s race，超时回退到原始 prompt，
  不让首条聊天消息因 collectors / waitConfiguration 慢响应而卡死。
- **`scripts/lib/apply-linux-patches.js` Patch 7F — `SessionManager.resolveRuntimeConfig`**
  对 `runtimeConfigResolver.resolveConfig()` 加 5s race，超时回退到 `buildFallbackRuntimeConfig()`，
  避免首次 session 启动卡在未就绪的本地 resolver。
- **`install.sh` `write_launcher` — `XDG_CURRENT_DESKTOP="Unity:..."`**
  start.sh 模板里强制把 `Unity` 注入 `XDG_CURRENT_DESKTOP`，
  让 Electron 走 `ayatana-appindicator` (StatusNotifierItem)，
  否则在 Wayland session、waybar、quickshell DMS、KDE Plasma 6 这些只支持 SNI 的面板上托盘图标完全不显示。
  原桌面名保留在串里（`Unity:XFCE` 等），不影响其它依赖 `XDG_CURRENT_DESKTOP` 的程序。
- **`install.sh` `write_launcher` — `MCP_TIMEOUT=3000` 默认**
  启用多个 connector 时，原 30s/server 串行 settle 会让首条 LLM 调用卡到分钟级；
  改成 3s + Promise.race 兜底后健康服务正常使用，慢服务跳过。
- **`scripts/check-portability.sh` 新增两条断言**
  防止后续维护误删上述两条 export，让 `make check` 在 CI / 本地都能立刻拦下。

### Changed

- `scripts/lib/apply-linux-patches.js` 的 `markOptional` 设计原则同步进文件头注释：
  锚点失配时不抛错，仅写 `patch-report.json`，让后续上游变更只影响单个 patch。

### Notes for upgraders

后续上游 WorkBuddy 若发新 DMG：

1. `make build-app DMG=/path/to/new.dmg` 即可，patcher 会从干净 baseline 全量重打。
2. 跑完后看 `workbuddy-app/.workbuddy-linux/patch-report.json`：
   - `required.*` 都为 `true` 才能用；任一为 `false` 时 patcher 会以非零退出码失败。
   - `optional.*` 为 `false` 时会有 stderr 警告，对应 patch 跳过；功能可能退化但不阻塞启动。
3. 若 7A-7F 任一 anchor 失配，最快处理路径：
   - 在 `/tmp/wb503-asar/main/index.js`（解开新 asar 后）grep `prepareNodeRuntimeEnv`、
     `composePromptForBackend`、`resolveRuntimeConfig`、`runPreCliAuth`，对照 anchor 字符串调整。
   - 所有 7x patch 都用紧邻的几行 minified 源码做锚点，新版即使变量名变了，模式一般还在。
- 若上游修复了 `BinaryManager.doInitialize()` 的悬挂、或换了 stdio MCP 启动路径，可考虑下调 7A/7B 超时或直接移除，
  但建议保留 30s 的 7D 兜底（它只在异常路径生效）。

---

## [5.0.3+wb2] — 2026-06-XX

### Added

- Patch 5：Linux 下注入最小化/最大化/关闭三按钮（X11 没有 `titleBarOverlay`，
  Wayland 才支持，我们直接在 renderer 注入 CSS+JS，靠现有 IPC 通道）。
- Patch 6：禁用自动更新菜单与 `update*` RPC（macOS ShipIt / Windows Squirrel 都不适用 Linux）。

### Changed

- `apply-linux-patches.js` 的 marker 升到 `__WB_LINUX_PATCHES_V5__`。
- `cli/dist/codebuddy.js` 三处 minified 锚点修复（agent/command/skill 路径对象兼容）+ session replay 跨项目 fallback。

---

## [5.0.3+wb1] — 2026-06-XX

### Added

- Patch 1：`ACC_PRODUCT_CONFIG_V3` 环境变量 shim — `Object.defineProperty + Proxy` 把
  ~260KB JSON 留在 JS 槽里，不进 libc environ，避免 Linux 128KB MAX_ARG_STRLEN 触发的
  `execve() E2BIG`，否则 Chromium 内部 `/proc/self/exe` 拉网络/GPU/utility 子进程都失败、主窗口起不来。
- Patch 2：Linux 下 tray 菜单改用 `setContextMenu()`（libayatana-appindicator 不发 click 事件，
  上游依赖的 click/right-click 永远收不到）。
- Patch 3：Linux Tray 用磁盘 PNG 路径构造（NativeImage 在 AppIndicator 下渲染成 broken-image）。
- Patch 4：禁用 `Check for Updates...` 菜单。
- Patch 4b：`child_process.spawn/spawnSync` + `node-pty` 双层 wrap，把超长 env 溢出写文件、
  传 `*_FILE` 指针给子进程，sidecar-entry.js 端再读回 — 解决 sidecar / plugin 市场的 spawn E2BIG。
