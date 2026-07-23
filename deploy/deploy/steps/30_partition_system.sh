#!/bin/bash
# =============================================================================
# 30_partition_system.sh — разметка системных дисков и монтаж целевой ФС
# Версия: v2.3.0
# Дата:   2026-07-23
# -----------------------------------------------------------------------------
# Поддерживаем два сценария:
#   • ДВА ДИСКА: RAID1 для /boot (md0, metadata=1.0) и для data (md1, metadata=1.2).
#                ESP создаётся на КАЖДОМ диске отдельно (НЕ RAID).
#   • ОДИН ДИСК: GPT + LVM (ESP + /boot + PV → VG → LV swap + LV root).
#
# Модифицирован для поддержки произвольных LV (var, tmp, home, varlog, varlogaudit, vartmp)
# и выбора типа ФС (FS TYPE) из install.env.
#
# КЛЮЧЕВОЙ ФИКС ДЛЯ KERNEL 5.x: mkfs.xfs использует флаги из install.env.
# =============================================================================

set -euo pipefail
mkdir -p /mnt/target

# --- Инициализация переменных LV Size и FS Type из install.env ---
# Значения по умолчанию для обратной совместимости (если не заданы в install.env)
: "${var_mb:=0}"
: "${root_mb:=0}"
: "${tmp_mb:=0}"
: "${vartmp_mb:=0}"
: "${home_mb:=0}"
: "${varlog_lv_mb:=0}"
: "${varlogaudit_lv_mb:=0}"
: "${use_varlog_disk:=false}"
: "${vg_name:=vg0}"
: "${swap_mb:=0}"
: "${xfs_compat_flags:=}" # Используем переменную из install.env

# Определяем значения по умолчанию для FS, если они не заданы в install.env
: "${root_fs:=ext4}"
: "${var_fs:=ext4}"
: "${tmp_fs:=ext4}"
: "${vartmp_fs:=ext4}"
: "${home_fs:=ext4}"
: "${varlog_lv_fs:=ext4}"
: "${varlogaudit_lv_fs:=ext4}"

# ------------------------------ Вспомогалки ----------------------------------

# Подождать «тишину» в /proc/mdstat (нет active raid*), чтобы не попасть
# в автосборку старых массивов сразу после «возвращения» диска.
md_quiet_wait() {
  for _ in {1..20}; do
    if ! grep -qE '^[[:space:]]*md[0-9]+[[:space:]]*:\s*active' /proc/mdstat 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
}

# Сборка md с одним ретраем.
# Аргументы:
#   $1 = имя (/dev/mdX), $2 = metadata (например, 1.0 / 1.2), остальные — участники.
create_md_with_retry() {
  local md="$1" meta="$2"; shift 2
  local members=( "$@" )

  # Первая попытка (ошибка не валит скрипт, т.к. в условии if)
  if mdadm --create "$md" --level=1 --raid-devices="${#members[@]}" \
           --metadata="$meta" --force "${members[@]}"; then
    return 0
  fi

  # Ретрай: стоп скан, зачистка участников, settle — и повторная попытка
  log "[RAID] create ${md} failed once — retrying after cleanup"
  mdadm --stop --scan 2>/dev/null || true
  for p in "${members[@]}"; do
    mdadm  --zero-superblock --force "$p" 2>/dev/null || true
    wipefs -af "$p"               2>/dev/null || true
  done
  udevadm settle || true
  sleep 0.5
  md_quiet_wait || true

  # Вторая (финальная) попытка — если упадёт, set -e завершит шаг (и это правильно)
  mdadm --create "$md" --level=1 --raid-devices="${#members[@]}" \
        --metadata="$meta" --force "${members[@]}"
}

# -----------------------------------------------------------------------------

if ((${#TARGET[@]}>=2)); then
  # ======================== ВАРИАНТ: 2 ДИСКА (RAID1) ========================
  d1="${TARGET[0]}"; d2="${TARGET[1]}"

  # Жёсткая зачистка обоих дисков
  wipe_disk_full "$d1"
  wipe_disk_full "$d2"

  # Разметка: ESP (EF00) + /boot (8300) + md/LVM (FD00)
  for x in "$d1" "$d2"; do
    log "[RAID] partitioning /dev/${x} via sgdisk (ESP НЕ в RAID)"
    sgdisk --zap-all "/dev/${x}" || true
    sgdisk -n 1:2048:+${esp_mb}MiB -t 1:EF00 "/dev/${x}"   # 1: ESP
    sgdisk -n 2:0:+${boot_mb}MiB -t 2:8300 "/dev/${x}"     # 2: /boot
    sgdisk -n 3:0:0              -t 3:FD00 "/dev/${x}"     # 3: RAID/LVM
    partprobe "/dev/${x}" 2>/dev/null || true
    udevadm settle || true
  done

  # Удобные алиасы разделов с учётом nvme/mmcblk
  d1p1=$(part_path "$d1" 1); d1p2=$(part_path "$d1" 2); d1p3=$(part_path "$d1" 3)
  d2p1=$(part_path "$d2" 1); d2p2=$(part_path "$d2" 2); d2p3=$(part_path "$d2" 3)

  # --- КРИТИЧЕСКАЯ ПРОВЕРКА ---
  if ! [ -b "$d1p1" ] || ! [ -b "$d2p1" ]; then
    log "FATAL ERROR: One or both ESP partition device nodes ($d1p1, $d2p1) not found after partitioning! Halting deployment."
    return 1
  fi
  # ----------------------------

  # Стоп любых авто-md и зачистка подписей на будущих участниках p2/p3
  mdadm --stop --scan 2>/dev/null || true
  for p in "$d1p2" "$d2p2" "$d1p3" "$d2p3"; do
    mnt=$(findmnt -rno TARGET --source "$p" 2>/dev/null || true)
    [ -n "$mnt" ] && (umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true)
    mdadm  --zero-superblock --force "$p" 2>/dev/null || true
    wipefs -af "$p"               2>/dev/null || true
    dd if=/dev/zero of="$p" bs=1M count=16 oflag=direct conv=fsync 2>/dev/null || true
  done
  udevadm settle || true
  partprobe "/dev/$d1" 2>/dev/null || true
  partprobe "/dev/$d2" 2>/dev/null || true
  sleep 0.8
  md_quiet_wait || true

  # Сборка массивов с 1-ретраем:
  md_boot=/dev/md0
  md_data=/dev/md1
  create_md_with_retry "$md_boot" 1.0 "$d1p2" "$d2p2"   # /boot → metadata=1.0
  create_md_with_retry "$md_data" 1.2 "$d1p3" "$d2p3"   # data  → metadata=1.2

  # Короткое ожидание активации (array_state != inactive)
  for d in "$md_boot" "$md_data"; do
    n="${d#/dev/}"
    for _ in {1..50}; do
      state=$(cat "/sys/block/$n/md/array_state" 2>/dev/null || echo "")
      [[ "$state" != "inactive" && -e "$d" ]] && break
      sleep 0.2
    done
  done
  udevadm settle || true

  # Убираем старые подписи и следы прежних PV/VG (если вдруг были)
  wipefs -af "$md_boot" 2>/dev/null || true
  wipefs -af "$md_data" 2>/dev/null || true
  pvremove -ff "$md_data" 2>/dev/null || true

  # LVM поверх md_data
  pvcreate -ff -y "$md_data"
  vgcreate "$vg_name" "$md_data"

  # --- Создание LV с фиксированным размером (если > 0) ---

  # SWAP
  if [ "${swap_mb}" -gt 0 ]; then
    log "[LVM] Create swap LV (${swap_mb}M)"
    lvcreate -L ${swap_mb}M "$vg_name" -n swap -y
  fi

  # /tmp
  if [ "${tmp_mb}" -gt 0 ]; then
    log "[LVM] Create /tmp LV (${tmp_mb}M)"
    lvcreate -L ${tmp_mb}M "$vg_name" -n tmp -y
  fi

  # /var/tmp
  if [ "${vartmp_mb}" -gt 0 ]; then
    log "[LVM] Create /var/tmp LV (${vartmp_mb}M)"
    lvcreate -L ${vartmp_mb}M "$vg_name" -n vartmp -y
  fi

  # /home
  if [ "${home_mb}" -gt 0 ]; then
    log "[LVM] Create /home LV (${home_mb}M)"
    lvcreate -L ${home_mb}M "$vg_name" -n home -y
  fi

  # /var/log (только если не выносится на отдельный диск и задан размер)
  if [[ "${use_varlog_disk}" != "true" && "${varlog_lv_mb}" -gt 0 ]]; then
      log "[LVM] Create /var/log LV (${varlog_lv_mb}M)"
      lvcreate -L ${varlog_lv_mb}M "$vg_name" -n varlog -y
  fi

  # /var/log/audit (только если не выносится на отдельный диск и задан размер)
  if [[ "${use_varlog_disk}" != "true" && "${varlogaudit_lv_mb}" -gt 0 ]]; then
      log "[LVM] Create /var/log/audit LV (${varlogaudit_lv_mb}M)"
      lvcreate -L ${varlogaudit_lv_mb}M "$vg_name" -n varlogaudit -y
  fi

  # --- Логика для / и /var ---
  if [ "${var_mb}" -gt 0 ]; then
      # НОВАЯ СХЕМА: / получает заданный root_mb, /var получает все остальное (100%FREE)
      if [ "${root_mb}" -eq 0 ]; then
          log "ОШИБКА: root_mb должен быть задан ( > 0) при var_mb > 0 для новой схемы разметки!"
          return 1
      fi
      log "[LVM] Scheme: New (fixed / (${root_mb}M) and 100% FREE /var)"
      lvcreate -L ${root_mb}M "$vg_name" -n root -y
      lvcreate -l 100%FREE "$vg_name" -n var -y
      export VAR_LV="/dev/mapper/${vg_name}-var"
      export ROOT_LV="/dev/mapper/${vg_name}-root"
  else
      # СТАРАЯ СХЕМА: root получает все остальное (100%FREE).
      log "[LVM] Scheme: Legacy (100% FREE /)"
      lvcreate -l 100%FREE "$vg_name" -n root -y
      export VAR_LV=""
      export ROOT_LV="/dev/mapper/${vg_name}-root"
  fi

  # --- Форматирование и Монтирование ---

  # ESP/BOOT/SWAP
  mkfs_vfat "$d1p1" ESP
  mkfs_vfat "$d2p1" ESP
  mkfs_ext4 "$md_boot" BOOT "-O ^64bit"
  if [ "${swap_mb}" -gt 0 ]; then
    mkswap -L SWAP /dev/mapper/${vg_name}-swap
  fi

  # / (root)
  log "[FS] Format and mount / ($root_fs)"
  if [[ "$root_fs" == "xfs" ]]; then
    # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
    umount_if "$ROOT_LV"
    wipefs -a "$ROOT_LV" || true
    mkfs.xfs -f -L SYSTEM ${xfs_compat_flags} -n ftype=1 "$ROOT_LV"
    mount -t xfs -o noatime "$ROOT_LV" /mnt/target
  else
    mkfs_ext4 "$ROOT_LV" SYSTEM
    mount -t ext4 -o noatime "$ROOT_LV" /mnt/target
  fi

  # /var
  if [ -n "$VAR_LV" ] && [ -b "$VAR_LV" ]; then
    log "[FS] Format and mount /var ($var_fs)"
    mkdir -p /mnt/target/var
    if [[ "$var_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VAR_LV"
      wipefs -a "$VAR_LV" || true
      mkfs.xfs -f -L VAR ${xfs_compat_flags} -n ftype=1 "$VAR_LV"
      mount -t xfs -o noatime "$VAR_LV" /mnt/target/var
    else
      mkfs_ext4 "$VAR_LV" VAR
      mount -t ext4 -o noatime "$VAR_LV" /mnt/target/var
    fi
  fi

  # /tmp
  export TMP_LV="/dev/mapper/${vg_name}-tmp"
  if [ "${tmp_mb}" -gt 0 ] && [ -b "$TMP_LV" ]; then
    log "[FS] Format and mount /tmp ($tmp_fs)"
    mkdir -p /mnt/target/tmp
    if [[ "$tmp_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$TMP_LV"
      wipefs -a "$TMP_LV" || true
      mkfs.xfs -f -L TMP ${xfs_compat_flags} -n ftype=1 "$TMP_LV"
      mount -t xfs -o noatime "$TMP_LV" /mnt/target/tmp
    else
      mkfs_ext4 "$TMP_LV" TMP
      mount -t ext4 -o noatime "$TMP_LV" /mnt/target/tmp
    fi
  fi

  # /var/tmp
  export VARTMP_LV="/dev/mapper/${vg_name}-vartmp"
  if [ "${vartmp_mb}" -gt 0 ] && [ -b "$VARTMP_LV" ]; then
    log "[FS] Format and mount /var/tmp ($vartmp_fs)"
    if [ ! -d /mnt/target/var ]; then mkdir -p /mnt/target/var; fi
    mkdir -p /mnt/target/var/tmp
    if [[ "$vartmp_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VARTMP_LV"
      wipefs -a "$VARTMP_LV" || true
      mkfs.xfs -f -L VARTMP ${xfs_compat_flags} -n ftype=1 "$VARTMP_LV"
      mount -t xfs -o noatime "$VARTMP_LV" /mnt/target/var/tmp
    else
      mkfs_ext4 "$VARTMP_LV" VARTMP
      mount -t ext4 -o noatime "$VARTMP_LV" /mnt/target/var/tmp
    fi
  fi

  # /var/log (LV)
  export VARLOG_LV="/dev/mapper/${vg_name}-varlog"
  if [[ "${use_varlog_disk}" != "true" && "${varlog_lv_mb}" -gt 0 ]] && [ -b "$VARLOG_LV" ]; then
    log "[FS] Format and mount /var/log LV ($varlog_lv_fs)"
    if [ ! -d /mnt/target/var ]; then mkdir -p /mnt/target/var; fi
    mkdir -p /mnt/target/var/log
    if [[ "$varlog_lv_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VARLOG_LV"
      wipefs -a "$VARLOG_LV" || true
      mkfs.xfs -f -L VARLOG ${xfs_compat_flags} -n ftype=1 "$VARLOG_LV"
      mount -t xfs -o noatime "$VARLOG_LV" /mnt/target/var/log
    else
      mkfs_ext4 "$VARLOG_LV" VARLOG
      mount -t ext4 -o noatime "$VARLOG_LV" /mnt/target/var/log
    fi
  fi

  # /var/log/audit (LV)
  export VARLOGAUDIT_LV="/dev/mapper/${vg_name}-varlogaudit"
  if [[ "${use_varlog_disk}" != "true" && "${varlogaudit_lv_mb}" -gt 0 ]] && [ -b "$VARLOGAUDIT_LV" ]; then
    log "[FS] Format and mount /var/log/audit LV ($varlogaudit_lv_fs)"
    if [ ! -d /mnt/target/var/log ]; then mkdir -p /mnt/target/var/log; fi
    mkdir -p /mnt/target/var/log/audit
    if [[ "$varlogaudit_lv_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VARLOGAUDIT_LV"
      wipefs -a "$VARLOGAUDIT_LV" || true
      mkfs.xfs -f -L VARLOGAUDIT ${xfs_compat_flags} -n ftype=1 "$VARLOGAUDIT_LV"
      mount -t xfs -o noatime "$VARLOGAUDIT_LV" /mnt/target/var/log/audit
    else
      mkfs_ext4 "$VARLOGAUDIT_LV" VARLOGAUDIT
      mount -t ext4 -o noatime "$VARLOGAUDIT_LV" /mnt/target/var/log/audit
    fi
  fi

  # /home
  export HOME_LV="/dev/mapper/${vg_name}-home"
  if [ "${home_mb}" -gt 0 ] && [ -b "$HOME_LV" ]; then
    log "[FS] Format and mount /home ($home_fs)"
    mkdir -p /mnt/target/home
    if [[ "$home_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$HOME_LV"
      wipefs -a "$HOME_LV" || true
      mkfs.xfs -f -L HOME ${xfs_compat_flags} -n ftype=1 "$HOME_LV"
      mount -t xfs -o noatime "$HOME_LV" /mnt/target/home
    else
      mkfs_ext4 "$HOME_LV" HOME
      mount -t ext4 -o noatime "$HOME_LV" /mnt/target/home
    fi
  fi

  # Монтаж /boot и ESP
  mkdir -p /mnt/target/boot
  mount -t ext4 -o noatime "$md_boot" /mnt/target/boot
  mkdir -p /mnt/target/boot/efi /mnt/target/boot/efi2
  mount -t vfat -o noatime,umask=0077,quiet "$d1p1" /mnt/target/boot/efi
  mount -t vfat -o noatime,umask=0077,quiet "$d2p1" /mnt/target/boot/efi2 || true

  # Экспортируем для следующих шагов
  export d1p1 d2p1 md_boot

else
  # ======================== ВАРИАНТ: 1 ДИСК (GPT+LVM) ========================
  d="${TARGET[0]}"

  # Разметка GPT: ESP → /boot → LVM PV
  parted -s /dev/${d} mklabel gpt
  parted -s /dev/${d} mkpart primary 0% ${esp_mb}MiB
  parted -s /dev/${d} set 1 esp on
  parted -s /dev/${d} set 1 boot on
  boot_end=$((esp_mb + boot_mb))
  parted -s /dev/${d} mkpart primary ${esp_mb}MiB ${boot_end}MiB
  parted -s /dev/${d} mkpart primary ${boot_end}MiB 100%
  parted -s /dev/${d} set 3 lvm on
  partprobe "/dev/${d}" 2>/dev/null || true
  udevadm settle || true

  # Алиасы разделов
  p1=$(part_path "$d" 1); p2=$(part_path "$d" 2); p3=$(part_path "$d" 3)

  # LVM поверх третьего раздела
  pvcreate "$p3"
  vgcreate "$vg_name" "$p3"

  # --- Создание LV с фиксированным размером (если > 0) ---

  # SWAP
  if [ "${swap_mb}" -gt 0 ]; then
    log "[LVM] Create swap LV (${swap_mb}M)"
    lvcreate -L ${swap_mb}M "$vg_name" -n swap -y
  fi

  # /tmp
  if [ "${tmp_mb}" -gt 0 ]; then
    log "[LVM] Create /tmp LV (${tmp_mb}M)"
    lvcreate -L ${tmp_mb}M "$vg_name" -n tmp -y
  fi

  # /var/tmp
  if [ "${vartmp_mb}" -gt 0 ]; then
    log "[LVM] Create /var/tmp LV (${vartmp_mb}M)"
    lvcreate -L ${vartmp_mb}M "$vg_name" -n vartmp -y
  fi

  # /home
  if [ "${home_mb}" -gt 0 ]; then
    log "[LVM] Create /home LV (${home_mb}M)"
    lvcreate -L ${home_mb}M "$vg_name" -n home -y
  fi

  # /var/log (только если не выносится на отдельный диск и задан размер)
  if [[ "${use_varlog_disk}" != "true" && "${varlog_lv_mb}" -gt 0 ]]; then
      log "[LVM] Create /var/log LV (${varlog_lv_mb}M)"
      lvcreate -L ${varlog_lv_mb}M "$vg_name" -n varlog -y
  fi

  # /var/log/audit (только если не выносится на отдельный диск и задан размер)
  if [[ "${use_varlog_disk}" != "true" && "${varlogaudit_lv_mb}" -gt 0 ]]; then
      log "[LVM] Create /var/log/audit LV (${varlogaudit_lv_mb}M)"
      lvcreate -L ${varlogaudit_lv_mb}M "$vg_name" -n varlogaudit -y
  fi

  # --- Логика для / и /var ---
  if [ "${var_mb}" -gt 0 ]; then
      # НОВАЯ СХЕМА: / получает заданный root_mb, /var получает все остальное (100%FREE)
      if [ "${root_mb}" -eq 0 ]; then
          log "ОШИБКА: root_mb должен быть задан ( > 0) при var_mb > 0 для новой схемы разметки!"
          return 1
      fi
      log "[LVM] Scheme: New (fixed / (${root_mb}M) and 100% FREE /var)"
      lvcreate -L ${root_mb}M "$vg_name" -n root -y
      lvcreate -l 100%FREE "$vg_name" -n var -y
      export VAR_LV="/dev/mapper/${vg_name}-var"
      export ROOT_LV="/dev/mapper/${vg_name}-root"
  else
      # СТАРАЯ СХЕМА: root получает все остальное (100%FREE).
      log "[LVM] Scheme: Legacy (100% FREE /)"
      lvcreate -l 100%FREE "$vg_name" -n root -y
      export VAR_LV=""
      export ROOT_LV="/dev/mapper/${vg_name}-root"
  fi

  # --- Форматирование и Монтирование ---
  mkfs_vfat "$p1" ESP
  mkfs_ext4 "$p2" BOOT "-O ^64bit"
  if [ "${swap_mb}" -gt 0 ]; then
    mkswap -L SWAP /dev/mapper/${vg_name}-swap
  fi

  # / (root)
  log "[FS] Format and mount / ($root_fs)"
  if [[ "$root_fs" == "xfs" ]]; then
    # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
    umount_if "$ROOT_LV"
    wipefs -a "$ROOT_LV" || true
    mkfs.xfs -f -L SYSTEM ${xfs_compat_flags} -n ftype=1 "$ROOT_LV"
    mount -t xfs -o noatime "$ROOT_LV" /mnt/target
  else
    mkfs_ext4 "$ROOT_LV" SYSTEM
    mount -t ext4 -o noatime "$ROOT_LV" /mnt/target
  fi

  # /var
  if [ -n "$VAR_LV" ] && [ -b "$VAR_LV" ]; then
    log "[FS] Format and mount /var ($var_fs)"
    mkdir -p /mnt/target/var
    if [[ "$var_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VAR_LV"
      wipefs -a "$VAR_LV" || true
      mkfs.xfs -f -L VAR ${xfs_compat_flags} -n ftype=1 "$VAR_LV"
      mount -t xfs -o noatime "$VAR_LV" /mnt/target/var
    else
      mkfs_ext4 "$VAR_LV" VAR
      mount -t ext4 -o noatime "$VAR_LV" /mnt/target/var
    fi
  fi

  # /tmp
  export TMP_LV="/dev/mapper/${vg_name}-tmp"
  if [ "${tmp_mb}" -gt 0 ] && [ -b "$TMP_LV" ]; then
    log "[FS] Format and mount /tmp ($tmp_fs)"
    mkdir -p /mnt/target/tmp
    if [[ "$tmp_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$TMP_LV"
      wipefs -a "$TMP_LV" || true
      mkfs.xfs -f -L TMP ${xfs_compat_flags} -n ftype=1 "$TMP_LV"
      mount -t xfs -o noatime "$TMP_LV" /mnt/target/tmp
    else
      mkfs_ext4 "$TMP_LV" TMP
      mount -t ext4 -o noatime "$TMP_LV" /mnt/target/tmp
    fi
  fi

  # /var/tmp
  export VARTMP_LV="/dev/mapper/${vg_name}-vartmp"
  if [ "${vartmp_mb}" -gt 0 ] && [ -b "$VARTMP_LV" ]; then
    log "[FS] Format and mount /var/tmp ($vartmp_fs)"
    if [ ! -d /mnt/target/var ]; then mkdir -p /mnt/target/var; fi
    mkdir -p /mnt/target/var/tmp
    if [[ "$vartmp_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VARTMP_LV"
      wipefs -a "$VARTMP_LV" || true
      mkfs.xfs -f -L VARTMP ${xfs_compat_flags} -n ftype=1 "$VARTMP_LV"
      mount -t xfs -o noatime "$VARTMP_LV" /mnt/target/var/tmp
    else
      mkfs_ext4 "$VARTMP_LV" VARTMP
      mount -t ext4 -o noatime "$VARTMP_LV" /mnt/target/var/tmp
    fi
  fi

  # /var/log (LV)
  export VARLOG_LV="/dev/mapper/${vg_name}-varlog"
  if [[ "${use_varlog_disk}" != "true" && "${varlog_lv_mb}" -gt 0 ]] && [ -b "$VARLOG_LV" ]; then
    log "[FS] Format and mount /var/log LV ($varlog_lv_fs)"
    if [ ! -d /mnt/target/var ]; then mkdir -p /mnt/target/var; fi
    mkdir -p /mnt/target/var/log
    if [[ "$varlog_lv_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VARLOG_LV"
      wipefs -a "$VARLOG_LV" || true
      mkfs.xfs -f -L VARLOG ${xfs_compat_flags} -n ftype=1 "$VARLOG_LV"
      mount -t xfs -o noatime "$VARLOG_LV" /mnt/target/var/log
    else
      mkfs_ext4 "$VARLOG_LV" VARLOG
      mount -t ext4 -o noatime "$VARLOG_LV" /mnt/target/var/log
    fi
  fi

  # /var/log/audit (LV)
  export VARLOGAUDIT_LV="/dev/mapper/${vg_name}-varlogaudit"
  if [[ "${use_varlog_disk}" != "true" && "${varlogaudit_lv_mb}" -gt 0 ]] && [ -b "$VARLOGAUDIT_LV" ]; then
    log "[FS] Format and mount /var/log/audit LV ($varlogaudit_lv_fs)"
    if [ ! -d /mnt/target/var/log ]; then mkdir -p /mnt/target/var/log; fi
    mkdir -p /mnt/target/var/log/audit
    if [[ "$varlogaudit_lv_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$VARLOGAUDIT_LV"
      wipefs -a "$VARLOGAUDIT_LV" || true
      mkfs.xfs -f -L VARLOGAUDIT ${xfs_compat_flags} -n ftype=1 "$VARLOGAUDIT_LV"
      mount -t xfs -o noatime "$VARLOGAUDIT_LV" /mnt/target/var/log/audit
    else
      mkfs_ext4 "$VARLOGAUDIT_LV" VARLOGAUDIT
      mount -t ext4 -o noatime "$VARLOGAUDIT_LV" /mnt/target/var/log/audit
    fi
  fi

  # /home
  export HOME_LV="/dev/mapper/${vg_name}-home"
  if [ "${home_mb}" -gt 0 ] && [ -b "$HOME_LV" ]; then
    log "[FS] Format and mount /home ($home_fs)"
    mkdir -p /mnt/target/home
    if [[ "$home_fs" == "xfs" ]]; then
      # KERNEL 5.x FIX: Используем mkfs.xfs с флагами совместимости
      umount_if "$HOME_LV"
      wipefs -a "$HOME_LV" || true
      mkfs.xfs -f -L HOME ${xfs_compat_flags} -n ftype=1 "$HOME_LV"
      mount -t xfs -o noatime "$HOME_LV" /mnt/target/home
    else
      mkfs_ext4 "$HOME_LV" HOME
      mount -t ext4 -o noatime "$HOME_LV" /mnt/target/home
    fi
  fi

  # Монтаж целевой системы
  mkdir -p /mnt/target/boot
  mount -t ext4 -o noatime "$p2" /mnt/target/boot
  mkdir -p /mnt/target/boot/efi
  mount -t vfat -o noatime,umask=0077,quiet "$p1" /mnt/target/boot/efi

  # Экспортируем для следующих шагов
  export p1 p2
fi
