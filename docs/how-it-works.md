# 原理与排障

## 一、为什么标准办法不行

普通笔记本的电池通过 ACPI 的 `PNP0C0A`（Control Method Battery）设备暴露，内核 `acpi/battery` 一加载，`/sys/class/power_supply/BAT0` 就出现了。

Surface Pro 7 属于微软第 7 代 Surface。这一代把电池与供电从 ACPI 里移了出去，改由 SSAM（Surface System Aggregator Module，板载嵌入式控制器）直接提供，ACPI 命名空间里只留下一个控制器节点。

典型机器上的 ACPI 节点（`/sys/bus/acpi/devices/`）：

```
MSHW0005  MSHW0006  MSHW0040  MSHW0084  MSHW0091  MSHW0116  MSHW0125  MSHW0184
```

- `MSHW0116` —— Surface Pro 7 的 SSAM 平台枢纽（7+ 是 `MSHW0119`）
- `MSHW0084` —— SSAM 控制器本身

硬件是完整的，但没有驱动去绑定，于是：

- `/sys/class/power_supply/` 是空目录
- 发行版自带的电池驱动（`sbs-battery`、`max17042_battery`、`bq27xxx_battery`、`ds2760_battery`、`acpi/battery`）全都用不上——它们要 I2C 或 ACPI 接口
- 上层（桌面环境、监控服务、UPS 功能）看到的就是「这台机器没有电池」

验证方法：

```sh
ls /sys/class/power_supply            # 空
ls /sys/bus/acpi/devices | grep MSHW  # 有 MSHW0084 / MSHW0116
ls /lib/modules/$(uname -r)/kernel/drivers/platform/
# 若只有 mellanox、x86 之类，说明内核没编 Surface 平台驱动
```

## 二、驱动栈

上游 Linux 从 5.13 起支持这套硬件，代码位置：

```
drivers/platform/surface/aggregator/          # SSAM 核心（core/ssh_parser/ssh_packet_layer/ssh_request_layer/bus/controller）
drivers/platform/surface/surface_aggregator_registry.c
drivers/power/supply/surface_battery.c
drivers/power/supply/surface_charger.c
lib/crc/crc-itu-t.c                           # 6.9 之前是 lib/crc-itu-t.c
```

依赖链：

```
surface_battery ─┐
surface_charger ─┼─> surface_aggregator ─> crc_itu_t
registry ────────┘
```

`surface_aggregator_registry` 按 ACPI ID 认机型，为 Surface Pro 7 注册三个客户端设备（`ssam_node_group_sp7`）：供电 `ssam:01:02:01:01:01`、主电池 `ssam:01:02:01:01:00`、性能档 `ssam:01:03:01:00:01`。`surface_battery` 绑定电池节点后注册 power_supply 设备。

## 三、这个项目做的三件「非标准」事

### 1. 补 `crc_itu_t`

`surface_aggregator` 依赖内核的 `crc_itu_t()`，而 NAS 内核常见只编了 `CONFIG_CRC_ITU_T=n`。表现是：

```
insmod: can't insert 'surface_aggregator.ko': unknown symbol in module
dmesg: surface_aggregator: Unknown symbol crc_itu_t (err -2)
```

所以从同一份内核源码的 `lib/crc/crc-itu-t.c` 编一个 `crc-itu-t.ko` 补上。

### 2. 手动打开 `CONFIG_SURFACE_AGGREGATOR_BUS`

目标内核没 enable 这个选项，`include/linux/surface_aggregator/device.h` 和 `aggregator/bus.h` 会把相关函数退化成 `static inline` 空实现，结果和 `bus.c` 里的真实定义冲突：

```
bus.c:379:5: error: redefinition of 'ssam_bus_register'
```

编译时用 `KCFLAGS="-DCONFIG_SURFACE_AGGREGATOR_BUS"` 打开即可，不需要改内核源码。

### 3. 关掉模块签名

内核 `CONFIG_MODULE_SIG=y` 但没有 `CONFIG_MODULE_SIG_FORCE` 时，未签名模块仍可加载（只污染内核、`dmesg` 里有提示）。因此编译时传 `CONFIG_MODULE_SIG=n`，避免因为没有签名私钥而报错。

如果目标内核开了 `SIG_FORCE`，本项目直接不可用，需要自己配签名密钥。

### 4. 把 BAT1 改成 BAT0（可选）

上游驱动里电池叫 `BAT1`（Surface Book 3 的第二块电池是 `BAT2`）。部分上层软件只遍历 `BAT0`，所以默认改名。想要原生命名：

```sh
sudo BAT_NAME=BAT1 sh install.sh
```

## 四、安装后的持久化

两件事保证开机可用：

1. `.ko` 放在 `/lib/modules/<版本>/extra/surface-battery/`，并执行 `depmod -a <版本>`
2. `/etc/modules-load.d/surface-battery.conf` 按依赖顺序列出模块名

顺序不能错：

```
crc_itu_t
surface_aggregator
surface_aggregator_registry
surface_charger
surface_battery
```

## 五、常见问题

**模块加载失败：`unknown symbol`**
说明缺依赖。先 `insmod` / `modprobe` `crc_itu_t`，再看 `dmesg | tail`。

**`insmod: invalid module format`**
vermagic 不匹配。绝大多数情况是系统升级过内核，用新的 `uname -r` 重跑 `install.sh`。

**装完还是空的 `power_supply`**
按顺序查：

```sh
lsmod | grep -E 'surface|ssam|crc_itu'    # 5 个模块是否都在
ls /sys/class/power_supply                 # BAT0 / ADP1
dmesg | grep -iE 'surface|ssam' | tail -20 # 绑定过程
```

如果没有 `ssam` 相关日志，很可能是 `surface_aggregator` 没绑上 SSAM 控制器——检查 ACPI 里是否存在 `MSHW0116`。

**监控页看不到电池**
测试机上 fnOS 的 `appcgi.resmon.battery` 在驱动就绪后依然返回 `errno 100030002`，触发 uevent 重扫和重启 `resmon_service` 都无效；但 UPS 设置页可以正常使用内置电池。属于上层实现差异，不阻塞使用。

**`depmod: ERROR: fstatat(5, alternatives): No such file or directory`**
`depmod` 在容器里扫描模块树时碰到一条悬空链接，属于噪声：命令仍然返回 0，`modules.dep` 正常写入。可以用 `modinfo surface_battery` 复核是否登记成功。

**升级内核后失效**
重新执行 `install.sh`。旧的 `/lib/modules/<旧版本>/extra/surface-battery/` 可以删掉。

## 六、当前取值参考（Surface Pro 7 实测）

| 属性 | 值 |
| --- | --- |
| 电芯厂商 | SMP |
| 型号 | M1109598 |
| 满电电压 | 8.37 V |
| 循环次数 | 420 |
| SSAM 固件 | 14.800.139 |
