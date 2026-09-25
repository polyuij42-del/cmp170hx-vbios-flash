# 02 — ROM 真身校验（别信 md5）

## 背景

目标 ROM = CMP 170HX 8GB **300W build `92.00.6D.00.0A`**（2022-04-07）。
流通渠道：TechPowerUp VBIOS Database [#268495](https://www.techpowerup.com/vgabios/268495/268495)
（国内 IP 直连 403，需自备网络出口）、二手卖家预刷卡 dump、论坛转载等。

**md5 不可用于判真伪。** 1MB SPI 镜像的 `0xC2000` 之后是动态数据区
（训练数据/计数器，每次开机都会变），InfoROM 区域可能含 per-card 数据，
不同来源 dump 的 md5 几乎必然不同。实测：同一张卡相隔近一个月的两次
dump，VBIOS 主体区（0x0–0xC2000）逐位一致，但 md5 不同，差异全部落在
0xC2000 之后。

## 校验方法

### 第一步：nvflash 读元数据

```bash
nvflash --version ROM.rom
```

必须看到：

```
Version               : 92.00.6D.00.0A      ← 目标版本
Device ID             : 0x20C2              ← 8GB 卡
Subsystem ID          : 0x1585
Board ID              : 0x030A
Chip SKU              : 105
Project               : 1001-0108
Build Date            : 06/16/21
Modification Date     : 04/07/22
InfoROM Version       : 1001.0108.01.02
License Placeholder   : Present             ← 关键：是占位符
```

### 第二步：结构标记核验（scripts/check_rom.py）

判据来自 amoghmunikote 的 GA100 VBIOS 逆向对比文档
（cmpunlocker 作者，基于静态分析 + CH341A 实证刷写实验）：

| 标记 | 250W build (92.00.67.00.01) | 300W build (92.00.6D.00.0A) | 含义 |
|---|---|---|---|
| 功耗字节 | `90 D0 03` @0x45E45 | `E0 93 04` @0x46045 | 300W 偏移 +0x200 |
| CFG1 strap tier | `0x44` @0x41D53 | `0x44` @0x41F53 | **都是 0x44=NERFED**（300W 不解锁显存容量） |
| strap 表基址 | 0x41D41 | 0x41F41（+0x200） | |
| MAC 校验范围 | 0x2200–0x43A00 | 0x2200–0x43C00 | |
| FwSec body | 241,664 B | 242,176 B（+512） | |
| 训练表条目 | 12 | 20 | |

**重点**：strap tier 必须是 `0x44`。如果是 `0x66`，说明有人伪造 MAC 改了
显存地址深度（"64G 魔改 ROM"）——这种 ROM 刷进去 Booter 会拒载
（MAC 不匹配 → `GFW_BOOT=0x001` 卡死），是**已证实的变砖路径**。

### 第三步：许可证区检查

`0xFE504` 起的 HULK 证书区必须是全零占位符。非零 = 有人注入过证书，
按魔改 ROM 处理，不要刷。

### 第四步（可选）：与手头原厂 ROM diff

对 250W 原厂 dump 与 300W ROM 做逐字节 diff，差异簇应全部落在：

- `0x1004–0x6157`（PciAt/manifest：版本号、RFRD 字段）
- `0xBFFF–0xC748`（FwSec 头，含 +512 尺寸变化）
- `0x14511–0x42C07`（ECB 加密固件——不同 build 密文全变，正常）
- `0x43D31–0x47900`（strap/training 表 +0x200 移位）
- `0x6xxxx` 镜像副本（+0x60000 处同样一份）
- `0xC1088+` 动态数据区

出现上述区域之外的孤立差异（尤其 strap 区 `0x66`、证书区）→ 不刷。

## 刷前最后防线

脚本会在写入前用 nvflash `--version` 自动核对 devid/subsys/版本，
不匹配直接拒刷。
