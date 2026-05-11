#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_DIR/scripts/lib/common.sh"

APP_DIR="${APP_DIR:-$REPO_DIR/workbuddy-app}"
DIST_DIR="${DIST_DIR:-$REPO_DIR/dist}"
PKG_WORK="${PKG_WORK:-$DIST_DIR/pacman-work}"
PACKAGE_NAME="${PACKAGE_NAME:-workbuddy}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(date -u +%Y.%m.%d.%H%M%S)}"
PACMAN_VERSION="${PACKAGE_VERSION//+/_}"
PACMAN_VERSION="${PACMAN_VERSION//-/_}"
DESKTOP_TEMPLATE="$REPO_DIR/packaging/linux/workbuddy.desktop"

map_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        *) error "Unsupported pacman architecture: $(uname -m)" ;;
    esac
}

main() {
    [ -x "$APP_DIR/start.sh" ] || error "Missing generated app. Run make build-app first."
    require_cmd makepkg

    local arch output_file source_root
    arch="$(map_arch)"
    output_file="$DIST_DIR/${PACKAGE_NAME}-${PACMAN_VERSION}-1-${arch}.pkg.tar.zst"
    source_root="$PKG_WORK/src/app"

    rm -rf "$PKG_WORK"
    mkdir -p "$source_root"
    cp -a "$APP_DIR/." "$source_root/"

    sed -e "s|__EXEC__|/opt/$PACKAGE_NAME/start.sh %F|g" "$DESKTOP_TEMPLATE" \
        > "$PKG_WORK/$PACKAGE_NAME.desktop"

    cat > "$PKG_WORK/PKGBUILD" <<EOF
pkgname=$PACKAGE_NAME
pkgver=$PACMAN_VERSION
pkgrel=1
pkgdesc='Unofficial local Linux conversion of WorkBuddy'
arch=('$arch')
license=('MIT')
depends=('gtk3' 'nss' 'libxss' 'alsa-lib' 'libsecret' 'libxkbfile')
source=()
sha256sums=()

package() {
  mkdir -p "\$pkgdir/opt/$PACKAGE_NAME" "\$pkgdir/usr/bin" "\$pkgdir/usr/share/applications" "\$pkgdir/usr/share/icons/hicolor/256x256/apps"
  cp -a "$source_root/." "\$pkgdir/opt/$PACKAGE_NAME/"
  cat > "\$pkgdir/usr/bin/$PACKAGE_NAME" <<'SCRIPT'
#!/bin/bash
exec /opt/$PACKAGE_NAME/start.sh "\$@"
SCRIPT
  chmod 0755 "\$pkgdir/usr/bin/$PACKAGE_NAME"
  install -m 0644 "$PKG_WORK/$PACKAGE_NAME.desktop" "\$pkgdir/usr/share/applications/$PACKAGE_NAME.desktop"
  if [ -f "$source_root/.workbuddy-linux/workbuddy.png" ]; then
    install -m 0644 "$source_root/.workbuddy-linux/workbuddy.png" "\$pkgdir/usr/share/icons/hicolor/256x256/apps/workbuddy.png"
  fi
  # Set SUID bit on chrome-sandbox so Chromium can spawn child processes
  if [ -f "\$pkgdir/opt/$PACKAGE_NAME/chrome-sandbox" ]; then
    chmod 4755 "\$pkgdir/opt/$PACKAGE_NAME/chrome-sandbox"
  fi
}
EOF

    (
        cd "$PKG_WORK"
        makepkg -f --noconfirm
    )

    mkdir -p "$DIST_DIR"
    cp "$PKG_WORK"/*.pkg.tar.zst "$output_file"
    info "Built package: $output_file"
}

main "$@"
