#!/bin/sh
# build-and-install.sh - 在容器内编译并安装 Surface 电池驱动
# 由 install.sh 调用，环境变量：KVER / UP / BAT_NAME
set -eu

: "${KVER:?缺少 KVER}"
: "${UP:?缺少 UP}"
BAT_NAME=${BAT_NAME:-BAT0}

export DEBIAN_FRONTEND=noninteractive

say() { echo; echo "[$1] $2"; }

say 1/6 "安装编译工具链"
if ! apt-get update -qq 2>/dev/null; then
	echo "  默认软件源不可用，改用 HTTP 源重试"
	printf 'deb [trusted=yes] http://deb.debian.org/debian bookworm main\n' > /etc/apt/sources.list
	rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
	apt-get update -qq
fi
apt-get install -y -qq --no-install-recommends \
	curl ca-certificates xz-utils gcc make bc flex bison libelf-dev kmod

say 2/6 "准备内核头文件"
HDR=/usr/src/linux-headers-$KVER
[ -d "$HDR" ] || { echo "错误：$HDR 不存在" >&2; exit 1; }
[ -f "/boot/config-$KVER" ] || { echo "错误：/boot/config-$KVER 不存在" >&2; exit 1; }

WORK=/work
rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$HDR" "$WORK/kdir"
cp "/boot/config-$KVER" "$WORK/kdir/.config"
# 头文件里已带 include/config/auto.conf，把 .config 时间戳压旧，避免触发 kconfig 重建
touch -d '2000-01-01 00:00:00' "$WORK/kdir/.config" 2>/dev/null || \
	touch -t 200001010000 "$WORK/kdir/.config"

say 3/6 "下载内核源码 linux-$UP"
TARBALL="$WORK/linux-$UP.tar.xz"
for base in \
	"https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x" \
	"https://cdn.kernel.org/pub/linux/kernel/v6.x"
do
	[ -s "$TARBALL" ] && break
	echo "  尝试 $base"
	curl -fL --retry 2 --connect-timeout 15 -o "$TARBALL" "$base/linux-$UP.tar.xz" || rm -f "$TARBALL"
done
[ -s "$TARBALL" ] || { echo "错误：内核源码下载失败，请手动放置 $TARBALL" >&2; exit 1; }

say 4/6 "解出需要的源码"
mkdir -p "$WORK/src" "$WORK/x"
SRC=linux-$UP
tar -xf "$TARBALL" -C "$WORK/x" \
	"$SRC/drivers/platform/surface" \
	"$SRC/drivers/power/supply/surface_battery.c" \
	"$SRC/drivers/power/supply/surface_charger.c" \
	|| { echo "错误：解压失败（内核源码结构可能已变化）" >&2; exit 1; }

# crc-itu-t 在 6.9 之后挪到了 lib/crc/ 下，两种路径都试
CRC=
for c in "$WORK/x/$SRC/lib/crc/crc-itu-t.c" "$WORK/x/$SRC/lib/crc-itu-t.c"; do
	[ -f "$c" ] && CRC=$c && break
done
if [ -z "$CRC" ]; then
	tar -xf "$TARBALL" -C "$WORK/x" "$SRC/lib/crc/crc-itu-t.c" 2>/dev/null || true
	[ -f "$WORK/x/$SRC/lib/crc/crc-itu-t.c" ] && CRC="$WORK/x/$SRC/lib/crc/crc-itu-t.c"
fi

P="$WORK/x/$SRC"
cp "$P"/drivers/platform/surface/aggregator/*.c "$WORK/src/"
cp "$P"/drivers/platform/surface/aggregator/*.h "$WORK/src/"
cp "$P"/drivers/platform/surface/surface_aggregator_registry.c "$WORK/src/"
cp "$P"/drivers/power/supply/surface_battery.c "$WORK/src/"
cp "$P"/drivers/power/supply/surface_charger.c "$WORK/src/"

if [ -n "$CRC" ]; then
	cp "$CRC" "$WORK/src/"
else
	echo "  源码里没有 crc-itu-t.c，改为从内核头文件已有实现跳过（若编译报缺 crc_itu_t 会失败）"
fi

cat > "$WORK/src/Makefile" <<'MK'
obj-m += crc-itu-t.o

obj-m += surface_aggregator.o
surface_aggregator-y := core.o ssh_parser.o ssh_packet_layer.o ssh_request_layer.o bus.o controller.o

obj-m += surface_aggregator_registry.o
obj-m += surface_battery.o
obj-m += surface_charger.o

ccflags-y := -I$(src)
MK

if [ "$BAT_NAME" != "BAT1" ]; then
	sed -i "s/\.name = \"BAT1\",/.name = \"$BAT_NAME\",/" "$WORK/src/surface_battery.c"
	if grep -q "\.name = \"$BAT_NAME\"," "$WORK/src/surface_battery.c"; then
		echo "  电池设备名改为 $BAT_NAME"
	else
		echo "  警告：没找到 BAT1 命名点，保持上游默认"
	fi
fi

say 5/6 "编译模块"
JOBS=$(nproc 2>/dev/null || echo 2)
# CONFIG_SURFACE_AGGREGATOR_BUS 未在目标内核 enable，头文件会退化成空实现，这里手动打开
make -C "$WORK/kdir" M="$WORK/src" \
	CONFIG_MODULE_SIG=n \
	KCFLAGS="-DCONFIG_SURFACE_AGGREGATOR_BUS" \
	modules -j"$JOBS"

say 6/6 "安装模块并更新依赖"
DEST=/lib/modules/$KVER/extra/surface-battery
mkdir -p "$DEST"
cp "$WORK"/src/*.ko "$DEST"/
depmod -a "$KVER"
ls -l "$DEST"
