#!/bin/bash
# =============================================================================
# 70_personalize.sh — «персонификация» установленной системы
# Версия: v1.3.3
# Дата:   2025-12-11
# -----------------------------------------------------------------------------
# Что делает:
#   1) Генерирует новый machine-id.
#   2) Создаёт свежий random-seed.
#   3) Добавляет записи для созданных LV в конец /etc/fstab, используя /dev/mapper/*
#      и, при вынесенном /var/log на отдельный диск, LABEL=VARLOG.
#   4) Переключает логирование с LiveCD на лог внутри целевой системы.
#
# ВНИМАНИЕ:
#   Предполагается, что на шаге 60 был скопирован стандартный fstab-шаблон,
#   содержащий записи для proc, devpts, tmpfs, /, /boot, ESP, swap.
# =============================================================================

log "Personification (machine-id, random-seed, fstab append)"

# --- Функции для генерации чистых строк fstab ---
# ВАЖНО:
#   • Функция печатает в stdout только готовые строки для записи в fstab.
#   • Все служебные сообщения уходят в stderr через log/echo >&2 и не попадают в файл.
generate_lv_fstab_lines() {
  local fstab_line

  # /var
  if [ "${var_mb}" -gt 0 ]; then
    log "--> Appending /var (${var_fs})" >&2
    fstab_line="/dev/mapper/${vg_name}-var /var                       ${var_fs}     nosuid,relatime                                 1 2"
    echo "$fstab_line"
  fi

  # /tmp LV
  if [ "${tmp_mb}" -gt 0 ]; then
    log "--> Appending /tmp LV (${tmp_fs})" >&2
    fstab_line="/dev/mapper/${vg_name}-tmp /tmp                       ${tmp_fs}     nodev,nosuid,noexec,noatime                     0 0"
    echo "$fstab_line"
  fi

  # /var/tmp
  if [ "${vartmp_mb}" -gt 0 ]; then
    log "--> Appending /var/tmp (${vartmp_fs})" >&2
    fstab_line="/dev/mapper/${vg_name}-vartmp /var/tmp                ${vartmp_fs}     nodev,nosuid,noexec,noatime                     0 0"
    echo "$fstab_line"
  fi

  # /var/log (LV)
  # Добавляется только если не используется отдельный диск И размер LV > 0.
  if [[ "${use_varlog_disk}" != "true" && "${varlog_lv_mb}" -gt 0 ]]; then
    log "--> Appending /var/log LV (${varlog_lv_fs})" >&2
    fstab_line="/dev/mapper/${vg_name}-varlog /var/log                ${varlog_lv_fs}     nodev,nosuid,noexec,noatime                     0 0"
    echo "$fstab_line"
  fi

  # /home
  if [ "${home_mb}" -gt 0 ]; then
    log "--> Appending /home (${home_fs})" >&2
    fstab_line="/dev/mapper/${vg_name}-home /home                     ${home_fs}     nodev,nosuid,noatime                            0 0"
    echo "$fstab_line"
  fi

  # /var/log (Separate Disk)
  # Добавляется только если use_varlog_disk == "true".
  if [[ "${use_varlog_disk}" == "true" ]]; then
    log "--> Appending /var/log (Separate Disk: LABEL=${varlog_label})" >&2
    fstab_line="LABEL=VARLOG    /var/log                ${varlog_lv_fs}    nodev,nosuid,noexec,noatime                                     0 0"
    echo "$fstab_line"
  fi
}

# --- Основной код шага 70 ---

# 1) Новый machine-id в целевую систему
dbus-uuidgen > /mnt/target/etc/machine-id

# 2) Legacy-путь для D-Bus
if [ -d /mnt/target/var/lib/dbus ]; then
  cp -Lf /mnt/target/etc/machine-id /mnt/target/var/lib/dbus/machine-id
fi

# 3) Свежий random-seed
head -c512 /dev/urandom > /mnt/target/var/lib/systemd/random-seed
chmod 600 /mnt/target/var/lib/systemd/random-seed

# --- Добавление записей для дополнительных LV в /etc/fstab ---
FSTAB_PATH=/mnt/target/etc/fstab

# Инициализация переменных (для корректного выполнения)
: "${var_mb:=0}"
: "${tmp_mb:=0}"
: "${vartmp_mb:=0}"
: "${home_mb:=0}"
: "${varlog_lv_mb:=0}"
: "${use_varlog_disk:=false}"
: "${vg_name:=vg0}"

: "${var_fs:=ext4}"
: "${tmp_fs:=ext4}"
: "${vartmp_fs:=ext4}"
: "${home_fs:=ext4}"
: "${varlog_lv_fs:=ext4}"
: "${varlog_label:=VARLOG}"

log "Starting append of new Logical Volumes to /mnt/target/etc/fstab"

# Добавляем пустую строку-разделитель перед нашими записями
printf "\n" >> "$FSTAB_PATH"

# Генерируем строки и добавляем их в fstab
generate_lv_fstab_lines >> "$FSTAB_PATH"

log "Appending to fstab complete."

# 4) Переключаем лог внутрь целевой ОС
switch_log_to_target

# -----------------------------------------------------------------------------
# Предложения по улучшению (не влияют на работу шага):
# 1) Явно обнулять /mnt/target/var/lib/systemd/random-seed до распаковки архивов,
#    если в root.tgz уже лежит старый seed, чтобы гарантировать отсутствие «хвостов».
# 2) Ввести переменную PERSONA_FORCE=true для принудительного перегенерирования
#    machine-id/random-seed даже при повторном запуске шага.
# -----------------------------------------------------------------------------```

