# cmp170hx-vbios-flash

**CMP 170HX 8GB（10DE:20C2）VBIOS 250W → 300W 刷写脚本 + 完整踩坑实录。**
2026-09-26 在 Ubuntu 26.04（华南 X99-T8D 双路 E5-2698B v3，纯无头）+ nvflash 5.867 实测刷写成功。

## 为什么刷

| 项 | 250W VBIOS (92.00.67.00.01) | 300W VBIOS (92.00.6D.00.0A) |
|---|---|---|
| 功耗墙上限 | 250 W | **300 W** |
| 显存时钟上限（P0） | 1458 MHz | **1728 MHz** |
| SM 加速上限 | 1410 MHz | **1695 MHz** |
| 64GB 软件解锁（cmpunlocker 驱动补丁） | ✅ | ✅ 不受影响（实测保持 65536 MiB） |
| Device ID / Subsystem | 10DE:20C2 / 10DE:1585 | 相同（直接互刷，无 ID 冲突） |

> 300W ROM 的 strap 表与 250W 完全相同（显存容量限制原样保留），"unlocked" 只指功耗墙。
> 64GB 解锁靠驱动层 PLM 补丁（[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)），刷这个 ROM 不替代、也不破坏它。

## ⚠️ 风险声明

- VBIOS 刷写**不可逆**，刷错即变砖。170HX 无显示输出、多数用户机器无 BMC，救砖只剩 CH341A SPI 编程器夹 SOP8 芯片一条路。
- 本仓库脚本只接受**与 10DE:20C2 / 10DE:1585 匹配的官方 ROM**，并在刷前自动备份原厂 ROM。请务必先看 [docs/02-rom-verification.md](docs/02-rom-verification.md) 校验你的 ROM。
- 3 次冷启动机会成本：失败尝试会把卡 Falcon 搞僵（表现为 nvflash 全线报错），只能冷断电恢复（无 BMC 就得人按电源键）。

## 快速开始

```bash
# 0) 备齐：nvflash 5.867（NVIDIA 官网下载 linux zip）、已校验的 300W ROM、一份 250W 回滚 ROM
#    回滚 ROM 必须在【本次开机之前】就存在 —— 备份与写入不能共用一个 Falcon 窗口（见 docs/01）
# 1) 参数用环境变量覆盖（脚本头部有默认值）：
sudo INDEX=0 BDF_SELF=0000:02:00.0 BDF_OTHER=0000:81:00.0 \
     ROM=/path/to/300w.rom ROLLBACK=/path/to/250w_backup.rom \
     ./scripts/flash_170hx_300w.sh
# 2) 脚本自动：冻结 udev/gdm → 杀 /dev/nvidia* 持有者并 lsof 校验为 0 → unbind 两卡 + rmmod
#            → 写入（伪终端定时喂 y；写入 = 窗口内第一个操作）→ 回读校验 → 还原现场
# 3) 看到 "A reboot is required for the update to take effect." + exit 0 后重启
sudo reboot
# 4) 验证
./scripts/verify_170hx.sh
```

**成功判据**：nvflash 退出码 0 + typescript 出现 `A reboot is required for the update to take effect.`；
重启后 `nvidia-smi --query-gpu=vbios_version` 显示 `92.00.6D.00.0A`，`clocks.max.memory=1728`，`memory.total=65536`（装了 cmpunlocker 的话）。

**如果 unbind 挂死**（内核栈 `nv_pci_remove_helper → os_delay`，见 docs/03「usage-count 卡死」）：
某些卡/主板组合的 sysfs unbind 会**零引用也惯性挂死**。此时改用**无驱动直刷** —— 把
`install nvidia /bin/false`（连同 nvidia_modeset / nvidia_drm / nvidia_uvm）写进
`/etc/modprobe.d/` 后冷启动，驱动从头不加载，nvflash 直接写（它通过
`/sys/bus/pci/devices/` + `/dev/mem` 直访 BAR，**不需要内核驱动**），冷启动次数还从 2 次降到 1 次。
完整配方见 docs/03「无驱动直刷」。⚠️ 带着 unbind 楔死的内核发 `reboot` 会让机器卡死在重启半途
（关机路径走不完，只能人工冷断电）——所以 unbind 一挂就立刻改走这条路，别急着重启。

## 关键发现（不看必踩坑）

1. **每张卡的 Falcon 一次窗口只允许一个 nvflash 操作。**
   复位（冷启动 / 部分 PCIe rescan）之后，第一个触碰 Falcon 的 nvflash 操作（--check/--save/写入）能通，之后全部报
   `Falcon In HALT or STOP state` / `Detecting GPU failed` / `A system restart might be required`。
   ⇒ **写入必须是复位后的第一个操作**，前面别放任何 --check / --save / --protectoff 探测。
2. **可靠窗口 = 冷启动 + 卸载驱动后的第一笔。** 软件复位里只有冷启动 100% 可复现；
   `PCIe remove/rescan` 偶尔有效不可依赖；驱动重载（modprobe→rmmod）在卡僵死后可能反过来把 unbind 卡进 D 状态。
3. **`nvflash -y` 不会自动确认**（5.867 实测）。确认提示 `Press 'y' to confirm` 必须从 **真实 TTY** 读取：
   - 管道 `echo y | nvflash ...` → `console read: Bad file descriptor` → `Nothing changed!`
   - 正解：**伪终端 + 定时喂键**：
     ```bash
     ( sleep 45; echo y; sleep 500 ) | script -qec "nvflash -i 0 ROM.rom" typescript.log
     ```
     45 秒 = 覆盖 "Reading EEPROM (up to 30 seconds)" 之后的确认提示。
4. **驱动会自己回来。** gdm3 / udevd 会在几秒内重新 modprobe nvidia，刷写中途被插一脚 = 砖险。
   ⇒ 临时 `install nvidia /bin/false` blacklist（刷完删）+ 停 udevd 全部 socket + 停 gdm3。
5. **rmmod 前先 unbind 两张卡**：`echo <bdf> > /sys/bus/pci/drivers/nvidia/unbind`。
   ⚠️ **unbind 之前必须确认没有任何进程握着 `/dev/nvidia*`**（`lsof /dev/nvidia*` 为 0）：
   只要有一台 vLLM / Xorg 还开着句柄，驱动的 remove 回调就会卡死在
   `nv_pci_remove_helper → os_delay`，**事后杀掉持有者也救不回来**，只能重启。
   卡僵死时 unbind 同样挂死（kill 不掉），带病内核发 `reboot` 会卡死在重启半途。
6. **日志不要放 /tmp**（Ubuntu 重启清空），全部落在持久目录。
7. **`pkill -f "<模式>"` 会杀掉自己的 ssh 会话**（模式串就在命令行里）：用自避正则
   （`flash_gpu1_v1[8]`）或按 PID 杀。

## 文件

| 文件 | 说明 |
|---|---|
| `scripts/flash_170hx_300w.sh` | 主刷写脚本（备份→刷写→回读校验一体，卡序号可参数化） |
| `scripts/verify_170hx.sh` | 重启后验证：版本 / 64GB / 显存上限 / 功耗墙 / PLM dmesg |
| `scripts/check_rom.py` | ROM 结构校验（确认真身，见下） |
| `docs/01-falcon-window.md` | "一次窗口一个操作" 规律的完整证据链 |
| `docs/02-rom-verification.md` | 不信 md5 的 ROM 真身校验法（对照独立逆向文档逐标记核验） |
| `docs/03-failure-chronology.md` | 13 版脚本失败全记录（每种报错的含义与修法） |

## ROM 来源与校验

- 目标 ROM = NVIDIA CMP 170HX **300W build `92.00.6D.00.0A`**（2022-04-07），社区流通渠道：
  [TechPowerUp VBIOS Database #268495](https://www.techpowerup.com/vgabios/268495/268495)
  （TPU 标注 md5 `a58aae86e72b13d50603c15653350664`）。
- **注意**：不同来源 dump 的 md5 几乎必然不同——1MB SPI 里 `0xC2000` 之后是每次开机都会变的动态数据区，
  且 InfoROM 可能含 per-card 数据。**别用 md5 判真伪**，用 `scripts/check_rom.py` 做结构核验
  （NVGI 头 / devid 0x20C2 / subsys 0x1585 / 功耗字节 `E0 93 04`@0x46045 / strap tier `0x44`@0x41F53 /
  许可证区全零等，判据来自 [amoghmunikote 的 GA100 VBIOS 逆向 gist](https://gist.github.com/amoghmunikote/dafea7b6663c13edc28b33872f6e51be)）。
- 回滚 ROM 必须**提前准备**：`--save` 备份会吃掉 Falcon 窗口，所以不能和写入放在同一次开机里
  （要备份就多花一次冷启动）。若手上没有本卡的 250W 备份，**同型号另一张卡的 250W dump 也可用**——
  先比对静态区（`<0xC2000`）逐位一致即可确认等效（本仓库实测：两张卡 dump 静态区 0 字节差异，
  6 万余处差异全部落在每开机变化的动态区）。

## 回滚

用同一脚本把 `ROM` 指向备份文件再跑一遍即可（脚本对 250W/300W ROM 一视同仁，都是官方 build）。
备份 ROM 与卡对应关系：`nvidia-smi --query-gpu=pci.bus_id` ↔ nvflash `--list` 的 `B:` 总线号一一对应。

## 实测环境与现状

- 机器：华南 X99-T8D 双路 + 2× E5-2698B v3，Ubuntu 26.04，内核 7.0.0-30，NVIDIA open 610.43.03（cmpunlocker 补丁版）
- ✅ GPU0（02:00.0）：已刷 92.00.6D.00.0A，64GB / 1728 MHz 验证通过（2026-09-26 00:38）
- ✅ GPU1（81:00.0）：已刷 92.00.6D.00.0A，64GB / 1728 MHz / 1695 MHz 验证通过（2026-09-26 03:07）
- GPU1 的刷写比 GPU0 多踩两个坑（usage-count 卡死、无驱动直刷），完整过程见 `docs/03-failure-chronology.md` 的 v16–v18

## 致谢

- [amoghmunikote/cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)（64GB 解锁 + GA100 VBIOS 逆向 gist）
- [cachenetics/170tune](https://github.com/cachenetics/170tune)（SM 降压/超频）
- TechPowerUp VBIOS Database
