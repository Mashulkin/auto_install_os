#!/bin/bash
# =============================================================================
# os/redos/80_chroot.sh — CHROOT-этап для RedOS 7.3
# Версия: v1.3.1
# Дата:   2026-07-23
# -----------------------------------------------------------------------------
# Выполняется после разметки/копирования root.tgz/fstab и персонализации.
#
# Делает:
#   1) Чистит старые EFI Boot#### (efibootmgr).
#   2) Фиксирует текущую конфигурацию md-RAID (mdadm.conf) и нормализует
#      /etc/default/grub и BLS (root=UUID, MachineID, options).
#   3) Пересобирает initramfs (dracut) с явным добавлением mdraid/lvm.
#   4) Генерирует /boot/grub2/grub.cfg.
#   5) Кладёт EFI-пэйлоад и темы на КАЖДЫЙ найденный ESP и создаёт RedOS-загрузчики
#      на уровне NVRAM с динамическим определением регистра вендорской папки.
#   6) Приводит rescue-ядро к текущему MachineID (переименование файлов и BLS),
#      затем при необходимости заново генерирует grub.cfg и чистит чужие
#      rescue-артефакты.
#   7) Внутри целевой ОС устанавливает storcli (если файлы есть в /root),
#      генерирует вспомогательный /root/set-ip.sh, выполняет санитарную
#      очистку логов/истории/старых ssh-ключей, после выхода из chroot
#      запускает диагностику, аккуратно размонтирует все точки монтирования
#      и выполняет reboot.
# =============================================================================

log "CHROOT (RedOS 7.3): normalize cmdline/BLS, dracut (+raid1/mdadm), grub.cfg, EFI payload on all ESPs (A/B), rescue MachineID rename, cleanup"

# --- Сценарий, который выполнится ВНУТРИ целевой ОС ---------------------------
mkdir -p /mnt/target/tmp
cat >/mnt/target/tmp/deploy-chroot <<'CH'
#!/bin/bash
set -euo pipefail
# Лог chroot-этапа внутри целевой системы
exec > >(tee -a /var/log/deploy-chroot.log) 2>&1
echo "== $(date -Is) :: chroot stage (RedOS) =="

# Минимальные монтирования для корректной работы инструментов и efibootmgr
mount -t devpts none /dev/pts 2>/dev/null || true
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true

# --- 1) Очистить все EFI Boot#### в NVRAM -------------------------------------
if command -v efibootmgr >/dev/null 2>&1; then
  efibootmgr | awk '/^Boot[0-9A-Fa-f]{4}/ {print $1}' | while read -r tag; do
    num="${tag#Boot}"; num="${num%%[^0-9A-Fa-f]*}"
    [ "${#num}" = 4 ] && efibootmgr -q -B -b "$num" || true
  done
fi

# --- 2) mdadm.conf: зафиксировать текущую конфигурацию массивов ----------------
mkdir -p /etc/mdadm
mdadm --detail --scan > /etc/mdadm/mdadm.conf 2>/dev/null || true
cp -f /etc/mdadm/mdadm.conf /etc/mdadm.conf 2>/dev/null || true

# ====================== НОРМАЛИЗАЦИЯ cmdline и BLS =============================
# Определяем UUID корневого и swap LV, чтобы прописать root=UUID и, при желании, resume=
ROOT_LV="$(ls /dev/mapper/*-root 2>/dev/null | head -n1 || true)"
SWAP_LV="$(ls /dev/mapper/*-swap 2>/dev/null | head -n1 || true)"
ROOT_UUID=""; [ -n "$ROOT_LV" ] && ROOT_UUID="$(blkid -s UUID -o value "$ROOT_LV" 2>/dev/null || true)"
SWAP_UUID=""; [ -n "$SWAP_LV" ] && SWAP_UUID="$(blkid -s UUID -o value "$SWAP_LV" 2>/dev/null || true)"

# 2.1) /etc/default/grub: убрать старые root/resume/rd.* и добавить корректные параметры
if [ -n "$ROOT_UUID" ] && [ -f /etc/default/grub ]; then
  cur=$(sed -n 's/^GRUB_CMDLINE_LINUX="//p' /etc/default/grub | sed 's/"$//')
  cur=$(echo "$cur" | sed -E \
        -e 's/(^| )root=[^ ]+//g' \
        -e 's/(^| )resume=[^ ]+//g' \
        -e 's/(^| )rd\.[^ ]+//g' \
        -e 's/  +/ /g; s/^ //; s/ $//')
  new="root=UUID=${ROOT_UUID}"
  case " $cur " in *" rd.auto=1 "*) : ;; *) new="$new rd.auto=1" ;; esac
  [ -n "$cur" ] && new="$cur $new"
  sed -i -E "s|^GRUB_CMDLINE_LINUX=.*$|GRUB_CMDLINE_LINUX=\"${new}\"|" /etc/default/grub
fi

# 2.2) BLS (/boot/loader/entries): синхронизация MachineID и опций kernel
if [ -d /boot/loader/entries ]; then
  MID="$(cat /etc/machine-id 2>/dev/null || true)"; [ -n "$MID" ] || MID=""
  for f in /boot/loader/entries/*.conf; do
    [ -f "$f" ] || continue
    # Имя файла: <MachineID>-<rest>
    if [ -n "$MID" ]; then
      base="$(basename "$f")"
      case "$base" in
        ${MID}-*) : ;;
        *) rest="${base#*-}"; [ "$rest" != "$base" ] && mv -f "$f" "/boot/loader/entries/${MID}-${rest}" && f="/boot/loader/entries/${MID}-${rest}";;
      esac
      if grep -qi '^\s*machineid\s*=' "$f"; then
        sed -i -E "s/^\s*(MachineID|machineid)\s*=.*/MachineID=${MID}/" "$f"
      else
        echo "MachineID=${MID}" >> "$f"
      fi
    fi
    # options: убрать старые root/resume/rd.* и добавить root=UUID + rd.auto=1
    if grep -q '^options ' "$f"; then
      opts="$(sed -n 's/^options //p' "$f")"
      opts="$(echo "$opts" | sed -E \
              -e 's/(^| )root=[^ ]+//g' \
              -e 's/(^| )resume=[^ ]+//g' \
              -e 's/(^| )rd\.[^ ]+//g' \
              -e 's/  +/ /g; s/^ //; s/ $//')"
      [ -n "$ROOT_UUID" ] && opts="$opts root=UUID=${ROOT_UUID}"
      case " $opts " in *" rd.auto=1 "*) : ;; *) opts="$opts rd.auto=1" ;; esac
      sed -i -E "s|^options .*|options ${opts}|" "$f"
    fi
  done
fi
# ===================== /нормализация cmdline и BLS =============================

# --- 3) dracut: пересборка initramfs с поддержкой mdraid/lvm -------------------
shopt -s nullglob
for kdir in /lib/modules/*; do
  [ -r "$kdir/modules.dep" ] || continue
  kver="$(basename "$kdir")"
  img="/boot/initramfs-${kver}.img"
  temp_img="/tmp/initramfs_temp_${kver}.img" # Временный файл для стабильной записи

  if command -v dracut >/dev/null 2>&1; then
    echo "[$(date -Is)] [DRACUT] Attempting stable LVM/RAID build to $temp_img..." >&2

    # Основная попытка: пишем во временный файл в изолированном подпроцессе
    ( dracut -f --no-compress "$temp_img" "$kver" --add "mdraid lvm" --add-drivers "raid1" --install "mdadm mdmon" )

    # Проверяем код возврата и наличие файла
    if [ $? -eq 0 ] && [ -f "$temp_img" ]; then
        echo "[$(date -Is)] [DRACUT] Success. Moving $temp_img to $img." >&2
        mv -f "$temp_img" "$img" || true
    else
        echo "[$(date -Is)] [DRACUT] WARNING: Primary dracut attempt failed. Running simplified fallback." >&2
        # Fallback: Если первая попытка упала, пробуем упрощённый вариант
        dracut -f --no-compress "$img" "$kver" --add "mdraid lvm" || true
    fi
  fi
done
shopt -u nullglob

# --- 4) grub.cfg: сгенерировать конфигурацию меню -----------------------------
if command -v grub2-mkconfig >/dev/null 2>&1; then
  grub2-mkconfig -o /boot/grub2/grub.cfg
else
  grub-mkconfig  -o /boot/grub2/grub.cfg
fi

# --- 5) EFI-пэйлоад на КАЖДЫЙ ESP и NVRAM-записи RedOS-A/RedOS-B --------------
# Работает напрямую с устройствами ESP (тип GPT EFI или vfat), без зависимости от /boot/efi2.
install_on_esp() {
  local dev="$1" label="$2"
  local mnt="/mnt/esp.$$.$RANDOM"
  mkdir -p "$mnt"

  mount -t vfat -o rw,umask=0077 "$dev" "$mnt" || { rmdir "$mnt"; return 0; }

  # Выложить пары shim+grub в вендорские каталоги и BOOT (если они есть),
  # иначе собрать standalone BOOTX64.EFI.
  ensure_payload() {
    local m="$1" src="/boot/efi"
    
    # Ищем реальное имя вендорской папки на диске (redos или RedOS)
    local blid_alias
    blid_alias="$(ls -d "$src/EFI/"*/ 2>/dev/null | grep -iv '/BOOT/' | head -n1 || true)"
    blid_alias="$(basename "$blid_alias")"
    [ -z "$blid_alias" ] && blid_alias="redos"

    mkdir -p "$m/EFI/$blid_alias" "$m/EFI/BOOT"

    copy_pair_from() { # $1=dir with shimx64.efi+grubx64.efi
      local base="$1"
      [ -f "$base/shimx64.efi" ] && [ -f "$base/grubx64.efi" ] || return 1
      cp -f "$base/shimx64.efi"  "$m/EFI/BOOT/BOOTX64.EFI"
      cp -f "$base/grubx64.efi"  "$m/EFI/BOOT/grubx64.efi"
      cp -f "$base/shimx64.efi"  "$m/EFI/$blid_alias/shimx64.efi"
      cp -f "$base/grubx64.efi"  "$m/EFI/$blid_alias/grubx64.efi"
      return 0
    }

    copy_pair_from "$m/EFI/$blid_alias"   || \
    copy_pair_from "$src/EFI/$blid_alias" || {

      # Standalone GRUB как резервный вариант
      if command -v grub2-mkstandalone >/dev/null 2>&1; then
        grub2-mkstandalone -O x86_64-efi -o "$m/EFI/BOOT/BOOTX64.EFI" \
          "boot/grub/grub.cfg=/boot/grub2/grub.cfg" || true
        rm -f "$m/EFI/BOOT/grubx64.efi" 2>/dev/null || true
      fi
    }

    # Копируем конфиг и темы (для цветного меню RedOS)
    [ -f /boot/grub2/grub.cfg ] && cp -f /boot/grub2/grub.cfg "$m/EFI/$blid_alias/grub.cfg" 2>/dev/null || true
    if [ -d "$src/EFI/$blid_alias/themes" ]; then
      cp -rf "$src/EFI/$blid_alias/themes" "$m/EFI/$blid_alias/" 2>/dev/null || true
    fi
  }
  ensure_payload "$mnt"

  # Определяем базовый диск и номер раздела для создания EFI Boot#### записи
  local disk part
  case "$dev" in
    /dev/nvme*n*p*) disk="${dev%p*}"; part="${dev##*p}" ;;
    /dev/*[0-9])    disk="${dev%%[0-9]*}"; part="${dev##*[!0-9]}" ;;
    *)              umount "$mnt"; rmdir "$mnt"; return 0 ;;
  esac

  # Ищем точную вендорскую папку в смонтированном ESP под запись efibootmgr
  local vdir
  vdir="$(ls -d "$mnt/EFI/"*/ 2>/dev/null | grep -iv '/BOOT/' | head -n1 || true)"
  vdir="$(basename "$vdir")"
  [ -z "$vdir" ] && vdir="redos"

  # Путь загрузчика для NVRAM с УЧЁТОМ реального регистра папки
  local loader=''
  if   [ -f "$mnt/EFI/$vdir/shimx64.efi" ] && [ -f "$mnt/EFI/$vdir/grubx64.efi" ]; then
    loader="\\EFI\\${vdir}\\shimx64.efi"
  elif [ -f "$mnt/EFI/BOOT/BOOTX64.EFI" ]; then
    loader='\\EFI\\BOOT\\BOOTX64.EFI'
  fi

  [ -n "$loader" ] && efibootmgr -c -d "$disk" -p "$part" -L "$label" -l "$loader" || true
  umount "$mnt" 2>/dev/null || true
  rmdir  "$mnt" 2>/dev/null || true
}

# Собираем список ESP (тип GPT EFI или vfat)
mapfile -t _ESPS < <(lsblk -rno PATH,PARTTYPE,FSTYPE | awk '
  tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" || tolower($3)=="vfat" {print $1}')

# Устанавливаем RedOS/RedOS, если есть efibootmgr и обнаружены ESP
if command -v efibootmgr >/dev/null 2>&1 && [ "${#_ESPS[@]}" -gt 0 ]; then
  install_on_esp "${_ESPS[0]}" "RedOS"
  [ -n "${_ESPS[1]:-}" ] && install_on_esp "${_ESPS[1]}" "RedOS"
fi

# --- 6) Rescue: привести к текущему MachineID (файлы + BLS + grub.cfg) --------
echo "[chroot] Step 6: rescue MachineID rename (filenames + BLS)"
NEWMID="$(cat /etc/machine-id 2>/dev/null || true)"
if [ -n "$NEWMID" ]; then
  old_kernel="$(ls -1 /boot/vmlinuz-0-rescue-* 2>/dev/null | head -n1 || true)"
  if [ -n "$old_kernel" ]; then
    old_tag="${old_kernel##*/vmlinuz-0-rescue-}"
    if [ "$old_tag" != "$NEWMID" ]; then
      [ -f "/boot/vmlinuz-0-rescue-$old_tag" ]       && mv -f "/boot/vmlinuz-0-rescue-$old_tag"       "/boot/vmlinuz-0-rescue-$NEWMID"       || true
      [ -f "/boot/initramfs-0-rescue-$old_tag.img" ] && mv -f "/boot/initramfs-0-rescue-$old_tag.img" "/boot/initramfs-0-rescue-$NEWMID.img" || true
      for f in /boot/loader/entries/*-0-rescue.conf; do
        [ -f "$f" ] || continue
        sed -i -E "s/(\(0-rescue-)[^)]+/\1${NEWMID}/" "$f"
        sed -i -E "s/^(version\s+)0-rescue-.*/\10-rescue-${NEWMID}/" "$f"
        sed -i -E "s#^linux\s+/vmlinuz-0-rescue-.*#linux /vmlinuz-0-rescue-${NEWMID}#" "$f"
        sed -i -E "s#^initrd\s+/initramfs-0-rescue-.*#initrd /initramfs-0-rescue-${NEWMID}.img#" "$f"
        if grep -qi '^\s*machineid\s*=' "$f"; then
          sed -i -E "s/^\s*(MachineID|machineid)\s*=.*/MachineID=${NEWMID}/" "$f"
        else
          echo "MachineID=${NEWMID}" >> "$f"
        fi
      done
      # Удаляем старые rescue-артефакты с прежним MID
      for x in /boot/vmlinuz-0-rescue-* /boot/initramfs-0-rescue-*.img; do
        [ -e "$x" ] || continue
        case "$x" in *"-0-rescue-${NEWMID}"*|*"-0-rescue-${NEWMID}.img") : ;; *) rm -f -- "$x" || true ;; esac
      done
      # Перегенерация grub.cfg после правок rescue
      if command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg || true
      else
        grub-mkconfig  -o /boot/grub2/grub.cfg || true
      fi
    fi
  fi
fi

# --- 7) Install storcli and Network setup ---

echo "[chroot] Step 7: Installing storcli and configuring network"

# 7.1) Устанавливаем storcli в /opt/
if [ -f /root/storcli64 ]; then
  mkdir -p /opt/MegaRAID/storcli
  echo "[chroot] Installing storcli to /opt/MegaRAID/storcli64"
  mv /root/storcli64 /opt/MegaRAID/storcli/
  chmod 755 /opt/MegaRAID/storcli/storcli64
fi

if [ -f /root/storcli2 ]; then
  mkdir -p /opt/MegaRAID/storcli2
  echo "[chroot] Installing storcli to /opt/MegaRAID/storcli2"
  mv /root/storcli2 /opt/MegaRAID/storcli2/
  chmod 755 /opt/MegaRAID/storcli2/storcli2
fi

# 7.2) Создаем скрипт для ручной настройки IP
cat >/root/set-ip.sh <<NET_SCRIPT
#!/bin/bash

set -euo pipefail

# Параметры из install.env (подставляются как литералы)
NET_CIDR="${net_cidr}"
NET_IFACE="${net_iface}"

LAST_OCTET="\$1"
# Извлекаем базовую сеть (например, 192.168.1.) и маску (/24)
BASE_IP_PREFIX=\$(echo "\$NET_CIDR" | awk -F'.' '{print \$1"."\$2"."\$3"."}')
CIDR_MASK=\$(echo "\$NET_CIDR" | awk -F'/' '{print "/"\$2}')
NEW_IP="\${BASE_IP_PREFIX}\${LAST_OCTET}\${CIDR_MASK}"

echo "--- Настройка \${NET_IFACE} на \${NEW_IP} ---"

# Проверяем существование интерфейса
if ! nmcli device show \${NET_IFACE} >/dev/null 2>&1; then
    echo "WARNING: Interface \${NET_IFACE} not found. Skipping auto-setup."
    exit 0 # Не падаем, если интерфейс не найден
fi

# 1. Удаляем старые подключения, если они есть
nmcli connection delete "\${NET_IFACE}" 2>/dev/null || true

# 2. Создаем новое статическое подключение
nmcli connection add type ethernet con-name "\${NET_IFACE}" ifname "\${NET_IFACE}" \
    ipv4.method manual ipv4.addresses "\${NEW_IP}" autoconnect yes

# 3. Активируем подключение
nmcli connection up "\${NET_IFACE}"

echo "IP setup complete. Check with 'ip a'. You can now SSH to \${BASE_IP_PREFIX}\${LAST_OCTET}"
NET_SCRIPT

chmod +x /root/set-ip.sh

# --- Санитарная очистка логов и следов установки ------------------------------
echo "[chroot] sanitizing logs"

# 1) journal: оставить пустой свежий сегмент
if command -v journalctl >/dev/null 2>&1; then
  journalctl --rotate || true
  journalctl --vacuum-time=1s --vacuum-size=1M || true
fi

# 2) Точечные логи — обнулить, сохранив права
for f in \
  /var/log/messages /var/log/secure /var/log/maillog /var/log/cron \
  /var/log/kern.log /var/log/boot.log /var/log/dmesg \
  /var/log/audit/audit.log \
  /var/log/grubby*.log /var/log/grub*.log /var/log/dracut.log
do
  [ -f "$f" ] && truncate -s 0 "$f" || true
done

# 3) Пакетные менеджеры (RedOS: dnf/yum; ALT: apt-rpm)
for f in /var/log/dnf*.log /var/log/yum*.log /var/log/apt/*.log; do
  [ -f "$f" ] && truncate -s 0 "$f" || true
done

# 4) Инсталляторы — удалить полностью
rm -rf /var/log/anaconda 2>/dev/null || true
rm -rf /var/log/alterator* /var/log/installer* 2>/dev/null || true
rm -f  /root/anaconda-ks.cfg /root/install.log* 2>/dev/null || true

# 5) wtmp/btmp/lastlog — обнулить, но не удалять
for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
  [ -e "$f" ] && truncate -s 0 "$f" || true
done

# 6) История команд
: > /root/.bash_history 2>/dev/null || true
for h in /home/*/.bash_history; do : > "$h" 2>/dev/null || true; done

# 7) Старые «снимки dmesg» (файлы, не RAM-буфер ядра)
rm -f /var/log/dmesg* 2>/dev/null || true

# 8) Старые ssh ключи
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A

sync
echo "[chroot] logs sanitized"

# Завершение chroot-этапа
umount /dev/pts 2>/dev/null || umount -l /dev/pts 2>/dev/null || true
echo "== $(date -Is) :: chroot stage (RedOS) done =="
CH
chmod +x /mnt/target/tmp/deploy-chroot

# --- Bind-монты и запуск в chroot ---------------------------------------------
mount --bind /proc /mnt/target/proc
mount --bind /sys  /mnt/target/sys
mount --bind /dev  /mnt/target/dev
mount --bind /run  /mnt/target/run
chroot /mnt/target /bin/bash -lc '/tmp/deploy-chroot' || true

# --- Диагностика ---------------------------------------------------------------
echo "=== efibootmgr -v ==="; efibootmgr -v || true
echo "=== lsblk -fp ===";   lsblk -fp   || true
for md in /dev/md*; do [ -e "$md" ] && mdadm --detail "$md" || true; done
vgdisplay -v || true; lvdisplay -v || true

# --- Аккуратный unmount и ребут ------------------------------------------------
umount /mnt/target/boot/efi2 2>/dev/null || umount -l /mnt/target/boot/efi2 2>/dev/null || true
rm -rf /mnt/target/boot/efi2
umount /mnt/target/dev || umount -l /mnt/target/dev
umount /mnt/target/sys || umount -l /mnt/target/sys
umount /mnt/target/proc || umount -l /mnt/target/proc
umount /mnt/target/run  || umount -l /mnt/target/run
log "Cleaning up mounts..."
umount /mnt/target/boot/efi 2>/dev/null || umount -l /mnt/target/boot/efi 2>/dev/null || true
umount /mnt/target/boot     2>/dev/null || umount -l /mnt/target/boot     2>/dev/null || true
umount /mnt/target          2>/dev/null || umount -l /mnt/target          2>/dev/null || true

echo; echo "RedOS restored! Log saved to /root/deploy.log"; echo
sleep 3; reboot
