# 01 — Falcon 窗口规律：一次复位，一个操作

在 CMP 170HX 上用 nvflash 5.867 做**任何**触碰 Falcon/PMU 的操作
（`--check` / `--save` / `--protectoff` / 写入）后，卡会进入
`Falcon In HALT or STOP state`，此后所有 nvflash 操作都报：

```
ERROR:  Detecting GPU failed.
 Nvflash CPU side error Code:2Error Message: Falcon In HALT or STOP state, abort uCode command issuing process.
```

或

```
ERROR: A system restart might be required before running the utility.
```

要恢复，必须复位 Falcon。复位手段按可靠性排序：

| 手段 | 可靠性 | 备注 |
|---|---|---|
| **冷断电重上电** | ✅ 100%（实测 4 次） | 唯一可复现的解法；POST 重跑 VBIOS booter |
| 驱动重载（modprobe → nvidia-smi 全量初始化 → 干净 rmmod） | ⚠️ 偶尔成功 | 实测 1/3；且卡僵死后 unbind 会挂 D 状态 |
| `PCIe remove + rescan`（sysfs） | ⚠️ 偶尔成功 | 实测 1/3；remove 常报 EINVAL，rescan 单独无效 |
| 软重启（`reboot`） | ✅（等同于冷启动的 POST 效果） | 实测可用 |

## 规律的实证记录（同一天内）

| 时刻 | 前置状态 | 操作 | 结果 |
|---|---|---|---|
| 22:53 | 冷启动后数小时，驱动重载+卸载 | `--save`（op#1） | ✅ 数据传出（末尾报 HALT，文件完整） |
| 22:54 | 上一步之后 | `--protectoff`（op#2） | ❌ "system restart required" |
| 23:03 | PCIe remove+rescan | `--check`（op#1） | ✅ "Reading EEPROM" 成功 |
| 23:04 | 上一步之后 | 写入（op#2） | ❌ Detecting GPU failed |
| 23:29 | **冷启动** + 卸载 | `--check` ×2 卡（各 op#1） | ✅✅ 两卡全过 |
| 23:29 | 上一步之后 | 写入（op#2） | ❌ Detecting GPU failed |
| 00:11 | 冷启动 + 卸载 | 写入（op#1，无探测） | ✅ 到达确认提示符（被 stdin 问题中止） |
| 00:53 | 冷启动 + 卸载，但前一轮开机已有失败尝试 | 写入（op#1） | ❌ Detecting GPU failed（开机后卡已被上一轮弄僵） |
| 00:38 | 冷启动 + 卸载，无任何探测 | 写入（op#1） | ✅✅ **进度条 100% + "A reboot is required"** |

结论：**窗口内只做一件大事**。写入前不要跑任何探测；备份 `--save`
如果放在写入前，就必须再获得一个新窗口（即再冷启动一次）。

实测最省冷启动次数的顺序（本仓库脚本采用的顺序）：

```
冷启动 → 停服务/冻结 udev+gdm → unbind+rmmod →
  op#1 = --save 备份   （新窗口）
  op#2 = 写入          ← ❌ 会失败！
```

上面这个顺序是直觉顺序，但 **op#2 必挂**。两个解法：

1. （脚本实际采用）备份挪到**上一次开机窗口**或用更早的历史备份；
   本次开机窗口只留给写入。
2. 或者接受两次开机：第一次开机做备份，第二次开机做写入。

> 注：22:53 那次 op#1 `--save` 与 00:11 op#1 写入之间隔了多次失败尝试，
> 说明"窗口"并不严格等于复位后 30 秒内，而是"自上次 Falcon 交互成功后
> 到下一次交互之间"的某种粘性状态。不要依赖这种粘性，按"一窗一操作"纪律执行。

## unbind 卡死（D 状态）

Falcon 僵死后若驱动还在（或 udevd 又把它拉起来），

```bash
echo 0000:02:00.0 > /sys/bus/pci/drivers/nvidia/unbind
```

会挂进 D 状态（驱动 remove 回调等 GSP 关闭），10 分钟不返回，kill 不掉。
此时 rmmod 也失败。**唯一出路 = 冷断电**。
