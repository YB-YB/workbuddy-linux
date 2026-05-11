[English](#english) | [简体中文](#简体中文)

# 简体中文

# 移植笔记

## 参考项目模式

本项目参考了 `codebuddy-ide-cn-linux` 的本地转换与打包逻辑（同作者的成功移植案例），核心思路是将上游 macOS-only Electron DMG 作为本地输入，转换为 Linux 应用。关键步骤：

1. 使用 `7z`/`7zz` 提取 DMG。
2. 从 `Electron Framework.framework/.../Info.plist` 检测 Electron 版本。
3. 复制应用载荷（app.asar + app.asar.unpacked）。
4. 下载匹配的 Linux Electron runtime。
5. 为 Linux/Electron 重建原生 Node 模块。
6. 写入启动器和原生包。
7. 通过 `install-deps.sh`、`make build-app`、`make package`、`make install` 串起完整本地流程。

重要的法律和工程边界是：生成的载荷是本地产物，不是仓库内容。本项目只采用本地转换、依赖安装和包构建流程，不移植自动更新程序。

## WorkBuddy 与 CodeBuddy 的关键差异

已经检查过的 WorkBuddy macOS bundle 使用：

- 应用显示名：`WorkBuddy`；
- bundle id：`com.workbuddy.workbuddy`；
- Electron：`41.1.1`（CodeBuddy 为 `34.5.1`）；
- 应用版本：`4.22.10`；
- **载荷形式**：`app.asar` + `app.asar.unpacked`（CodeBuddy 用 `app` 目录）；
- URL scheme：`workbuddy`、`codebuddy`；
- 图标文件：`icon.icns`（CodeBuddy 为 `CodeBuddy CN.icns`）；
- 内部 CLI：`@genie/agent-cli`，使用 `@lydell/node-pty` 多平台预编译包。

### 载荷差异详解

CodeBuddy 直接以 `Contents/Resources/app` 目录形式解包，转换器可以直接复制整个目录。

WorkBuddy 使用 `app.asar`（约 196MB）存储主应用代码，同时有 `app.asar.unpacked` 目录存放原生模块和 CLI 等无法打包进 asar 的内容。转换器需要同时复制 `app.asar` 和 `app.asar.unpacked`，并在 `app.asar.unpacked` 目录内重建原生模块。

### 原生模块差异

`app.asar.unpacked/node_modules` 中发现的原生模块：

| 模块 | 版本 | 说明 |
|------|------|------|
| `node-pty` | 1.1.0 | 终端伪终端，有 `prebuilds/` 和 `src/` |
| `better-sqlite3` | 12.8.0 | SQLite 绑定，有 `src/` 和 `build/` |
| `@lydell/node-pty-darwin-arm64` | - | macOS 平台包（需替换为 linux-x64） |
| `@lydell/node-pty-darwin-x64` | - | macOS 平台包（需删除） |
| `@tencent/docs-engine` | - | 腾讯文档引擎 |
| `nunjucks` | - | 模板引擎（纯 JS，无需重建） |

## 首次 Linux 验证清单

把唯一一个官方 Intel/x64 DMG 放入 `downloads/`，然后运行：

```bash
bash scripts/install-deps.sh
make check
make build-app
make package
make install
workbuddy --verbose
```

也可以直接运行未安装的生成应用：

```bash
./workbuddy-app/start.sh --verbose
```

如果 UI 无法打开（无窗口弹出），通常是 GPU 子进程启动失败导致。
启动器已默认添加 `--in-process-gpu` 标志，将 GPU 进程移至主进程内运行。
如需单独调试 GPU 问题，可移除该标志并用以下方式排查：

```bash
# 检查 GPU 子进程是否可以正常启动
./workbuddy-app/start.sh --verbose 2>&1 | grep -i "LaunchProcess\|execvp\|GPU"
```

如果安装后的版本 GPU 子进程启动失败，确认 `chrome-sandbox` 具有 SUID 权限：

```bash
ls -la /opt/workbuddy/chrome-sandbox
# 应显示 -rwsr-xr-x root:root
# 如权限不对，修复：sudo chmod 4755 /opt/workbuddy/chrome-sandbox && sudo chown root:root /opt/workbuddy/chrome-sandbox
```

如果 UI 能打开，但终端或文件监听失败，请检查：

```bash
find workbuddy-app/resources/app.asar.unpacked/node_modules -name '*.node' -print
ldd workbuddy-app/resources/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-x64/node.abi*.node
ldd workbuddy-app/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node
```

如果原生模块重建失败，可以用下面的方式重试：

```bash
ELECTRON_HEADERS_URL=https://artifacts.electronjs.org/headers/dist make build-app
```

---

# English

# Porting Notes

## Reference Project Pattern

This project references the local conversion and packaging logic of `codebuddy-ide-cn-linux` (a successful porting case by the same author). The core idea is to take an upstream macOS-only Electron DMG as local input and convert it into a Linux application. Key steps:

1. Extract the DMG with `7z`/`7zz`.
2. Detect Electron version from `Electron Framework.framework/.../Info.plist`.
3. Copy the app payload (app.asar + app.asar.unpacked).
4. Download the matching Linux Electron runtime.
5. Rebuild native Node modules for Linux/Electron.
6. Write a launcher and native packages.
7. Connect the full local flow through `install-deps.sh`, `make build-app`, `make package`, and `make install`.

The important legal and engineering boundary is that generated payloads are local artifacts, not repository content. This project only adopts the local conversion, dependency installation, and package build flow; it does not port auto-updaters.

## Key Differences Between WorkBuddy and CodeBuddy

The inspected WorkBuddy macOS bundle uses:

- app display name: `WorkBuddy`;
- bundle id: `com.workbuddy.workbuddy`;
- Electron: `41.1.1` (CodeBuddy uses `34.5.1`);
- app version: `4.22.10`;
- **payload format**: `app.asar` + `app.asar.unpacked` (CodeBuddy uses a plain `app` directory);
- URL scheme: `workbuddy`, `codebuddy`;
- icon file: `icon.icns` (CodeBuddy uses `CodeBuddy CN.icns`);
- built-in CLI: `@genie/agent-cli`, uses `@lydell/node-pty` multi-platform prebuilt packages.

### Payload Differences

CodeBuddy unpacks as a `Contents/Resources/app` directory, allowing the converter to copy the directory directly.

WorkBuddy uses `app.asar` (~196MB) to store the main application code, with a separate `app.asar.unpacked` directory for native modules and CLI content that cannot be packed into asar. The converter needs to copy both `app.asar` and `app.asar.unpacked`, rebuilding native modules within the `app.asar.unpacked` directory.

### Native Module Differences

Native modules found in `app.asar.unpacked/node_modules`:

| Module | Version | Notes |
|--------|---------|-------|
| `node-pty` | 1.1.0 | Terminal PTY, has `prebuilds/` and `src/` |
| `better-sqlite3` | 12.8.0 | SQLite bindings, has `src/` and `build/` |
| `@lydell/node-pty-darwin-arm64` | - | macOS platform package (replace with linux-x64) |
| `@lydell/node-pty-darwin-x64` | - | macOS platform package (remove) |
| `@tencent/docs-engine` | - | Tencent Docs engine |
| `nunjucks` | - | Template engine (pure JS, no rebuild needed) |

## First Linux Validation Checklist

Place exactly one official Intel/x64 DMG in `downloads/`, then run:

```bash
bash scripts/install-deps.sh
make check
make build-app
make package
make install
workbuddy --verbose
```

You can also run the generated app before installing it:

```bash
./workbuddy-app/start.sh --verbose
```

If the UI fails to open (no window appears), it is usually caused by GPU subprocess launch failure.
The launcher includes `--in-process-gpu` by default, which runs the GPU process in the main process.
To debug GPU issues separately, remove that flag and check:

```bash
# Check if GPU subprocess can start
./workbuddy-app/start.sh --verbose 2>&1 | grep -i "LaunchProcess\|execvp\|GPU"
```

If the installed version has GPU subprocess launch failures, verify `chrome-sandbox` has SUID permissions:

```bash
ls -la /opt/workbuddy/chrome-sandbox
# Should show -rwsr-xr-x root:root
# If permissions are wrong, fix with: sudo chmod 4755 /opt/workbuddy/chrome-sandbox && sudo chown root:root /opt/workbuddy/chrome-sandbox
```

If the UI opens but terminal or file watching fails, inspect:

```bash
find workbuddy-app/resources/app.asar.unpacked/node_modules -name '*.node' -print
ldd workbuddy-app/resources/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-x64/node.abi*.node
ldd workbuddy-app/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node
```

If native rebuild fails, retry with:

```bash
ELECTRON_HEADERS_URL=https://artifacts.electronjs.org/headers/dist make build-app
```
