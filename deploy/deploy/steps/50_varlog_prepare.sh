#!/bin/bash
# =============================================================================
# 50_varlog_prepare.sh — вынос /var/log на отдельный диск/массив
# Версия: v1.0.1
# Дата:   2025-12-11
# -----------------------------------------------------------------------------
# Что делает:
#   • Если фича выключена (use_varlog_disk=false) — шаг тихо пропускается.
#   • Если найдено ≥2 подходящих дисков — собирает RAID1 (/dev/md2) «на весь диск».
#   • Если найден ровно 1 диск — создаёт одиночный раздел ext4 «на весь диск».
#
# Разметка:
#   • Через sgdisk. Один раздел «во всё доступное место» (1:2048:0).
#   • Для RAID — тип раздела FD00; для одиночного ext4 — 8300.
#
# Идемпотентность/повторные запуски:
#   • На входных дисках/разделах выполняется жёсткая зачистка: md-/FS-подписи,
#     нулим первые блоки (через wipe_disk_full + wipefs + dd).
#   • Ждём только активации md (array_state != inactive), не полного ресинка.
#
# Контракты/зависимости:
#   • use_varlog_disk, varlog_* и varlog_label заданы в install.env.
#   • Массив кандидатов VARLOG формируется в шаге 20_pick_disks.sh.
#   • Вспомогательные функции: wipe_disk_full, part_path, mkfs_ext4 — из lib/*.
#   • Шаг исполняется через 'source', поэтому return 0/1, а не exit.
# =============================================================================

set -euo pipefail

# ── Фича выключена → ничего не делаем
if [[ "${use_varlog_disk:-false}" != "true" ]]; then
  log "[VARLOG] disabled -> skip"
  return 0
fi

# ── Гарантируем, что VARLOG — именно массив (а не пустая строка)
if ! declare -p VARLOG >/dev/null 2>&1 || ! declare -p VARLOG 2>/dev/null | grep -q 'declare \-a'; then
  declare -a VARLOG=()
fi

# ── Кандидатов нет → шаг пропускаем
if ((${#VARLOG[@]}==0)); then
  log "[VARLOG] no candidate disks -> skip"
  return 0
fi

# Вспомогалка: создать «полный» раздел (type: FD00|8300) на всём диске
create_full_partition() {
  local disk="$1" type="$2"     # type: FD00 (RAID) или 8300 (Linux FS)
  [[ -b "/dev/$disk" ]] || { log "[VARLOG] skip /dev/$disk (not a block)"; return 0; }
  log "[VARLOG] partitioning /dev/${disk} via sgdisk (type=${type})"
  wipe_disk_full "$disk"                               # жёсткая зачистка диска
  sgdisk --zap-all "/dev/${disk}" || true              # сброс GPT/MBR
  sgdisk -n 1:2048:0 -t 1:${type} "/dev/${disk}"       # 1-й раздел: от 1MiB до конца
  partprobe "/dev/${disk}" 2>/dev/null || true
  udevadm settle || true
}

if ((${#VARLOG[@]}>=2)); then
  # ======================= ВАРИАНТ: RAID1 под /var/log =======================
  v1="${VARLOG[0]}"; v2="${VARLOG[1]}"

  create_full_partition "$v1" "FD00"
  create_full_partition "$v2" "FD00"

  v1p1=$(part_path "$v1" 1)
  v2p1=$(part_path "$v2" 1)

  # На всякий случай: стоп любых md и зачистка подписей на участниках
  mdadm --stop --scan 2>/dev/null || true
  for p in "$v1p1" "$v2p1"; do
    mnt=$(findmnt -rno TARGET --source "$p" 2>/dev/null || true)
    [ -n "$mnt" ] && (umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true)
    mdadm --zero-superblock --force "$p" 2>/dev/null || true
    wipefs -af "$p" 2>/dev/null || true
    dd if=/dev/zero of="$p" bs=1M count=16 oflag=direct conv=fsync 2>/dev/null || true
  done
  udevadm settle || true

  md_varlog=/dev/md2
  mdadm --create "$md_varlog" --level=1 --raid-devices=2 --metadata=1.2 --force "$v1p1" "$v2p1"

  # Ждём активацию массива (не полный ресинк)
  n="${md_varlog#/dev/}"
  for i in {1..50}; do
    state=$(cat "/sys/block/$n/md/array_state" 2>/dev/null || echo "")
    [[ "$state" != "inactive" && -e "$md_varlog" ]] && break
    sleep 0.2
  done
  udevadm settle || true

  # Чистим подписи на самом md2 и форматируем ext4 с меткой
  wipefs -af "$md_varlog" 2>/dev/null || true
  mkfs_ext4 "$md_varlog" "$varlog_label"

  # Монтируем в целевую систему + фиксируем конфиг mdadm
  mkdir -p /mnt/target/var/log
  mount -t ext4 -o noatime,nodev,nosuid "$md_varlog" /mnt/target/var/log
  mkdir -p /mnt/target/etc/mdadm
  mdadm --detail --scan >> /mnt/target/etc/mdadm/mdadm.conf 2>/dev/null || true

else
  # ======================= ВАРИАНТ: одиночный диск под /var/log =============
  v="${VARLOG[0]}"
  create_full_partition "$v" "8300"
  vp=$(part_path "$v" 1)

  mkfs_ext4 "$vp" "$varlog_label"
  mkdir -p /mnt/target/var/log
  mount -t ext4 -o noatime,nodev,nosuid "$vp" /mnt/target/var/log
fi

return 0

# -----------------------------------------------------------------------------
# Предложения по улучшению (идеи; не влияют на работу шага):
#
# 1) Поддержать XFS для /var/log по переменной (например, VARLOG_FS=xfs|ext4),
#    используя mkfs_xfs/mkfs_ext4 в зависимости от значения и требований политики
#    конкретного дистрибутива.
#
# 2) Добавить проверку, что varlog_label уникальна в системе (blkid -L "$varlog_label"
#    ничего не возвращает), чтобы избежать пересечения меток между разными стендами.
# -----------------------------------------------------------------------------

