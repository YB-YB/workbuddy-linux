#!/bin/bash
# Linux Electron runtime download. Sourced by install.sh.

electron_arch() {
    case "$ARCH" in
        x86_64) echo "x64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7l" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac
}

download_electron_runtime() {
    local arch zip_name url cache_dir cached_zip partial_zip lock_dir checksum

    arch="$(electron_arch)"
    zip_name="electron-v${ELECTRON_VERSION}-linux-${arch}.zip"
    if [ -n "$ELECTRON_MIRROR" ]; then
        url="${ELECTRON_MIRROR%/}/v${ELECTRON_VERSION}/${zip_name}"
    else
        url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/${zip_name}"
    fi

    cache_dir="${WORKBUDDY_ELECTRON_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/workbuddy-linux/electron}"
    cached_zip="$cache_dir/$zip_name"
    partial_zip="$cached_zip.$$.$RANDOM.part"
    lock_dir="$cache_dir/$zip_name.lock"
    checksum="${ELECTRON_ZIP_SHA256:-}"
    mkdir -p "$cache_dir"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        info "Waiting for Electron cache lock: $zip_name"
        sleep 1
    done
    trap "rm -rf '$lock_dir'" RETURN

    if [ ! -f "$cached_zip" ]; then
        info "Downloading $zip_name"
        curl -L --fail --progress-bar -o "$partial_zip" "$url"
        if [ -n "$checksum" ]; then
            printf '%s  %s\n' "$checksum" "$partial_zip" | sha256sum -c - >/dev/null || error "Electron runtime checksum mismatch: $zip_name"
        fi
        mv "$partial_zip" "$cached_zip"
    else
        info "Using cached Electron runtime: $cached_zip"
        # 缓存命中时也校验 checksum（如有提供），避免损坏的缓存被静默使用
        if [ -n "$checksum" ]; then
            printf '%s  %s\n' "$checksum" "$cached_zip" | sha256sum -c - >/dev/null || {
                warn "Cached Electron checksum mismatch, re-downloading"
                rm -f "$cached_zip"
                info "Downloading $zip_name"
                curl -L --fail --progress-bar -o "$partial_zip" "$url"
                printf '%s  %s\n' "$checksum" "$partial_zip" | sha256sum -c - >/dev/null || error "Electron runtime checksum mismatch: $zip_name"
                mv "$partial_zip" "$cached_zip"
            }
        fi
    fi

    unzip -qo "$cached_zip" -d "$INSTALL_DIR"
    [ -x "$INSTALL_DIR/electron" ] || error "Electron binary was not extracted"

    # 验证提取的 Electron 二进制版本与预期一致
    local extracted_version
    extracted_version="$("$INSTALL_DIR/electron" --version 2>/dev/null || true)"
    if [ -n "$extracted_version" ]; then
        extracted_version="${extracted_version#v}"
        if [ "$extracted_version" != "$ELECTRON_VERSION" ]; then
            warn "Extracted Electron version mismatch: expected v${ELECTRON_VERSION}, got v${extracted_version}"
        else
            info "Verified Electron runtime: v${extracted_version}"
        fi
    fi

    rm -rf "$lock_dir"
    trap - RETURN
}
