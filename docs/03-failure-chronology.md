# 03 — 失败编年史（13 版脚本，每种报错的含义）

一台无头 Ubuntu（X99 双路）+ 2× CMP 170HX 8GB，nvflash 5.867。
目标：250W → 300W VBIOS。最终第 14 版成功（单卡验证）。

| 版本 | 做了什么 | 结果 | 学到什么 |
|---|---|---|---|
| v1 | 复用 2025-08 旧脚本（`yes > fifo` + `script`） | fifo 权限拒绝，未执行 | 旧脚本写法本身就脆 |
| — | 多次 `rmmod` 失败 "in use" | — | **gdm3/udevd 会秒级重拉驱动**；必须停 gdm + 冻结 udevd 全部 socket（含 varlink） |
| — | `--protectoff` / `--check` / `--save` 各处报错 | 三种报错轮流出现 | 同一系列 Falcon 状态问题（见 docs/01） |
| v2 | rescan 复位 → protectoff → 写入 | ❌ protectoff 吃掉窗口，写入报 Detecting failed | **一窗一操作**；protectoff 非必需（EEPROM 未写保护时） |
| v3 | 每步独立复位；RC 捕获 bug | ❌ 误报 WRITE-OK（`$?` 取到 tail 的） | 函数里 `RC=$?` 必须紧跟 nvflash 本体；sysfs 写 root 也会 EINVAL，要兜底 |
| v5 | 全自包含（guard→unload→写） | ❌ unbind 挂 D 状态 9 分钟 | 卡僵死后驱动卸不掉，只能冷断电 |
| v6 | + unbind 两卡 | ❌ remove EINVAL → rescan 没执行 | unwedge 函数里 remove 失败不能中断流程 |
| v7 | remove 失败也继续 rescan | ❌ 仍 Detecting failed | rescan 复位不可靠（1/3） |
| v8 | **冷启动**后 guard+unload → `--check` ×2 → 写 | ❌ 探测成功，写入死 | **探测吃掉窗口**；冷启动+卸载后 op#1 100% 能通 |
| v10 | 冷启动 → 卸载 → 直接写（op#1，`-y`） | ❌ 到达提示符后 `console read: Bad file descriptor` → Nothing changed | **`-y` 不生效**，确认必须走 TTY；这版证明 op#1 能走到提示符 |
| v11 | `echo y \| nvflash`（管道） | ❌ 同样死在提示符 | 管道≠TTY，nvflash 只认终端 |
| v12 | `yes \| script -qec`（pty+洪泛） | ❌ rc=0 但 ROM 没变（typescript 只有起始行） | pty 方向对；`yes` 洪泛 + `timeout` 行为诡异，rc=0 不可信；**必须回读校验** |
| v13 | pty + 定时 y，但写前做了 rescan | ❌ Detecting failed | rescan 又没开成窗口；回读/typescript 全丢（/tmp 重启被清） |
| **v14** | **冷启动 → 卸载 → 写入=op#1，pty+定时 y（45s），日志落 /data** | ✅✅ 进度条 100%，"A reboot is required"，rc=0；重启后 92.00.6D.00.0A 生效 | 最终配方 |
| v15 | 同配方换 `-i 1` 刷第二张 | ❌ 该次开机已被 v13 时代失败尝试污染 | 每次刷写前必须**全新冷启动** |
| v16 | 全新开机 → guard → unbind（**vLLM 还握着 /dev/nvidia1**）→ 事后才杀 vLLM | ❌ unbind 卡死在 `nv_pci_remove_helper → os_delay`（内核栈实锤），kill 持有者/kill -9 脚本都救不回，只能重启 | **见下：usage-count 卡死** |
| v17 | 重启后零引用（`lsof` 校验 HELD=0 通过）→ unbind GPU1 | ❌ **同一个 os_delay 又挂死**（8 分钟无返回），证明该机 GPU1 的 sysfs unbind 惯性挂死，与引用无关；带病内核里发 `reboot` → 机器卡死在重启半途，只能人工冷断电 | **见下：无驱动直刷** |
| **v18** | 黑名单常驻 → 冷启动**驱动从未加载** → guard 只停 udevd/gdm → nvflash 写入 op#1（pty+定时 y） | ✅✅ 进度条 100% + "A reboot is required" + rc=0；重启后 92.00.6D.00.0A / 1728 MHz / 1695 MHz 生效 | **终极配方：绕开 unbind** |

## usage-count 卡死（2026-09-26 GPU1 实测新增）

dmesg 铁证：

```
NVRM: Attempting to remove device 0000:81:00.0 with non-zero usage count!
```

- **诱因**：unbind 发起时还有进程握着 `/dev/nvidia*`（本例 = 一台忘了停的 vLLM
  `qwen-llm-2.service`，`lsof /dev/nvidia*` 可见 4 个句柄）。
- **症状**：unbind 的 sysfs write 永久阻塞，内核栈
  `unbind_store → device_driver_detach → nv_pci_remove → os_delay` 循环；
  **事后杀掉持有者进程也救不回来**（remove 回调已经进死等），`kill -9` 执行脚本
  的 bash 也杀不掉（write 系统调用卡内核）。
- **更糟的变体**：v17 证明**即使零引用**，这台机的 GPU1 sysfs unbind 也会惯性挂死。
  带着这种内核楔死状态发 `systemctl reboot`，机器会**卡死在重启半途**（关机路径
  走不完），表现为双通道失联 + 局域网全段扫不到 SSH——只能人工按电源键冷断电。
- **修法（已进脚本 [B] 段）**：把 `fuser -k /dev/nvidia*` **挪到 unbind 之前**，
  随后 `lsof /dev/nvidia*` 强制校验为 0，非 0 直接 die。若零引用仍挂死，直接升级
  到下面的无驱动直刷。

## 无驱动直刷（v18，终极配方）

适用：sysfs unbind 挂死 / 想彻底跳过驱动交互的场景。原理：nvflash 5.867 通过
`/sys/bus/pci/devices/` + `/dev/mem` 直访 PCI BAR（二进制 strings 可证），**不需要
内核驱动在位**；它引用 `/dev/nvidia*` 只是为了检测"驱动已加载"并打印警告。

```
① 写死黑名单  /etc/modprobe.d/zz-flash-window.conf: install nvidia /bin/false（×4 个模块）
② 冷断电重启  → 驱动从头不加载（initramfs 里本来就没有 nvidia）
③ guard 只剩  systemctl stop udevd×3socket + udevd + gdm3 + nvidia-persistenced
④ lsmod 校验  0 个 nvidia 模块 → 直接写入 op#1（pty + 45s 定时 y）
⑤ 成功后删黑名单 → 重启生效
```

实测细节：开机早期驱动可能仍会被拉起又自动卸载（本机 dmesg 27–39s 有完整
probe+unload 且**干净退出**，无 os_delay 挂死）——只要 `lsmod` 为 0 就可以动手。
本配方把"冷启动次数"从 2 次降到 1 次，且完全不触碰 remove 回调。

## 报错速查

| 报错 | 含义 | 修法 |
|---|---|---|
| `Falcon In HALT or STOP state` | 上一个 nvflash 操作把 Falcon 留在 HALT | 冷启动；本窗口操作已作废 |
| `A system restart might be required` | 同上（检测阶段的表述） | 冷启动 |
| `Detecting GPU failed` + `Nothing changed!` | 窗口外操作，卡未受影响 | 冷启动重试，确保写入=op#1 |
| `In order to avoid the irreparable damage ... unload the NVIDIA kernel driver` | 驱动在位（udevd/gdm 拉回来的） | blacklist `install nvidia /bin/false` + 停 udevd sockets + 停 gdm3 |
| `console read: Bad file descriptor` / 提示符后 `Nothing changed` | 确认提示没喂到（-y 无效/管道无效） | pty（`script -qec`）+ 定时喂 y |
| `Adapter not accessible or supported EEPROM not found, skipping` | Falcon 不响应枚举 | 同 Falcon 僵死 |
| `echo ... > unbind` 挂死（D 状态） | 驱动 remove 等 GSP 关闭超时 | 冷断电，无解 |
| `NVRM: ... non-zero usage count!` + unbind 永久卡 `os_delay` | unbind 时有进程握着 /dev/nvidia*（lsof 查） | 重启；下次先 `fuser -k /dev/nvidia*` + lsof 校验为 0 再 unbind |
| 零引用 unbind 仍卡 `os_delay`（本机 GPU1 惯性） | 该卡驱动 remove 回调天生挂死 | 无驱动直刷（黑名单+冷启动，见上节） |
| `reboot` 后机器双通道失联、局域网无 SSH | 关机路径被内核楔死状态卡住 | 只能人工按电源键冷断电；发 reboot 前确认没有卡在内核的写操作 |
| nvflash rc=0 但版本没变 | 确认流程被吞（v12 型） | **永远以回读 md5 / 重启后 nvidia-smi 为准** |
| `/tmp` 日志消失 | Ubuntu 重启清 /tmp | 日志/备份放 /data 等持久分区 |

## 成本核算

最终配方一次成功需要：**1 次冷启动 + 1 个新窗口内的写入**。
若把备份也纳入同一次开机，需要 2 次冷启动（备份一次、写入一次）。
