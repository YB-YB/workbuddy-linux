# WorkBuddy 原生模块审计报告

## 全量 `.node` / `.dylib` 预编译文件清单

路径: `app.asar.unpacked/`

### 1. `node_modules/node-pty` — **关键模块，需从源码重建**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `prebuilds/darwin-arm64/pty.node` | Mach-O | ❌ 删除 |
| `prebuilds/darwin-x64/pty.node` | Mach-O | ❌ 删除 |
| `prebuilds/win32-arm64/pty.node` | PE | ❌ 删除 |
| `prebuilds/win32-arm64/conpty.node` | PE | ❌ 删除 |
| `prebuilds/win32-arm64/conpty_console_list.node` | PE | ❌ 删除 |
| `prebuilds/win32-x64/pty.node` | PE | ❌ 删除 |
| `prebuilds/win32-x64/conpty.node` | PE | ❌ 删除 |
| `prebuilds/win32-x64/conpty_console_list.node` | PE | ❌ 删除 |

**处理**: 从 npm 拉取 `node-pty@1.1.0` 源码，针对 Electron 41.1.1 + Linux 重新编译，整个模块替换。

### 2. `node_modules/better-sqlite3` — **关键模块，需从源码重建**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `build/Release/better_sqlite3.node` | Mach-O | ❌ 需重建 |
| `build/Release/test_extension.node` | Mach-O | ❌ 需重建 |
| `bin/darwin-x64-145/better-sqlite3.node` | Mach-O prebuild | ❌ 删除 |

**处理**: 从 npm 拉取 `better-sqlite3@12.8.0` 源码重新编译，整个模块替换。

### 3. `node_modules/@lydell/node-pty-darwin-arm64` — **macOS 平台包**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `prebuilds/darwin-arm64/pty.node` | Mach-O | ❌ 整个包删除 |

**处理**: 删除，安装 `@lydell/node-pty-linux-x64@1.2.0-beta.12` 替代。

### 4. `node_modules/@lydell/node-pty-darwin-x64` — **macOS 平台包**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `prebuilds/darwin-x64/pty.node` | Mach-O | ❌ 整个包删除 |

**处理**: 删除。

### 5. `node_modules/@tencent/docs-engine` — **⚠️ 腾讯私有模块，无法重建**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `lib/darwin-arm64/libeditor_sdk_ffi.dylib` | Mach-O (206MB) | ⚠️ 无法替换 |
| `lib/darwin-arm64/start_server_addon.node` | Mach-O | ⚠️ 无法替换 |
| `lib/darwin-arm64/icudt72l.dat` | 数据文件 | ✅ 平台无关 |

**处理**: 这是 WorkBuddy 内部的私有模块（`@tencent/docs-engine`），npm 上不存在，无法从源码重建。只有 `darwin-arm64` 目录（甚至没有 `darwin-x64`），说明这个模块只为 Apple Silicon 预编译了。在 Linux 上此模块**不可用**，需删除。该模块是腾讯文档编辑引擎，不影响 WorkBuddy 的核心 AI 编码功能。

### 6. `node_modules/nunjucks/node_modules/fsevents` — **macOS 专用模块**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `build/Release/fse.node` | Mach-O | ❌ 整个包删除 |
| `build/Release/.node` | Mach-O | ❌ 整个包删除 |

**处理**: `fsevents` 是 macOS 文件系统事件 API 的绑定，Linux 上不存在也不需要（Linux 用 `inotify`）。直接删除整个包。

### 7. `cli/node_modules/@lydell/node-pty-darwin-arm64` — **CLI 的 macOS 平台包**

**处理**: 删除，安装 `@lydell/node-pty-linux-x64@1.2.0-beta.12` 替代。

### 8. `cli/node_modules/@lydell/node-pty-darwin-x64` — **CLI 的 macOS 平台包**

**处理**: 删除。

### 9. `cli/vendor/ripgrep/x64-darwin/` — **CLI 的 ripgrep macOS 二进制**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `rg` | Mach-O 可执行文件 | ❌ 需替换 |
| `ripgrep.node` | Mach-O | ❌ 需替换 |

**处理**: 需要下载 Linux x64 版的 `@vscode/ripgrep` 或从系统安装 `ripgrep` 二进制，替换为 `x64-linux/` 目录。

### 10. `cli/vendor/sandbox/` — **Windows + macOS 混合二进制**

| 文件 | 格式 | 处理方式 |
|------|------|---------|
| `sandbox-cli` | macOS Mach-O 可执行文件 (5MB) | ⚠️ 无法替换 |
| `sandbox-cli.exe` | Windows PE | ❌ 删除 |
| `sandbox_ffi.dll` | Windows PE | ❌ 删除 |
| `tsbx.dll` | Windows PE | ❌ 删除 |
| `tsbx_sdk.dll` | Windows PE | ❌ 删除 |
| `tsbx_rules.json` | JSON | ✅ 保留 |

**处理**: Windows DLL 全部删除。macOS `sandbox-cli` 与底下的 `tsbx` 系列动态库同属于腾讯内部私有的代码执行沙盒引擎（Tencent Sandbox），在 npm 或开源社区没有对应的 Linux 版本。因此此沙盒功能在 Linux 上不可用（降级为无沙盒执行）。

## 处理策略总结

| 策略 | 模块 |
|------|------|
| **从源码重建** | `node-pty@1.1.0`, `better-sqlite3@12.8.0` |
| **安装 Linux 平台包替代** | `@lydell/node-pty-linux-x64@1.2.0-beta.12` (两处) |
| **下载 Linux 版替换** | `cli/vendor/ripgrep` (ripgrep Linux binary) |
| **直接删除（macOS 专用）** | `fsevents`, `@lydell/node-pty-darwin-*` (四处) |
| **直接删除（Windows 专用）** | sandbox `*.dll/*.exe` |
| **无法移植（私有模块）** | `@tencent/docs-engine` (腾讯文档引擎，可选功能) |
| **无法移植（私有模块）** | `cli/vendor/sandbox/sandbox-cli` (腾讯私有代码沙盒) |
