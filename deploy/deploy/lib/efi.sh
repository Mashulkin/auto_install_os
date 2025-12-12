#!/bin/bash
# =============================================================================
# lib/efi.sh — работа с EFI System Partition (ESP)
# Версия: v1.0.1
# Дата:   2025-12-11
# -----------------------------------------------------------------------------
# Назначение:
#   Утилита для «обезвреживания» лишних EFI System Partition (ESP) на узле,
#   чтобы прошивка/загрузчик не подхватывали старые загрузочные записи
#   с других дисков.
#
# Основная функция:
#   neutralize_other_esps <keep1> <keep2> ...
#
# Что делает neutralize_other_esps:
#   • Находит все GPT-разделы с типом EFI System Partition (ESP).
#   • Оставляет нетронутыми только те, которые явно переданы в списке
#     аргументов (keep_list).
#   • Для всех остальных:
#       - переименовывает метку тома (LABEL) на случайную ESPOLD<HEX>,
#       - монтирует ESP во временную точку и удаляет каталоги EFI/BOOT,
#         EFI/ALT, EFI/GRUB, EFI/grub (основные пути загрузчиков).
#
# Как определяется ESP:
#   • По типу GUID раздела GPT:
#       c12a7328-f81f-11d2-ba4b-00a0c93ec93b (EFI System Partition)
#
# Вход:
#   • keep_list — список путей разделов, которые НЕ трогаем (например,
#     /dev/sda1, /dev/nvme0n1p1 и т.п.).
#
# Замечания по безопасности:
#   • Монтирование производится временно в /mnt/neutralize-efi.
#   • Переименование метки выполняется через dosfslabel или fatlabel
#     (если доступны в системе).
#   • Удаляются только подкаталоги внутри EFI/ (BOOT, ALT, GRUB, grub),
#     корень раздела не чистится целиком.
#   • Ошибки внешних команд (lsblk, dosfslabel, mount и проч.) не считаются
#     фатальными — установка не должна падать на «нестандартных» разметках/ФС.
# =============================================================================

# Обезвреживание чужих ESP (не наших): переименовать метку и удалить EFI/*.
neutralize_other_esps(){
  local keep_list=("$@")                      # список ESP, которые нужно сохранить
  local esp_guid="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"  # GPT type GUID для ESP

  # Временная точка монтирования для «нейтрализации»
  mkdir -p /mnt/neutralize-efi

  # Перебираем все разделы по данным lsblk (путь и тип раздела GPT)
  while read -r path type; do
    # Интересуют только разделы с типом ESP; остальные пропускаем
    [[ "$type" != "$esp_guid" ]] && continue

    # Если раздел в списке «исключений» (keep_list) — не трогаем
    local skip=0
    for k in "${keep_list[@]}"; do
      [[ "$path" == "$k" ]] && skip=1
    done
    ((skip)) && continue

    # Переименовать метку FAT-тома в уникальную (ESPOLD<случайные 2 байта HEX>)
    # Предпочтительно dosfslabel; если нет — fatlabel.
    if command -v dosfslabel >/dev/null 2>&1; then
      dosfslabel "$path" "ESPOLD$(hexdump -n2 -e '2/1 \"%02X\"' /dev/urandom)"
    elif command -v fatlabel >/dev/null 2>&1; then
      fatlabel "$path" "ESPOLD$(hexdump -n2 -e '2/1 \"%02X\"' /dev/urandom)"
    fi

    # Пробуем смонтировать ESP как vfat и удалить «критичные» каталоги в EFI/
    if mount -t vfat "$path" /mnt/neutralize-efi 2>/dev/null; then
      rm -rf \
        /mnt/neutralize-efi/EFI/BOOT \
        /mnt/neutralize-efi/EFI/ALT  \
        /mnt/neutralize-efi/EFI/GRUB \
        /mnt/neutralize-efi/EFI/grub 2>/dev/null || true

      # Нормально размонтируем; если занято — ленивый umount
      umount /mnt/neutralize-efi || umount -l /mnt/neutralize-efi
    fi

  # Источник данных: список всех разделов с их PARTTYPE (GUID), без заголовков
  done < <(lsblk -rno PATH,PARTTYPE)
}

# -----------------------------------------------------------------------------
# Предложения по улучшению (идеи; не влияют на работу библиотеки):
#
# 1) Расширить список удаляемых путей (например, дистрибутив-специфичные
#    каталоги) через переменную окружения вида:
#      EFI_PURGE_DIRS="BOOT ALT GRUB grub redos altlinux ..."
#
# 2) Проверять тип ФС раздела (blkid -t TYPE=vfat) перед попыткой dosfslabel /
#    fatlabel и монтирования с -t vfat, чтобы не тратить время на неподдерживаемые
#    типы и не плодить лишние ошибки.
# -----------------------------------------------------------------------------

