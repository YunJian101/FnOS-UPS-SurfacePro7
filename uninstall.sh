#!/bin/sh
# uninstall.sh - 移除 Surface 电池驱动
set -eu

KVER=$(uname -r)
IMAGE=${IMAGE:-debian:bookworm-slim}
DEST=/lib/modules/$KVER/extra/surface-battery

die() { echo "错误：$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo sh uninstall.sh"

rm -rf "$DEST"
rm -f /etc/modules-load.d/surface-battery.conf
echo "已删除 $DEST 与 /etc/modules-load.d/surface-battery.conf"

if command -v depmod >/dev/null 2>&1; then
	depmod -a "$KVER"
	echo "已更新模块依赖"
elif command -v docker >/dev/null 2>&1; then
	docker run --rm -v /lib/modules:/lib/modules:rw "$IMAGE" sh -c \
		'apt-get update -qq && apt-get install -y -qq --no-install-recommends kmod >/dev/null && depmod -a '"$KVER" \
		&& echo "已更新模块依赖" || echo "警告：depmod 未成功，重启后模块表会自行重建"
else
	echo "警告：系统没有 depmod 也没有 docker，跳过依赖更新（重启后自动重建）"
fi

echo
echo "已经加载进内核的模块要重启后才会消失。"
echo "确认模块仍然存在：lsmod | grep surface"
