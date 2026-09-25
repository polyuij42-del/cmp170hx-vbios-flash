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
| nvflash rc=0 但版本没变 | 确认流程被吞（v12 型） | **永远以回读 md5 / 重启后 nvidia-smi 为准** |
| `/tmp` 日志消失 | Ubuntu 重启清 /tmp | 日志/备份放 /data 等持久分区 |

## 成本核算

最终配方一次成功需要：**1 次冷启动 + 1 个新窗口内的写入**。
若把备份也纳入同一次开机，需要 2 次冷启动（备份一次、写入一次）。
