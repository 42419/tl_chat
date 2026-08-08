#!/usr/bin/env bash
# 将 Flutter Linux release bundle 打包为 deb。
#
# 用法:
#   build_deb.sh <bundle目录> <输出.deb路径> <版本号> <架构(amd64|arm64)>
#
# 产物结构:
#   /opt/tl-chat/           应用 bundle（二进制 + lib + data）
#   /usr/bin/tl-chat        启动符号链接
#   /usr/share/applications/tl-chat.desktop
#   /usr/share/icons/hicolor/scalable/apps/tl-chat.svg
set -euo pipefail

BUNDLE="${1:?bundle dir required}"
OUT="${2:?output .deb path required}"
VERSION="${3:?version required}"
ARCH="${4:?arch required}"

[ -d "$BUNDLE" ] || { echo "error: bundle 目录不存在: $BUNDLE"; exit 1; }

# bundle 根目录下的可执行文件（如 tl_chat）
BIN="$(find "$BUNDLE" -maxdepth 1 -type f -perm -u+x ! -name '*.so' | head -1)"
[ -n "$BIN" ] || { echo "error: 在 bundle 中找不到可执行文件"; exit 1; }
BIN_NAME="$(basename "$BIN")"
echo "binary: $BIN_NAME"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" \
  "$STAGE/opt/tl-chat" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE"/. "$STAGE/opt/tl-chat/"
ln -s "/opt/tl-chat/$BIN_NAME" "$STAGE/usr/bin/tl-chat"

# 桌面入口
cat > "$STAGE/usr/share/applications/tl-chat.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=TL Chat
Comment=基于 Tailscale 内网穿透的轻量聊天客户端
Exec=/opt/tl-chat/$BIN_NAME
Icon=tl-chat
Terminal=false
Categories=Network;InstantMessaging;
StartupWMClass=tl-chat
EOF

# 图标
cp "$(dirname "$0")/tl_chat.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/tl-chat.svg"

# 包元信息
cat > "$STAGE/DEBIAN/control" <<EOF
Package: tl-chat
Version: $VERSION
Architecture: $ARCH
Maintainer: TL Chat Developers <dev@tl-chat.local>
Section: net
Priority: optional
Depends: libgtk-3-0, liblzma5
Description: TL Chat - Tailscale 内网穿透聊天客户端
 基于 Tailscale 的轻量聊天客户端，通过内网加密隧道连接
 中心服务，支持文本消息、已读回执、打字指示与历史同步。
EOF

mkdir -p "$(dirname "$OUT")"
dpkg-deb --build --root-owner-group "$STAGE" "$OUT"
echo "done: $OUT"
