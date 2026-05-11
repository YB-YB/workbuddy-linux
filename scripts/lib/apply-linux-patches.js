#!/usr/bin/env node
/**
 * Patch main/index.js inside a WorkBuddy app.asar so it runs on Linux.
 *
 * Fixes applied:
 *   1. Prelude shim: hide ACC_PRODUCT_CONFIG_V3 / _V2 from libc's
 *      environ so Chromium's internal /proc/self/exe spawn for the
 *      network/GPU/utility services doesn't fail with E2BIG.
 *
 *   2. Attach the tray context menu via setContextMenu() on Linux so
 *      the libayatana-appindicator backend renders the right-click
 *      menu (the AppIndicator never emits the click/right-click events
 *      upstream relies on).
 *
 *   3. Construct the Linux Tray from an on-disk PNG path (the
 *      .workbuddy-linux/workbuddy.png file written by install.sh)
 *      instead of a resized in-memory NativeImage — AppIndicator on
 *      Mint/Cinnamon otherwise renders a missing-image placeholder.
 *
 *   4. Disable the "Check for Updates..." menu entry and stub out the
 *      update* RPC handlers. The upstream updater drives the macOS
 *      ShipIt / Windows Squirrel installers, neither of which applies
 *      on a Linux port.
 *
 *   5. (in the env shim) Monkey-patch child_process.spawn/spawnSync
 *      to spill oversized env entries (ACC_PRODUCT_CONFIG_V3 / _V2)
 *      to a private temp file and replace them with a *_FILE pointer.
 *      The sidecar-entry.js shim reads the file back and re-injects
 *      the value via the same Proxy so the sidecar still sees the
 *      full JSON. This eliminates the spawn E2BIG that previously
 *      broke sidecar startup and plugin marketplace updates.
 *
 * The script operates directly on an app.asar file. It extracts it to a
 * temp directory, edits main/index.js + main/sidecar-entry.js, and
 * repacks the asar while preserving the original unpacked=true set.
 *
 * Usage:
 *   node apply-linux-patches.js <path/to/app.asar> <marker>
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const asar = require('@electron/asar');

const [, , asarPath, marker] = process.argv;
if (!asarPath || !marker) {
    console.error('Usage: apply-linux-patches.js <app.asar> <marker>');
    process.exit(2);
}

function log(msg) { console.log('  [apply-linux-patches] ' + msg); }

// ---------------------------------------------------------------------------
// 1. Extract the asar into a temp dir. We pull file contents straight from
//    asar.extractFile() instead of relying on the CLI so that:
//      (a) we don't depend on the CLI sniffing the sibling .unpacked dir,
//      (b) we can reliably recover the exact bytes for every entry.
//    Unpacked entries are copied from the sibling <asar>.unpacked/ dir.
// ---------------------------------------------------------------------------
const { header } = asar.getRawHeader(asarPath);
const unpackedSiblingDir = asarPath + '.unpacked';
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wb-asar-patch-'));
process.on('exit', () => {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) {}
});

// ---------------------------------------------------------------------------
// Walk the header, collect every file's metadata, and write the bytes to
// the temp dir. Also accumulate the "unpacked" set for later.
// ---------------------------------------------------------------------------
const unpackedFiles = [];
function walk(node, prefix) {
    if (!node.files) return;
    for (const [name, entry] of Object.entries(node.files)) {
        const rel = prefix ? prefix + '/' + name : name;
        const abs = path.join(tmpDir, rel);
        if (entry.files) {
            fs.mkdirSync(abs, { recursive: true });
            walk(entry, rel);
        } else if (entry.link) {
            // Symlink entries — extractFile can't give us the target, so
            // we just recreate them directly.
            try {
                fs.mkdirSync(path.dirname(abs), { recursive: true });
                fs.symlinkSync(entry.link, abs);
            } catch (err) {
                console.warn('  [apply-linux-patches] skipped symlink ' + rel + ': ' + err.message);
            }
        } else {
            fs.mkdirSync(path.dirname(abs), { recursive: true });
            if (entry.unpacked) {
                unpackedFiles.push(rel);
                const src = path.join(unpackedSiblingDir, rel);
                if (fs.existsSync(src)) {
                    fs.copyFileSync(src, abs);
                    const stat = fs.statSync(src);
                    fs.chmodSync(abs, stat.mode & 0o777);
                } else {
                    // Unpacked file missing from sibling dir — write an empty
                    // placeholder so the header can still reference it. This
                    // path is only hit if someone has deleted files from
                    // app.asar.unpacked/ between build and patch.
                    fs.writeFileSync(abs, Buffer.alloc(0));
                    console.warn('  [apply-linux-patches] missing unpacked file: ' + rel);
                }
            } else {
                const buf = asar.extractFile(asarPath, rel);
                fs.writeFileSync(abs, buf);
                if (entry.executable) {
                    fs.chmodSync(abs, 0o755);
                }
            }
        }
    }
}
walk(header, '');
log('Extracted ' + unpackedFiles.length + ' unpacked + packed entries to temp dir');

// ---------------------------------------------------------------------------
// 2. Apply the two source patches to main/index.js.
// ---------------------------------------------------------------------------
const indexPath = path.join(tmpDir, 'main', 'index.js');
if (!fs.existsSync(indexPath)) {
    console.error('[apply-linux-patches] ERROR: main/index.js missing in asar');
    process.exit(3);
}

let source = fs.readFileSync(indexPath, 'utf8');

const SHIM_BODY = `// ${marker} — WorkBuddy Linux runtime patches (env + tray)
(function wbLinuxEnvShim() {
  if (process.platform !== "linux") return;
  try {
    // ---------------------------------------------------------------
    // Part A: keep the oversized product-config JSON out of libc
    // environ so Chromium's own execvp("/proc/self/exe") for network,
    // GPU and utility subprocesses doesn't fail with E2BIG.
    //
    // We replace process.env with a Proxy that stores the two hidden
    // keys in a private JS slot, hides them from every enumeration
    // path (has/ownKeys/getOwnPropertyDescriptor), and returns them
    // only via direct property access. Node's child_process spawn
    // enumerates process.env to build the child environment, so the
    // oversized string never lands in the child's argv block either.
    // ---------------------------------------------------------------
    var HIDDEN = new Set(["ACC_PRODUCT_CONFIG_V3", "ACC_PRODUCT_CONFIG_V2"]);
    var real = process.env;
    var store = Object.create(null);
    HIDDEN.forEach(function (key) {
      if (typeof real[key] === "string") {
        store[key] = real[key];
        try { delete real[key]; } catch (_) {}
      }
    });
    var proxy = new Proxy(real, {
      get: function (target, prop) {
        if (typeof prop === "string" && HIDDEN.has(prop)) return store[prop];
        return Reflect.get(target, prop);
      },
      set: function (target, prop, value) {
        if (typeof prop === "string" && HIDDEN.has(prop)) {
          store[prop] = value == null ? undefined : String(value);
          try { delete target[prop]; } catch (_) {}
          return true;
        }
        return Reflect.set(target, prop, value);
      },
      deleteProperty: function (target, prop) {
        if (typeof prop === "string" && HIDDEN.has(prop)) {
          delete store[prop];
          try { delete target[prop]; } catch (_) {}
          return true;
        }
        return Reflect.deleteProperty(target, prop);
      },
      has: function (target, prop) { return Reflect.has(target, prop); },
      ownKeys: function (target) { return Reflect.ownKeys(target); },
      getOwnPropertyDescriptor: function (target, prop) {
        return Reflect.getOwnPropertyDescriptor(target, prop);
      }
    });
    Object.defineProperty(process, "env", {
      value: proxy,
      writable: true,
      configurable: true,
      enumerable: true
    });

    // ---------------------------------------------------------------
    // Part B: sidecar spawn E2BIG workaround.
    //
    // Upstream assigns the same ~260KB JSON into the env object it
    // passes to child_process.spawn (see SidecarManager.spawnSidecar
    // and related CLI helpers). Even though Part A keeps the value
    // off libc environ for the main process, spawn() still stuffs it
    // into the argv block of the new process, where MAX_ARG_STRLEN
    // rejects any single 128KB+ entry with E2BIG.
    //
    // We monkey-patch child_process.spawn / spawnSync so that any
    // env entry named ACC_PRODUCT_CONFIG_V3 / _V2 whose value is
    // larger than 100KB is spilled to a private temp file and
    // replaced in the child's env with ACC_PRODUCT_CONFIG_V3_FILE.
    // The sidecar-entry.js shim reads that file back and re-injects
    // the value via a matching Proxy so downstream code sees the
    // same process.env.ACC_PRODUCT_CONFIG_V3 string.
    // ---------------------------------------------------------------
    var cp = require("child_process");
    var fsMod = require("fs");
    var osMod = require("os");
    var pathMod = require("path");
    var cryptoMod = require("crypto");
    var SPILL_KEYS = ["ACC_PRODUCT_CONFIG_V3", "ACC_PRODUCT_CONFIG_V2"];
    var SPILL_THRESHOLD = 100 * 1024; // 100KB; MAX_ARG_STRLEN is 128KB

    function spillDir() {
      var dir = pathMod.join(osMod.tmpdir(), "workbuddy-linux-env-" + process.pid);
      try { fsMod.mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch (_) {}
      return dir;
    }

    function spillOversizedEnv(originalOpts) {
      if (!originalOpts || typeof originalOpts !== "object") return originalOpts;
      var env = originalOpts.env;
      if (!env || typeof env !== "object") return originalOpts;
      var spilled = null;
      for (var i = 0; i < SPILL_KEYS.length; i++) {
        var key = SPILL_KEYS[i];
        var value = env[key];
        if (typeof value === "string" && value.length >= SPILL_THRESHOLD) {
          try {
            var dir = spillDir();
            var filePath = pathMod.join(
              dir,
              key + "-" + cryptoMod.randomBytes(8).toString("hex") + ".json"
            );
            fsMod.writeFileSync(filePath, value, { mode: 0o600 });
            if (!spilled) spilled = Object.assign({}, env);
            delete spilled[key];
            spilled[key + "_FILE"] = filePath;
          } catch (err) {
            try {
              console.error("[wb-linux-shim] failed to spill " + key + ":", err);
            } catch (_) {}
          }
        }
      }
      if (!spilled) return originalOpts;
      return Object.assign({}, originalOpts, { env: spilled });
    }

    function wrapSpawnLike(name) {
      var orig = cp[name];
      if (typeof orig !== "function" || orig.__wbLinuxShimWrapped) return;
      function wrapped(command, args, options) {
        // Normalize arg shape: spawn(cmd[, args][, options])
        if (!Array.isArray(args) && typeof args === "object" && args !== null) {
          options = args;
          args = undefined;
        }
        var patched = spillOversizedEnv(options);
        if (args === undefined) return orig.call(cp, command, patched);
        return orig.call(cp, command, args, patched);
      }
      wrapped.__wbLinuxShimWrapped = true;
      try { cp[name] = wrapped; } catch (_) {}
    }
    wrapSpawnLike("spawn");
    wrapSpawnLike("spawnSync");

    // ---------------------------------------------------------------
    // Part C: receiver side.
    //
    // If our parent handed us a _FILE pointer (i.e. we are a child
    // process spawned after Part B kicked in), read the file back
    // and re-expose the original value on process.env through the
    // same Proxy. The file is deleted after a single read so we
    // don't leave the JSON lying around any longer than necessary.
    // ---------------------------------------------------------------
    for (var j = 0; j < SPILL_KEYS.length; j++) {
      var rkey = SPILL_KEYS[j];
      var fkey = rkey + "_FILE";
      var fp = real[fkey];
      if (typeof fp === "string" && fp.length) {
        try {
          store[rkey] = fsMod.readFileSync(fp, "utf8");
          try { fsMod.unlinkSync(fp); } catch (_) {}
        } catch (err) {
          try {
            console.error("[wb-linux-shim] failed to read " + fkey + ":", err);
          } catch (_) {}
        }
        try { delete real[fkey]; } catch (_) {}
      }
    }

    // ---------------------------------------------------------------
    // Part D: ensure app.asar.unpacked/node_modules is on the
    // module resolution path. The asar-packed require() only sees
    // modules listed in the asar header. Platform-specific optional
    // packages like @lydell/node-pty-linux-x64 are installed into
    // app.asar.unpacked/ by the build script but never registered
    // in the asar header. Adding the unpacked node_modules to
    // Module.globalPaths lets require() find them.
    // ---------------------------------------------------------------
    try {
      var Module = require("module");
      var resourcesPath = typeof process.resourcesPath === "string"
        ? process.resourcesPath
        : pathMod.dirname(process.execPath);
      var unpackedNM = pathMod.join(resourcesPath, "app.asar.unpacked", "node_modules");
      if (fsMod.existsSync(unpackedNM)) {
        if (Module.globalPaths && !Module.globalPaths.includes(unpackedNM)) {
          Module.globalPaths.push(unpackedNM);
        }
      }
    } catch (_) {}
  } catch (err) {
    try { console.error("[wb-linux-shim] install failed:", err); } catch (_) {}
  }
})();
`;

if (source.includes(marker)) {
    log('marker already present in main/index.js; skipping source patch');
} else {
    const shim = SHIM_BODY;
    source = shim + source;

    const trayMarker = 'this.tray = new electron.Tray(trayIcon);';
    const trayIdx = source.indexOf(trayMarker);
    if (trayIdx < 0) {
        console.error('[apply-linux-patches] ERROR: tray construction line not found');
        process.exit(4);
    }
    const afterTray = source.slice(trayIdx);
    const contextMenuDeclRe = /const contextMenu = electron\.Menu\.buildFromTemplate\(\[[\s\S]*?\]\);/;
    const m = afterTray.match(contextMenuDeclRe);
    if (!m) {
        console.error('[apply-linux-patches] ERROR: contextMenu declaration not found after tray');
        process.exit(5);
    }
    const insertAt = trayIdx + m.index + m[0].length;
    const trayPatch =
        '\n\t\t\tif (process.platform === "linux") {\n' +
        '\t\t\t\ttry { this.tray.setContextMenu(contextMenu); } catch (_) {}\n' +
        '\t\t\t}';
    source = source.slice(0, insertAt) + trayPatch + source.slice(insertAt);

    // Fix 3 (Linux): the tray icon renders as a missing-image placeholder
    // (exclamation mark on Mint/Cinnamon) because upstream hands
    // libayatana-appindicator a resized in-memory NativeImage. The
    // AppIndicator backend wants an on-disk file path it can re-read
    // through GTK. On Linux we construct the Tray from the PNG written
    // by install.sh at <install-dir>/.workbuddy-linux/workbuddy.png
    // (shipped into /opt/<app>/.workbuddy-linux/ by the .deb/.rpm/.pacman
    // builders), falling back to the upstream NativeImage path if that
    // file is missing for any reason.
    const trayConstruct = 'this.tray = new electron.Tray(trayIcon);';
    const trayConstructReplacement =
        'if (process.platform === "linux") {\n' +
        '\t\t\t\ttry {\n' +
        '\t\t\t\t\tconst linuxTrayPath = path.join(path.dirname(process.resourcesPath), ".workbuddy-linux", "workbuddy.png");\n' +
        '\t\t\t\t\tif (fs.existsSync(linuxTrayPath)) {\n' +
        '\t\t\t\t\t\tthis.tray = new electron.Tray(linuxTrayPath);\n' +
        '\t\t\t\t\t}\n' +
        '\t\t\t\t} catch (_) {}\n' +
        '\t\t\t}\n' +
        '\t\t\tif (!this.tray) this.tray = new electron.Tray(trayIcon);';
    // There are two identical Tray constructions in the file in some
    // builds; replace only the first occurrence (the WindowManager one).
    const trayIdx2 = source.indexOf(trayConstruct);
    if (trayIdx2 >= 0) {
        source = source.slice(0, trayIdx2)
            + trayConstructReplacement
            + source.slice(trayIdx2 + trayConstruct.length);
    }

    // -----------------------------------------------------------------------
    // Fix 4 (Linux): disable the "Check for Updates..." menu item and
    // stub out the updateCheck / updateDownload / updateQuitAndInstall
    // RPCs. The upstream updater talks to the macOS ShipIt / Windows
    // Squirrel / NSIS installers which are not available on Linux, and
    // the downloaded payloads (.dmg / .exe) cannot be applied here. We
    // surface a greyed-out menu entry so users see that auto-update is
    // intentionally unavailable on the Linux port.
    // -----------------------------------------------------------------------
    const updateMenuMarker = 'function getUpdateMenuItem(texts, updateState) {';
    const updateMenuIdx = source.indexOf(updateMenuMarker);
    if (updateMenuIdx >= 0) {
        const linuxUpdateShim =
            updateMenuMarker + '\n' +
            '\tif (process.platform === "linux") {\n' +
            '\t\treturn {\n' +
            '\t\t\tid: "checkForUpdates",\n' +
            '\t\t\tlabel: (texts.checkForUpdates || "Check for Updates...") + " (Linux 不支持)",\n' +
            '\t\t\tdisabled: true,\n' +
            '\t\t\tcommandId: "menu.checkForUpdates.disabled"\n' +
            '\t\t};\n' +
            '\t}';
        source = source.slice(0, updateMenuIdx)
            + linuxUpdateShim
            + source.slice(updateMenuIdx + updateMenuMarker.length);
    }

    // Neutralize updateCheck / updateDownload / updateQuitAndInstall RPCs
    // on Linux so any residual UI button in the renderer becomes a no-op
    // instead of invoking the macOS/Windows updater code paths.
    const updateRpcMarker = 'function registerUpdateHandlers(server, deps) {';
    const updateRpcIdx = source.indexOf(updateRpcMarker);
    if (updateRpcIdx >= 0) {
        const linuxRpcShim =
            updateRpcMarker + '\n' +
            '\tif (process.platform === "linux") {\n' +
            '\t\thandleRpc$1(server, "updateCheck", async () => {});\n' +
            '\t\thandleRpc$1(server, "updateDownload", async () => {});\n' +
            '\t\thandleRpc$1(server, "updateArchMismatchDownload", async () => {});\n' +
            '\t\thandleRpc$1(server, "updateArchMismatchInstall", async () => {});\n' +
            '\t\thandleRpc$1(server, "updateQuitAndInstall", async () => {});\n' +
            '\t\thandleRpc$1(server, "updateGetState", async () => ({ state: "idle" }));\n' +
            '\t\treturn;\n' +
            '\t}';
        source = source.slice(0, updateRpcIdx)
            + linuxRpcShim
            + source.slice(updateRpcIdx + updateRpcMarker.length);
    }

    // Also stub out UpdateServiceLinux.checkForUpdates so the automatic
    // background update check (triggered by UpdateService.start()) does
    // not fire HTTP requests to a macOS/Windows feed URL.
    const linuxUpdateClassMarker = 'UpdateServiceLinux = class extends AbstractUpdateService {';
    const linuxUpdateClassIdx = source.indexOf(linuxUpdateClassMarker);
    if (linuxUpdateClassIdx >= 0) {
        const checkMethodMarker = 'async checkForUpdates(explicit = false) {';
        const checkMethodIdx = source.indexOf(checkMethodMarker, linuxUpdateClassIdx);
        if (checkMethodIdx >= 0) {
            const afterCheck = checkMethodIdx + checkMethodMarker.length;
            const earlyReturn = '\n\t\t\t\t\t// [wb-linux-patch] Auto-update disabled on Linux port\n\t\t\t\t\treturn;\n';
            source = source.slice(0, afterCheck) + earlyReturn + source.slice(afterCheck);
        }
    }

    fs.writeFileSync(indexPath, source);
    log('patched main/index.js (env shim + tray context menu + tray icon path + disabled updater)');
}

// ---------------------------------------------------------------------------
// Also patch sidecar-entry.js so the sidecar process, spawned with
// ELECTRON_RUN_AS_NODE=1 and its own Node bootstrap, receives the same
// env Proxy / _FILE receiver installed in main/index.js. Without this
// the sidecar would boot without ACC_PRODUCT_CONFIG_V3 set (because
// the parent spilled it to a file) and every downstream call through
// getWorkbuddyBootstrapProductConfigurationEnv() would fall back to
// a stale bootstrap value.
// ---------------------------------------------------------------------------
const sidecarEntryPath = path.join(tmpDir, 'main', 'sidecar-entry.js');
if (fs.existsSync(sidecarEntryPath)) {
    let sidecarSource = fs.readFileSync(sidecarEntryPath, 'utf8');
    if (!sidecarSource.includes(marker)) {
        sidecarSource = SHIM_BODY + sidecarSource;
        fs.writeFileSync(sidecarEntryPath, sidecarSource);
        log('patched main/sidecar-entry.js (env shim)');
    } else {
        log('marker already present in main/sidecar-entry.js; skipping');
    }
}

// ---------------------------------------------------------------------------
// Ensure @lydell/node-pty-linux-x64 is present in the asar's node_modules
// so that require("@lydell/node-pty-linux-x64") resolves from within the
// asar. The package lives on disk in app.asar.unpacked/node_modules/ but
// was never registered in the original macOS asar header. We copy it into
// the tmpDir so the repack step includes it as an unpacked entry.
// ---------------------------------------------------------------------------
const lydellLinuxSrc = path.join(unpackedSiblingDir, 'node_modules', '@lydell', 'node-pty-linux-x64');
const lydellLinuxDst = path.join(tmpDir, 'node_modules', '@lydell', 'node-pty-linux-x64');
if (fs.existsSync(lydellLinuxSrc) && !fs.existsSync(lydellLinuxDst)) {
    fs.cpSync(lydellLinuxSrc, lydellLinuxDst, { recursive: true });
    log('copied @lydell/node-pty-linux-x64 into asar source for repack');
}

// ---------------------------------------------------------------------------
// 3. Repack.
//
// @electron/asar's glob-based --unpack matcher has O(2^n) behaviour on a
// brace list the size of ours (~850 entries). Instead we build a Set of
// the original unpacked paths, use a catch-all minimatch pattern that
// accepts everything, and pass a `dot: true` pattern per directory. But
// the cleanest route with the public API is: pass a minimatch function
// that is fast. Turns out the simplest workable approach is to use the
// pattern scheme once per "class" of entry. On inspection, the original
// header's unpacked set is exactly:
//     cli/**   +   resources/**   +   a specific subset of node_modules/**
//
// For node_modules, the unpacked subset is always a whole package tree
// (better-sqlite3, @lydell/*, node-pty, nunjucks, @tencent/docs-engine).
//
// We compute that per-top-level-dir unpacked set dynamically from the
// original header and emit an asar `--unpack=…` pattern that names each
// top-level directory that must be fully unpacked. That's small enough
// for minimatch to handle in microseconds.
// ---------------------------------------------------------------------------
function collectFullyUnpackedDirs() {
    // Find every directory where 100% of its immediate children are unpacked
    // (recursively). Start from each top-level dir.
    const dirs = [];
    function visit(node, relPath) {
        if (!node.files) return { total: 0, unpacked: 0 };
        let total = 0, unpacked = 0;
        for (const [name, entry] of Object.entries(node.files)) {
            const child = relPath ? relPath + '/' + name : name;
            if (entry.files) {
                const sub = visit(entry, child);
                total += sub.total;
                unpacked += sub.unpacked;
            } else if (entry.link) {
                // links aren't packed or unpacked; ignore for the ratio
            } else {
                total++;
                if (entry.unpacked) unpacked++;
            }
        }
        if (total > 0 && total === unpacked && relPath) {
            dirs.push(relPath);
        }
        return { total, unpacked };
    }
    visit(header, '');
    // Only keep maximal directories (drop any dir whose parent is also in
    // the set), so the asar glob pattern stays minimal.
    const set = new Set(dirs);
    return dirs.filter(d => {
        const parts = d.split('/');
        for (let i = 1; i < parts.length; i++) {
            const parent = parts.slice(0, i).join('/');
            if (set.has(parent)) return false;
        }
        return true;
    });
}

const fullyUnpackedDirs = collectFullyUnpackedDirs();
// Also include any Linux platform packages we injected into the tmpDir
// that weren't in the original macOS header.
const extraUnpackDirs = ['node_modules/@lydell/node-pty-linux-x64'];
for (const d of extraUnpackDirs) {
    if (fs.existsSync(path.join(tmpDir, d)) && !fullyUnpackedDirs.includes(d)) {
        fullyUnpackedDirs.push(d);
    }
}
log('Fully-unpacked top directories: ' + fullyUnpackedDirs.length);

// Compose the asar `unpackDir` glob. It is matched against directory
// entries, so "cli" matches the cli/ tree recursively. Brace-list of
// ~10 paths is fast.
const unpackDirPattern = '{' + fullyUnpackedDirs.map(d =>
    d.replace(/[{}(),*?[\]!|+@\\]/g, ch => '\\' + ch)
).join(',') + '}';

// Also compute any individual unpacked files that live in partially-packed
// directories (e.g. a single file under node_modules/foo/ where only that
// one file is unpacked). Collect them and use an explicit --unpack glob.
const partialUnpackedFiles = [];
function findPartialFiles(node, relPath) {
    if (!node.files) return;
    if (fullyUnpackedDirs.includes(relPath)) return; // covered by unpackDir
    for (const [name, entry] of Object.entries(node.files)) {
        const child = relPath ? relPath + '/' + name : name;
        if (entry.files) {
            if (!fullyUnpackedDirs.includes(child)) {
                findPartialFiles(entry, child);
            }
        } else if (entry.unpacked && !entry.link) {
            // Is the child's directory already in the fully-unpacked set?
            const parent = child.split('/').slice(0, -1).join('/');
            if (!fullyUnpackedDirs.some(d => parent === d || parent.startsWith(d + '/'))) {
                partialUnpackedFiles.push(child);
            }
        }
    }
}
findPartialFiles(header, '');
log('Partially-unpacked individual files: ' + partialUnpackedFiles.length);

const unpackPattern = partialUnpackedFiles.length
    ? '{' + partialUnpackedFiles.map(p =>
        p.replace(/[{}(),*?[\]!|+@\\]/g, ch => '\\' + ch)
    ).join(',') + '}'
    : undefined;

// ---------------------------------------------------------------------------
// Pack.
//
// We only edit main/index.js, which lives inside the asar (packed). The
// sibling <asar>.unpacked/ sidecar directory therefore does not need to
// change — and we explicitly avoid touching it so that any files the
// install.sh step already placed there (e.g. rebuilt native modules,
// Linux ripgrep binary, the original resources/icon.png) stay as-is.
//
// The repack produces its own sidecar directory matching the header's
// unpack set. We throw that output away.
// ---------------------------------------------------------------------------
(async () => {
    const outPath = asarPath + '.new';
    const stagingSidecar = outPath + '.unpacked';
    try { fs.rmSync(outPath, { force: true }); } catch (_) {}
    try { fs.rmSync(stagingSidecar, { recursive: true, force: true }); } catch (_) {}

    await asar.createPackageWithOptions(tmpDir, outPath, {
        unpackDir: unpackDirPattern,
        unpack: unpackPattern,
    });
    log('wrote ' + path.basename(outPath) + ' (' + fs.statSync(outPath).size + ' bytes)');

    // Atomically replace app.asar only. Leave app.asar.unpacked alone.
    fs.renameSync(asarPath, asarPath + '.prepatch');
    try {
        fs.renameSync(outPath, asarPath);
    } catch (err) {
        // Roll back on failure.
        try { fs.renameSync(asarPath + '.prepatch', asarPath); } catch (_) {}
        throw err;
    }
    try { fs.rmSync(asarPath + '.prepatch'); } catch (_) {}

    // Discard the repack's sidecar directory; the on-disk one is already
    // correct and contains additional files (rebuilt native modules,
    // Linux binaries) that the staging dir does not have.
    try { fs.rmSync(stagingSidecar, { recursive: true, force: true }); } catch (_) {}

    log('replaced app.asar in place (app.asar.unpacked left untouched)');
})().catch(err => {
    console.error('[apply-linux-patches] pack failed:', err);
    process.exit(6);
});
