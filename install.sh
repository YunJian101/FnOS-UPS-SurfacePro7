#!/bin/sh
# install.sh - 在目标机器上安装 Surface 电池驱动
# 需要 root 权限，需要 docker。
set -eu

KVER=$(uname -r)
IMAGE=${IMAGE:-debian:bookworm-slim}
BAT_NAME=${BAT_NAME:-BAT0}
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

die() { echo "错误：$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo sh install.sh"
command -v docker >/dev/null 2>&1 || die "未找到 docker，装好再来"

HDR=/usr/src/linux-headers-$KVER
[ -d "$HDR" ] || die "缺少 $HDR（需要安装与当前内核匹配的头文件包）"
[ -f "$HDR/Module.symvers" ] || die "$HDR/Module.symvers 缺失，头文件不完整"
[ -f "/boot/config-$KVER" ] || die "缺少 /boot/config-$KVER"

UP=$(printf '%s' "$KVER" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
[ -n "$UP" ] || die "无法从内核版本 $KVER 解析上游版本号"

echo "内核版本 : $KVER"
echo "上游源码 : $UP"
echo "电池设备名: $BAT_NAME"
echo

docker run --rm \
	-e KVER="$KVER" \
	-e UP="$UP" \
	-e BAT_NAME="$BAT_NAME" \
	-v /usr/src:/usr/src:ro \
	-v /boot:/boot:ro \
	-v /lib/modules:/lib/modules:rw \
	-v "$SRC_DIR/scripts:/scripts:ro" \
	"$IMAGE" sh /scripts/build-and-install.sh

DEST=/lib/modules/$KVER/extra/surface-battery
[ -f "$DEST/surface_battery.ko" ] || die "安装失败：$DEST 里没有 surface_battery.ko"

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/surface-battery.conf <<'EOF'
# Surface 电池驱动（fnos-surface-battery 安装）
crc_itu_t
surface_aggregator
surface_aggregator_registry
surface_charger
surface_battery
EOF
echo "已写入 /etc/modules-load.d/surface-battery.conf"

if command -v modprobe >/dev/null 2>&1; then
	modprobe surface_battery 2>/dev/null || true
	echo "已尝试 modprobe surface_battery"
else
	echo "系统里没有 modprobe，重启后由 modules-load 自动加载"
fi

echo
echo "==== 验证 ===="
echo "ls /sys/class/power_supply   # 期望看到 BAT0 和 ADP1"
echo "cat /sys/class/power_supply/BAT0/capacity"
echo "cat /sys/class/power_supply/ADP1/online"
