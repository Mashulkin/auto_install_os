#!/bin/bash
# =============================================================================
# os/alt/80_chroot.sh — CHROOT-этап для ALT Linux
# Версия: v1.0.3
# Дата:   2025-12-11
# -----------------------------------------------------------------------------
# Что делает «снаружи» (на LiveCD):
#   1) Генерирует скрипт /tmp/deploy-chroot внутри целевой системы.
#   2) Делает bind-монты /proc,/sys,/dev,/run в /mnt/target.
#   3) Запускает скрипт в chroot.
#   4) Печатает диагностику (efibootmgr/lsblk/mdadm/lvm).
#   5) Аккуратно размонтирует всё и выполняет reboot.
#
# Что делает «внутри» (в chroot-скрипте):
#   • Чистит все старые EFI Boot#### записи (efibootmgr -B).
#   • Устанавливает GRUB в /boot/efi (и /boot/efi2, если есть) — normal + removable.
#   • Создаёт явные EFI-записи ALT-A / ALT-B на нужные диски/разделы.
#   • Обновляет mdadm.conf, собирает initrd для всех ядер, запускает update-grub.
#   • ALT-специфика: integalert fix (если доступно).
# =============================================================================

log "CHROOT (ALT): efibootmgr reset, grub-install, mdadm.conf, initrd, update-grub"

# --- 1) Готовим chroot-скрипт, который будет выполняться ВНУТРИ целевой ОС ---
cat >/mnt/target/tmp/deploy-chroot <<'CH'
#!/bin/bash
set -euo pipefail
# Внутренний лог chroot-этапа (в /var/log целевой системы)
exec > >(tee -a /var/log/deploy-chroot.log) 2>&1
echo "== $(date -Is) :: chroot stage =="

# Минимальные точки монтирования для корректной работы инструментов
mount -t devpts   none      /dev/pts              || true
mount -t efivarfs efivarfs  /sys/firmware/efi/efivars 2>/dev/null || true

# 1) Очистка EFI NVRAM (удаляем ВСЕ Boot####, чтобы не остались «старые» записи)
if command -v efibootmgr >/dev/null 2>&1; then
  while read -r tag _; do
    bn="${tag#Boot}"               # "Boot0003*" -> "0003*"
    bn="${bn%%[^0-9A-Fa-f]*}"      # оставить только 4 hex-цифры
    [[ ${#bn} -eq 4 ]] && efibootmgr -q -B -b "$bn" || true
  done < <(efibootmgr | awk '/^Boot[0-9A-Fa-f]{4}/ {print $1}')
fi

# 2) Установка GRUB в ESP №1 (и ESP №2, если есть)
# --removable добавляет /EFI/BOOT/BOOTX64.EFI на случай, если прошивка игнорирует Boot####.
grub-install --target=x86_64-efi --efi-directory=/boot/efi  --bootloader-id=ALT --recheck || true
grub-install --target=x86_64-efi --efi-directory=/boot/efi  --removable    --recheck     || true
if [ -d /boot/efi2 ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi2 --bootloader-id=ALT --recheck || true
  grub-install --target=x86_64-efi --efi-directory=/boot/efi2 --removable    --recheck     || true
fi

# 3) Создание явных EFI Boot#### записей ALT (если доступен efibootmgr)
#    Вычисляем диск/номер раздела по текущей точке монтирования.
make_entry(){
  m="$1"; label="$2"
  src=$(findmnt -rno SOURCE "$m" || true); [ -n "$src" ] || return 0
  case "$src" in
    /dev/nvme*n*p*|/dev/mmcblk*p*) disk="${src%p*}"; part="${src##*p}" ;; # nvme0n1p1 -> disk=nvme0n1, part=1
    /dev/*[0-9])                    disk="${src%%[0-9]*}"; part="${src##*[!0-9]}" ;; # sda1 -> disk=sda, part=1
    *) return 0 ;;
  esac
  # Указываем путь к установленному EFI-файлу GRUB на ESP
  efibootmgr -c -d "$disk" -p "$part" -L "$label" -l '\EFI\ALT\grubx64.efi' || true
}
if command -v efibootmgr >/dev/null 2>&1; then
  [ -d /boot/efi  ] && make_entry /boot/efi  "ALT"
  [ -d /boot/efi2 ] && make_entry /boot/efi2 "ALT"
fi

# 4) mdadm.conf: фиксируем текущую конфигурацию массивов для автосборки при старте
mkdir -p /etc/mdadm
mdadm --detail --scan > /etc/mdadm/mdadm.conf 2>/dev/null || true
cp -f /etc/mdadm/mdadm.conf /etc/mdadm.conf 2>/dev/null || true

# 5) initrd для всех найденных ядер (на случай мульти-ядёр в образе)

for kdir in /lib/modules/*; do
  [ -r "$kdir/modules.dep" ] || continue
  kver=$(basename "$kdir")
  make-initrd -k "$kver" || make-initrd -k "$kver" --add=mdadm,lvm2 || true
done

# 6) Генерация конфигурации GRUB (меню)
update-grub || true

# 6.1. Синхронизация grub_token между EFI и /boot/grub/grubenv (ALT-специфика)
echo "[chroot] syncing grub_token"

# где лежит efi grub.cfg (обычно /boot/efi/EFI/ALT/grub.cfg или /boot/efi/EFI/altlinux/grub.cfg)
efi_cfg=""
for p in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/BOOT/grub.cfg; do
  [ -f "$p" ] && { efi_cfg="$p"; break; }
done

if [ -n "$efi_cfg" ]; then
  # вытащить токен из строки вида: if [ "$grub_token" != "fh6oi1bv6hek9hlqekpi5iuj" ]; then
  token=$(grep -oE '"[0-9a-z]{10,}"' "$efi_cfg" | head -n1 | tr -d '"')
  if [ -n "$token" ]; then
    # если grubenv нет — создать
    if [ ! -f /boot/grub/grubenv ]; then
      grub-editenv /boot/grub/grubenv create || true
    fi
    grub-editenv /boot/grub/grubenv set grub_token="$token" || true
    echo "[chroot] grub_token set to: $token"
  else
    echo "[chroot] WARNING: grub_token not found in $efi_cfg"
  fi
else
  echo "[chroot] WARNING: EFI grub.cfg not found, skip grub_token sync"
fi

# 7) Отключение встренного /tmp, если нам нужно монтировать свой раздел
if [ -b /dev/mapper/${vg_name}-tmp ]; then
cat >/etc/systemd/system/tmp.mount <<EOF
[Unit]
Description=Mount /tmp from LVM

[Mount]
What=/dev/mapper/${vg_name}-tmp
Where=/tmp
Type=ext4
Options=nodev,nosuid,noexec

[Install]
WantedBy=multi-user.target
EOF

systemctl enable tmp.mount || true
fi

# 8) Install storcli + persistent IP setup (ALT, /etc/net/ifaces) ----------
echo "[chroot] Step 9: installing storcli (if present) and creating persistent ALT network config helper"

# 8.1) Устанавливаем storcli в /opt/ (если бинарники были скопированы ранее)
if [ -f /root/storcli64 ]; then
  mkdir -p /opt/MegaRAID/storcli
  echo "[chroot] Installing storcli64 to /opt/MegaRAID/storcli/storcli64"
  mv /root/storcli64 /opt/MegaRAID/storcli/
  chmod 755 /opt/MegaRAID/storcli/storcli64
fi

if [ -f /root/storcli2 ]; then
  mkdir -p /opt/MegaRAID/storcli2
  echo "[chroot] Installing storcli2 to /opt/MegaRAID/storcli2/storcli2"
  mv /root/storcli2 /opt/MegaRAID/storcli2/
  chmod 755 /opt/MegaRAID/storcli2/storcli2
fi

# 8.2) Создаем скрипт для ручной настройки IP
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

IFACE_DIR="/etc/net/ifaces/\${NET_IFACE}"

echo "--- Настройка \${NET_IFACE} на \${NEW_IP} ---"

# Проверяем существование интерфейса
if ! ip link show "\${NET_IFACE}" >/dev/null 2>&1; then
  echo "WARNING: Interface \${NET_IFACE} not found. Skipping."
  exit 0
fi

# Создаём каталог интерфейса
mkdir -p "\${IFACE_DIR}"

# Минимальный options
cat >"\${IFACE_DIR}/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
EOF

# Один IPv4 адрес, без gateway и маршрутов
echo "\${NEW_IP}" > "\${IFACE_DIR}/ipv4address"

# Активируем подключение
systemctl restart network.service

echo "IP setup complete. Check with 'ip a'. You can now SSH to \${BASE_IP_PREFIX}\${LAST_OCTET}"
NET_SCRIPT

chmod +x /root/set-ip.sh

# 9) ALT-специфика: «починка базы», чтобы при первом старте не ругался
if command -v integalert >/dev/null 2>&1; then
  echo "[chroot] running: integalert fix"
  integalert fix || true
else
  echo "[chroot] integalert not found — skipping"
fi

# --- Санитарная очистка логов и следов установки (универсально для RedOS/ALT) --
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

# 4) Инсталляторы (RedOS: anaconda; ALT: alterator/installer) — удалить полностью
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
rm -f /etc/openssh/ssh_host_*
ssh-keygen -A

sync
echo "[chroot] logs sanitized"

# Завершение chroot-этапа: уборка и выход
umount /dev/pts || umount -l /dev/pts || true
echo "== $(date -Is) :: chroot stage done =="
CH
chmod +x /mnt/target/tmp/deploy-chroot

# --- 2) Bind-монты в целевую систему для корректной работы инструментов ---
mount --bind /proc /mnt/target/proc
mount --bind /sys  /mnt/target/sys
mount --bind /dev  /mnt/target/dev
mount --bind /run  /mnt/target/run

# --- 3) Запускаем chroot-скрипт (внутренний сценарий может падать, мы не ломаемся) ---
chroot /mnt/target /bin/bash -lc '/tmp/deploy-chroot' || true

# --- 4) Диагностика: полезно иметь в общем логе на случай разборов ---
echo "=== efibootmgr -v ==="; efibootmgr -v || true
echo "=== lsblk -fp ===";   lsblk -fp || true
for md in /dev/md*; do [ -e "$md" ] && mdadm --detail "$md" || true; done
vgdisplay -v || true; lvdisplay -v || true

# --- 5) Аккуратно размонтируем всё в правильном порядке и ребутимся ---
umount /mnt/target/boot/efi2 2>/dev/null || umount -l /mnt/target/boot/efi2 2>/dev/null || true
rm -rf /mnt/target/boot/efi2
umount /mnt/target/dev || umount -l /mnt/target/dev
umount /mnt/target/sys || umount -l /mnt/target/sys
umount /mnt/target/proc || umount -l /mnt/target/proc
umount /mnt/target/run || umount -l /mnt/target/run
log "Cleaning up mounts..."
umount /mnt/target/boot/efi 2>/dev/null || umount -l /mnt/target/boot/efi 2>/dev/null || true
umount /mnt/target/boot     2>/dev/null || umount -l /mnt/target/boot     2>/dev/null || true
umount /mnt/target          2>/dev/null || umount -l /mnt/target          2>/dev/null || true

echo; echo "ALT restored! Log saved to /root/deploy.log"; echo
sleep 3; reboot

# -----------------------------------------------------------------------------
# Предложения по улучшению (не влияют на работу скрипта):
# 1) При наличии /boot на md1 можно явно включить write-intent bitmap (mdadm --grow --bitmap=internal).
# 2) В логи добавить вывод blkid -o export для ESP и /boot — удобно для сверки меток/UUID.
# -----------------------------------------------------------------------------

