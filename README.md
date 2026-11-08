# fnos-surface-battery

在飞牛 fnOS 上给 **Microsoft Surface Pro 7 / 7+** 补上电池驱动，让系统能读到内置电池与供电状态（`BAT0` / `ADP1`）。

解决两个直接问题：

- `/sys/class/power_supply` 空目录，系统完全不知道有电池
- fnOS 的 UPS 功能因此无法把内置电池当作 UPS 使用

## 为什么需要它

Surface Pro 7 属于微软「第 7 代」Surface。从这一代开始，电池与供电信息不再通过标准 ACPI 接口暴露，而是由 **Surface System Aggregator Module（SSAM，嵌入式控制器）** 直接提供。

Linux 上游从 5.13 起就有对应驱动：

| 模块 | 作用 | 产物 |
| --- | --- | --- |
| `surface_aggregator` | SSAM 总线 / 控制器核心 | — |
| `surface_aggregator_registry` | 设备注册表，按 ACPI ID 认机型（SP7 = `MSHW0116`） | 创建电池/供电等子设备 |
| `surface_battery` | 电池驱动 | `/sys/class/power_supply/BAT0` |
| `surface_charger` | 供电（充电器）驱动 | `/sys/class/power_supply/ADP1` |
| `crc-itu-t` | SSAM 用到的 CRC-ITU-T，部分发行版内核没编 | — |

而面向 NAS 的内核通常只编通用驱动（`sbs-battery`、`max17042`、`bq27xxx`、ACPI battery……），这些都需要 I2C 或 ACPI 电池接口，对 Surface 无效。结果就是：**硬件在、ACPI 里能看到 SSAM 控制器，但没有任何驱动去绑定它**，`/sys/class/power_supply` 永远是空的。

这个项目就是把这 5 个模块对着目标机器的内核头文件编出来，装进 `/lib/modules/<版本>/extra/`，并配置开机自动加载。

## 实测环境

- 设备：Microsoft Surface Pro 7（i5-1035G4 / 8GB）
- 系统：fnOS 1.2.1000，内核 `6.18.18.c1186-trim`
- 结论：安装后 `BAT0`、`ADP1` 正常出现，重启后自动加载，fnOS 的 UPS 页面可以使用内置电池

其它基于 Debian、且 `/usr/src/linux-headers-$(uname -r)` 与 `/boot/config-$(uname -r)` 齐全的发行版理论上也能用，但没有逐一验证。

## 前置条件

1. 机器是 Surface Pro 7 / 7+（ACPI ID `MSHW0116` / `MSHW0119`）。
   其它 Surface 型号可对照下表改 `surface_aggregator_registry` 的支持情况，本项目未做适配。
2. 系统里有 **Docker**（fnOS 自带），用来提供编译工具链。
3. 存在这两个路径：

   ```sh
   ls /usr/src/linux-headers-$(uname -r)   # 必须存在，且含 Module.symvers
   ls /boot/config-$(uname -r)             # 必须存在
   ```

   没有的话需要先装对应内核的头文件包，本项目不负责补。

## 安装

以 root 在目标机器上执行：

```sh
git clone https://github.com/YunJian101/FnOS-UPS-SurfacePro7.git
cd FnOS-UPS-SurfacePro7
sudo sh install.sh
```

脚本会：

1. 校验内核头文件、配置文件
2. 起一个临时 `debian:bookworm-slim` 容器（只挂载 `/usr/src`、`/boot` 只读，`/lib/modules` 可写）
3. 在容器内安装 gcc/make 等工具，按 `uname -r` 对应的上游版本号下载内核源码，只解出需要的那几个文件
4. 编译 5 个模块，装到 `/lib/modules/$(uname -r)/extra/surface-battery/`，执行 `depmod`
5. 写入 `/etc/modules-load.d/surface-battery.conf` 实现开机自动加载
6. 立即 `modprobe` 一次，无需重启即可生效

常用参数（环境变量）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BAT_NAME` | `BAT0` | 电池设备名。上游驱动默认叫 `BAT1`，部分上层软件只认 `BAT0`，所以默认改成 `BAT0`；想要原生命名就传 `BAT1` |
| `IMAGE` | `debian:bookworm-slim` | 编译用镜像 |

```sh
sudo BAT_NAME=BAT1 sh install.sh
```

## 验证

```sh
ls /sys/class/power_supply
# 期望输出：ADP1  BAT0

cat /sys/class/power_supply/BAT0/capacity      # 电量百分比
cat /sys/class/power_supply/BAT0/status        # Charging / Discharging / Full
cat /sys/class/power_supply/ADP1/online        # 1 = 接着电

modinfo surface_battery
```

重启后再执行一次 `ls /sys/class/power_supply`，确认开机自动加载有效。

## 卸载

```sh
sudo sh uninstall.sh
sudo reboot
```

脚本会删除模块目录与 `modules-load.d` 配置并重跑 `depmod`。已经加载进内核的模块要到重启后才消失。

## 内核升级后

模块是按内核版本编译的，`vermagic` 必须匹配。系统升级内核后：

1. 确认新内核的 headers 与 config 已就位
2. 重新执行 `sudo sh install.sh`

脚本会按新的 `uname -r` 重新编译安装。旧版本目录留在 `/lib/modules/<旧版本>/extra/` 里不会干扰，可以手动删。

## 已知问题

- **fnOS「资源监控」里的电池卡片仍可能显示为空**。在测试机上，安装后 `appcgi.resmon.battery` 一直返回 `errno 100030002`，即使内核已经正确暴露 `BAT0`；触发 uevent 重扫、重启 `resmon_service` 均无效。而 UPS 设置页面可以正常使用内置电池。如果你更在意监控页，可另开 issue 一起看。
- `CONFIG_MODULE_SIG_FORCE` 打开的内核会拒绝加载未签名模块。本项目编译时关闭了签名（`CONFIG_MODULE_SIG=n`），如果目标内核强制校验签名，需要自行配置签名密钥。
- 只验证了 x86_64。

## 目录结构

```
install.sh                     # 一键安装（宿主侧，需 root）
uninstall.sh                   # 卸载
scripts/build-and-install.sh   # 容器内编译安装脚本
docs/how-it-works.md           # 原理与排障细节
```

## 许可

脚本部分 MIT。编译产物来自 Linux 内核源码，遵循 GPL-2.0。

本项目与微软、飞牛官方无关，按「现状」提供，风险自负。
