#!/bin/bash
set -Eeuo pipefail

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

grep -q 'WORKBUDDY_DISABLE_SANDBOX' install.sh || fail "start.sh must gate sandbox fallback behind WORKBUDDY_DISABLE_SANDBOX"
if grep -n '^  --no-sandbox \\' install.sh >/dev/null; then
    fail "start.sh must not pass --no-sandbox by default"
fi

# [wb-linux] start.sh template must inject Unity into XDG_CURRENT_DESKTOP so
# Electron uses ayatana-appindicator (SNI) instead of GtkStatusIcon. Without
# this the tray icon disappears on Wayland sessions and on panels that only
# implement StatusNotifierItem (waybar, quickshell DMS, KDE Plasma 6).
grep -q 'Unity:\\${XDG_CURRENT_DESKTOP' install.sh || fail "start.sh template must inject Unity into XDG_CURRENT_DESKTOP for SNI tray support"

# [wb-linux] start.sh template must default MCP_TIMEOUT so a slow / hung
# stdio MCP server can't block the first chat message for the upstream 30s.
grep -q 'MCP_TIMEOUT:-3000' install.sh || fail "start.sh template must default MCP_TIMEOUT to 3000ms"

# AppImage builder must exist and have correct shebang
[ -f scripts/build-appimage.sh ] || fail "AppImage builder script missing"
grep -q 'set -Eeuo pipefail' scripts/build-appimage.sh || fail "AppImage builder must have pipefail"
grep -q 'appimagetool' scripts/build-appimage.sh || fail "AppImage builder must reference appimagetool"

# AppImage builder must be registered in Makefile and package.sh
grep -q 'appimage:' Makefile || fail "Makefile must have appimage target"
grep -q 'bash scripts/build-appimage.sh' Makefile || fail "Makefile appimage target must invoke build-appimage.sh"
grep -q 'appimage)' scripts/package.sh || fail "package.sh must handle appimage format"

# install.sh must sync the upstream DMG version to the project-level
# package.json and export PACKAGE_VERSION for downstream packaging.
grep -q 'write_package_version' install.sh || fail "install.sh must have write_package_version function"
grep -q "p.version = '" install.sh || fail "install.sh must patch version into package.json via node"
grep -q 'export PACKAGE_VERSION' install.sh || fail "install.sh must export PACKAGE_VERSION"
grep -q 'resolve_package_version' scripts/lib/common.sh || fail "common.sh must provide resolve_package_version helper"

grep -q 'lydell_node_pty_linux_package()' scripts/lib/native-modules.sh || fail "missing shared @lydell platform mapping"
grep -q '@tencent/docs-engine/lib/darwin-arm64' scripts/lib/native-modules.sh || fail "missing @tencent/docs-engine darwin-arm64 cleanup"
grep -q 'cli/vendor/sandbox/sandbox-cli.exe' scripts/lib/native-modules.sh || fail "missing Tencent Sandbox Windows executable cleanup"
grep -q 'cli/vendor/sandbox/sandbox_ffi.dll' scripts/lib/native-modules.sh || fail "missing Tencent Sandbox DLL cleanup"
grep -q 'Mach-O executable' scripts/lib/native-modules.sh || fail "missing Mach-O executable cleanup"
grep -q 'native-cleanup-report.json' scripts/lib/native-modules.sh || fail "missing native cleanup report"
grep -q '<@lydell/node-pty-linux-arch>' scripts/lib/apply-linux-patches.js || fail "patcher must require an explicit @lydell platform package argument"
grep -q 'assertRequiredPatches()' scripts/lib/apply-linux-patches.js || fail "patcher must fail when required patches are missing"
grep -q 'patch-report.json' scripts/lib/apply-linux-patches.js || fail "patcher must write patch-report.json"

if grep -n "node-pty-linux-x64" scripts/lib/native-modules.sh | grep -v 'x86_64)' | grep -v '^.*#' >/dev/null; then
    fail "native module flow still hard-codes node-pty-linux-x64 outside the architecture mapping"
fi

if grep -n "node-pty-linux-x64" scripts/lib/apply-linux-patches.js | grep -v '^.*//' >/dev/null; then
    fail "patcher still hard-codes node-pty-linux-x64"
fi

echo "portability-check-ok"
