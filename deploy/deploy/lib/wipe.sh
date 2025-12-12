#!/bin/bash
# =============================================================================
# lib/wipe.sh — функции для грубой и точечной очистки устройств хранения
# Версия: v1.0.2
# Дата:   2025-12-11
# -----------------------------------------------------------------------------
# Назначение:
#   Набор функций для приведения дисковой подсистемы в «чистое» состояние
#   перед разметкой и развёртыванием ОС.
#
# Что здесь есть:
#   - settle():
#       аккуратная «синхронизация» с udev после изменений в устройствах.
#
#   - reread_pt(<disk>):
#       принудительное перечитывание таблицы разделов ядром (partprobe,
#       blockdev --rereadpt, partx -u).
#
#   - global_wipe():
#       максимальная зачистка следов LVM/md/dm на всей системе (swapoff, stop md,
#       VG/LV/PV remove, dmsetup remove).
#
#   - log_disk_snapshot():
#       вывод состояния дисков, LVM, MD и swap (диагностический снимок для отладки).
#
#   - wipe_disk_full(<name>):
#       агрессивная очистка конкретного диска: unmount, stop md, zero-superblock,
#       wipefs, dd по началу/концу диска, sgdisk --zap-all.
#
# ВНИМАНИЕ:
#   • Эти процедуры предельно разрушительны. Использовать только на LiveCD
#     перед развёртыванием ОС.
#   • Ошибки внешних утилит сознательно «глушатся» через `|| true`, чтобы не
#     ронять установку на «мусорных» состояниях железа.
#   • Логирование предполагает наличие функций log/log_level из lib/log.sh.
# =============================================================================

# ---- udev helpers -----------------------------------------------------------

# Ожидаем, пока udev «догонит» изменения устройств (создание/удаление нод и т.п.).
# Дополнительные 0.5s — чтобы сгладить флапающие сценарии на медленном «железе».
settle(){ udevadm settle || true; sleep 0.5; }

# Принудительно сообщаем ядру, что таблица разделов могла измениться:
#   - partprobe          — мягкая попытка «подтолкнуть» ядро к перечитыванию PT;
#   - blockdev --rereadpt — прямой запрос перечитать PT;
#   - partx -u           — обновить сведения о разделах (включая nvme с pN);
# После этого — короткое ожидание udev.
reread_pt(){
  local d="$1"
  partprobe "$d" 2>/dev/null || true
  blockdev --rereadpt "$d" 2>/dev/null || true
  partx -u "$d" 2>/dev/null || true
  settle
}

# ---- Диагностический снимок системы (Snapshot) ------------------------------
# Выводит состояние дисков, LVM, MD и swap. Используется, например,
# шагом 10_global_wipe.sh перед/после зачистки.
log_disk_snapshot() {
  log_level "DEBUG" "--- DISK SNAPSHOT START ---"
  echo "=== lsblk -fp ==="
  lsblk -fp || true
  echo "=== LVM PV/VG/LV ==="
  pvs -o pv_name,vg_name,pv_fmt,pv_uuid || true
  vgs -o vg_name,vg_fmt,vg_uuid,vg_attr,vg_size,vg_free || true
  lvs -o vg_name,lv_name,lv_path,lv_attr,lv_size || true
  echo "=== MDADM Arrays ==="
  for md in /dev/md*; do
    [[ -e "$md" ]] && mdadm --detail "$md" || true
  done
  echo "=== SWAP ==="
  cat /proc/swaps || true
  echo "=== MOUNTS (target/mapper) ==="
  mount | grep -E '/mnt/target|/dev/mapper' || true
  log_level "DEBUG" "--- DISK SNAPSHOT END ---"
}

# ---- глобальная зачистка md/LVM/dm ------------------------------------------
# Полезно запускать в самом начале перед разметкой: снимает swap, стопает md,
# удаляет volume group'ы, physical volume'ы, dm-маппинги. Идея — привести узел
# к максимально «чистому» состоянию, чтобы новая разметка/создание md/LVM прошли
# без конфликтов с прежними метаданными.
global_wipe(){
  log "global LVM/md/dm"

  # 0) На всякий случай выключаем swap (если он активен — бывает на «живых» образах).
  swapoff -a || true

  # 1) Останавливаем все md-устройства, если они есть.
  #    Перебор по /dev/md* безопасен: если паттерн пуст — условие с [[ -e ]] не сработает.
  for md in /dev/md*; do
    [[ -e "$md" ]] && mdadm --stop "$md" 2>/dev/null || true
  done

  # 2) Удаляем superblock'и mdadm у всех устройств-участников RAID
  #    (blkid-детект TYPE=linux_raid_member). sort -u — от «дубликатов».
  while read -r m; do
    [[ -n "$m" ]] && mdadm --zero-superblock --force "$m" 2>/dev/null || true
  done < <(blkid -t TYPE=linux_raid_member -o device 2>/dev/null | sort -u)

  # 3) Деактивируем все VG, потом пытаемся снести LV и сами VG.
  vgchange -an 2>/dev/null || true
  while read -r vg; do
    [[ -n "$vg" ]] && { lvremove -f "$vg" 2>/dev/null || true; vgremove -f "$vg" 2>/dev/null || true; }
  done < <(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}')

  # 4) Удаляем подписи PV (физических томов LVM), если остались.
  while read -r pv; do
    [[ -n "$pv" ]] && pvremove -ff "$pv" 2>/dev/null || true
  done < <(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}')

  # 5) Чистим device-mapper узлы (они иногда «держат» старые маппинги).
  dmsetup remove --force --retry /dev/mapper/* 2>/dev/null || true

  settle
}

# ---- ПОЛНАЯ очистка конкретного диска (очень агрессивная) -------------------
# Аргумент:
#   $1 — имя блочного устройства БЕЗ /dev/ (например: sda, nvme0n1).
#
# Что делаем:
#   1) Размонтируем всё, что привязано к этому диску/его разделам.
#   2) Остановим md-RAID, где фигурирует диск (или его разделы).
#   3) mdadm --zero-superblock на самом диске и всех его разделах (sda1, nvme0n1p1, ...).
#   4) wipefs -af на диске и разделах (снимаем сигнатуры файловых систем).
#   5) Нулим первые 16 MiB и последние 16 MiB — там часто лежат superblock 1.2,
#      GPT-заголовки/копии и прочие «хвостовые» метаданные.
#   6) sgdisk --zap-all (зачистка GPT/MBR) и перечитываем PT (reread_pt).
wipe_disk_full(){
  local name="$1"

  # Базовая проверка корректности параметра.
  if [[ -z "$name" ]] || [[ ! -b "/dev/$name" ]]; then
    log "[WIPE] skip: '$name' is not a block device"; return 0
  fi

  local disk="/dev/$name"
  log "[WIPE] $disk (stop md, zero superblocks, wipe start+end, wipefs)"

  # Размонтировать всё, что висит на этом диске или его разделах.
  # lsblk -rno PATH /dev/sdX выдаёт список путей /dev/sdX, /dev/sdX1, ...
  while read -r p; do
    umount "$p" 2>/dev/null || true
  done < <(lsblk -rno PATH "$disk" | tail -n +1)

  # 1) Остановить md-массивы, где участвует диск (или раздел).
  #    mdadm -D выводит детали; ищем имя диска в составе active/clean массива.
  for md in /dev/md*; do
    [[ -e "$md" ]] || continue
    if mdadm -D "$md" 2>/dev/null | grep -qE "(active|clean).*$(basename "$disk")"; then
      mdadm --stop "$md" 2>/dev/null || true
    fi
  done

  # 2) Снести superblock'и mdadm на диске и всех его разделах (sda1, nvme0n1p1).
  mdadm --zero-superblock --force "$disk" 2>/dev/null || true
  for p in /dev/${name}[0-9]* /dev/${name}p[0-9]*; do
    [[ -b "$p" ]] || continue
    mdadm --zero-superblock --force "$p" 2>/dev/null || true
  done

  # 3) Удалить сигнатуры ФС (ext4/xfs/…): сначала диск, затем каждый раздел.
  wipefs -af "$disk" 2>/dev/null || true
  for p in /dev/${name}[0-9]* /dev/${name}p[0-9]*; do
    [[ -b "$p" ]] || continue
    wipefs -af "$p" 2>/dev/null || true
  done

  # 4) Затираем «голову» диска (первые 16 MiB) и «хвост» (последние 16 MiB).
  # oflag=direct + conv=fsync — писать минуя кэш и дождаться сброса на носитель.
  dd if=/dev/zero of="$disk" bs=1M count=16 oflag=direct conv=fsync 2>/dev/null || true

  # Посчитать общий размер (байт) и затереть «хвост», если диск > 32 MiB.
  local szB; szB=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
  if [[ "$szB" -gt 33554432 ]]; then # > 32 MiB
    local mib=$(( szB / 1048576 ))
    local seek=$(( mib > 16 ? mib - 16 : 0 ))
    dd if=/dev/zero of="$disk" bs=1M count=16 seek="$seek" oflag=direct conv=fsync 2>/dev/null || true
  fi

  # 5) Стереть GPT/MBR с помощью sgdisk, затем заставить ядро перечитать PT.
  sgdisk --zap-all "$disk" 2>/dev/null || true
  reread_pt "$disk"
}

# -----------------------------------------------------------------------------
# Предложения по улучшению (идеи; не влияют на работу библиотеки):
#
# 1) В wipe_disk_full попробовать (по отдельному флагу WIPE_KILL_HOLDERS=true)
#    убивать процессы, держащие монтирование (через fuser/lsof), чтобы уменьшить
#    количество «busy» кейсов.
#
# 2) Добавить опцию детерминированной «подтерки» начала/конца через nvme sanitize /
#    blkdiscard при наличии SSD и поддержке, чтобы ускорить очистку.
#
# 3) Логировать найденные и остановленные md-устройства (списком) до и после
#    операции, чтобы было видно, что именно было зачистено.
#
# 4) Добавить «сухой запуск» (WIPE_DRY_RUN=1), который только печатает план
#    действий без реального изменения устройств.
# -----------------------------------------------------------------------------

