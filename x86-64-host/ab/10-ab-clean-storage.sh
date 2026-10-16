#!/bin/sh
# ============================================================================
# A/B 纯净固件首启存储与防掉电配置 (10-ab-clean-storage.sh)
#
# 标准 uci-defaults 机制：系统首次启动执行一次后自动被框架清理。
# 职责:
#   1. 配置引导分区 /boot 常态以只读 (ro,noatime) 挂载：
#      从物理和文件系统层杜绝突然硬断电损坏 FAT32 分区。
#      升级或切槽写入时由 ab-lib 自动临时 remount,rw 并在写完后切回 ro。
#   2. 配置数据分区 /Lager (LABEL=LAGER2) 抗断电加固参数：
#      barrier=1,commit=5,errors=remount-ro,noatime
#      强制硬件落盘屏障、缩短事务提交窗口至 5 秒、异常自动只读保护。
# ============================================================================

uci -q batch <<'EOF'
set fstab.boot=mount
set fstab.boot.label='kernel'
set fstab.boot.target='/boot'
set fstab.boot.options='ro,noatime'
set fstab.boot.enabled='1'

set fstab.lager=mount
set fstab.lager.label='LAGER2'
set fstab.lager.target='/Lager'
set fstab.lager.options='barrier=1,commit=5,errors=remount-ro,noatime'
set fstab.lager.enabled='1'
commit fstab
EOF

exit 0
