#!/bin/bash
# =============================================================================
# 60_copy_payload.sh — перенос «полезной нагрузки» (root.tgz + fstab) в целевую ОС
# Версия: v1.1.1
# Дата:   2025-12-11
# -----------------------------------------------------------------------------
# Что делает:
#   1) Копирует архив системы root.tgz из ${backup_dir} на LiveCD → /mnt/target.
#   2) Распаковывает его в /mnt/target и удаляет архив.
#   3) Копирует заранее подготовленный fstab в /mnt/target/etc/fstab.
#   4) При наличии в бэкапе утилит storcli64 / storcli2 — копирует их в
#      /mnt/target/root/ для последующей установки/использования в chroot.
#
# Предпосылки / окружение:
#   - /mnt/target уже смонтирован и содержит размеченную целевую систему.
#   - backup_ip, backup_passwd, backup_dir экспортированы ранее:
#       * backup_ip/backup_passwd — проставлены auto_install.sh (те же, что для хранилища),
#       * backup_dir — задан в install.env (подкаталог внутри общего хранилища).
#   - Доступ по scp — паролем через sshpass (StrictHostKeyChecking=off для LiveCD).
#   - Файлы storcli64 / storcli2 в backup_dir считаются опциональными: если их нет,
#     шаг просто пропускает соответствующее копирование без ошибки.
# =============================================================================

# Информируем в лог откуда и что тянем
log "Copying payload from ${backup_ip}:${backup_dir}"

# 1) Копируем архив root.tgz в корень целевой ФС
log "Starting SCP transfer: root.tgz"
sshpass -p "$backup_passwd" scp -o 'StrictHostKeyChecking=no' -q \
  root@${backup_ip}:${backup_dir}/root.tgz /mnt/target
log "SCP transfer of root.tgz finished."

# 2) Распаковка архива в /mnt/target (содержимое root.tgz — корень будущей системы)
log "Extracting root.tgz into /mnt/target..."
tar -xzf /mnt/target/root.tgz -C /mnt/target
rm -f /mnt/target/root.tgz
log "Extraction complete. Archive /mnt/target/root.tgz removed."

# 3) Копируем fstab (подготовлен под нашу схему разметки/UUID/метки)
log "Copying fstab template to /mnt/target/etc/fstab"
sshpass -p "$backup_passwd" scp -o 'StrictHostKeyChecking=no' -q \
  root@${backup_ip}:${backup_dir}/fstab /mnt/target/etc
log "fstab template copied."

# 4) Копируем storcli в /root/ для последующей установки в chroot (шаг 80)
# Проверяем наличие файла storcli64 на удаленном сервере через SSH
if sshpass -p "$backup_passwd" ssh -o StrictHostKeyChecking=no -q \
    root@${backup_ip} "test -f ${backup_dir}/storcli64"; then
  
  log "Copying storcli64 from ${backup_ip}:${backup_dir}"
  sshpass -p "$backup_passwd" scp -o 'StrictHostKeyChecking=no' -q \
    root@${backup_ip}:"${backup_dir}/storcli64" /mnt/target/root/
  log "storcli64 copied."
fi

# Проверяем наличие файла storcli2 на удаленном сервере через SSH
if sshpass -p "$backup_passwd" ssh -o StrictHostKeyChecking=no -q \
    root@${backup_ip} "test -f ${backup_dir}/storcli2"; then
  
  log "Copying storcli2 from ${backup_ip}:${backup_dir}"
  sshpass -p "$backup_passwd" scp -o 'StrictHostKeyChecking=no' -q \
    root@${backup_ip}:"${backup_dir}/storcli2" /mnt/target/root/
  log "storcli2 copied."
fi

# Чёткие права и владелец для fstab
chown root:root /mnt/target/etc/fstab
chmod 644 /mnt/target/etc/fstab

# -----------------------------------------------------------------------------
# Предложения по улучшению (не влияют на работу шага):
# 1) Проверять SHA256 root.tgz (если хранить ${backup_dir}/SHA256SUMS) перед распаковкой.
# 2) Делать предварительный df -h /mnt/target и логировать свободное место.
# 3) Поддержать альтернативный транспорт (rsync) за флагом COPY_WITH_RSYNC=true.
# -----------------------------------------------------------------------------

