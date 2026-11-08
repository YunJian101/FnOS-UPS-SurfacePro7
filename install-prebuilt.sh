#!/bin/sh
# install-prebuilt.sh - 用预编译模块安装，不需要编译器和内核源码
#
# 用法：
#   sudo sh install-prebuilt.sh            # 在同目录下找 <uname -r> 子目录，或直接用同目录的 .ko
#   sudo sh install-prebuilt.sh <目录>     # 指定模块所在目录
set -eu

KVER=$(uname -r)
BASE=$(cd "$(dirname "$0")" && pwd)
SRC=""

die() { echo "错误：$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo sh install-prebuilt.sh"

if [ "${1:-}" != "" ]; then
	SRC=$1
elif [ -d "$BASE/$KVER" ]; then
	SRC=$BASE/$KVER
elif ls "$BASE"/*.ko >/dev/null 2>&1; then
	SRC=$BASE
fi

if [ -z "$SRC" ] || [ ! -d "$SRC" ] || ! ls "$SRC"/*.ko >/dev/null 2>&1; then
	echo "没有找到适用于当前内核 $KVER 的预编译模块。"
	if [ -d "$BASE" ]; then
		echo "当前目录可用的版本："
		find "$BASE" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sed 's/^/  - /'
	fi
	echo
	echo "要么改用源码编译（会针对当前内核现编）："
	echo "  sudo sh install.sh"
	exit 1
fi

echo "内核版本     : $KVER"
echo "预编译模块目录: $SRC"

if [ -f "$SRC/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
	echo "校验完整性..."
	( cd "$SRC" && sha256sum -c SHA256SUMS ) || die "校验失败，文件可能不完整"
fi

DEST=/lib/modules/$KVER/extra/surface-battery
mkdir -p "$DEST"
cp -f "$SRC"/*.ko "$DEST"/
echo "已安装模块到 $DEST"

if command -v depmod >/dev/null 2>&1; then
	depmod -a "$KVER"
	echo "已更新模块依赖"
elif command -v docker >/dev/null 2>&1; then
	echo "系统没有 depmod，用容器补一次"
	docker run --rm -v /lib/modules:/lib/modules:rw debian:bookworm-slim sh -c \
		'apt-get update -qq && apt-get install -y -qq --no-install-recommends kmod >/dev/null && depmod -a '"$KVER"
else
	echo "警告：既没有 depmod 也没有 docker，跳过依赖更新（重启后会自行重建）"
fi

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/surface-battery.conf <<'EOF'
# Surface 电池驱动（FnOS-UPS-SurfacePro7 安装）
crc_itu_t
surface_aggregator
surface_aggregator_registry
surface_charger
surface_battery
EOF
echo "已写入 /etc/modules-load.d/surface-battery.conf"

if command -v modprobe >/dev/null 2>&1; then
	modprobe surface_battery 2>/dev/null || true
	echo "已尝试加载 surface_battery"
else
	echo "系统没有 modprobe，重启后由 modules-load 自动加载"
fi

echo
echo "==== 验证 ===="
ls -1 /sys/class/power_supply 2>/dev/null || echo "（还看不到，重启后再看）"
echo "期望出现 BAT0 和 ADP1"
