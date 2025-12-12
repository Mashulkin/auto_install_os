# Комплекс «архив → развёртывание из бандла» (RedOS/ALT)

> Документ описывает **полный цикл**: как снять архив с «эталонной» системы, собрать бандл установщика, а затем **на LiveCD** развернуть новую машину из архива с автоматической разметкой дисков, настройкой EFI/GRUB и chroot‑постконфигом.  
> Код уже рабочий; ниже — порядок использования, справочник переменных и подсказки.

---

## 0) Состав репозитория

Файлы на **сервере бэкапов** (по умолчанию `10.3.15.250`, `root/root`):

```text
/backup/
├── alt/                               # Эталонные архивы ALT
│   ├── c10f2/
│   │   ├── fstab
│   │   └── root.tgz
│   ├── c10f2-virt/
│   │   ├── fstab
│   │   └── root.tgz
│   └── c9f2/
│       ├── fstab
│       └── root.tgz
├── redos/                             # Эталонные архивы RedOS
│   ├── fstab_origin
│   ├── redos73c-5-15/
│   │   ├── fstab
│   │   ├── root.tgz
│   │   ├── storcli64                  # опционально, кладётся в /root и потом в /opt
│   │   └── storcli2                   # опционально, дополнительный бинарник storcli
│   └── redos73c-5-15-libvirt/
│       ├── fstab
│       ├── root.tgz
│       ├── storcli64
│       └── storcli2
├── auto_install.sh                    # Точка входа на LiveCD
├── deploy.sh                          # Сборка бандла deploy.bundle.tar.gz
├── make_archive.sh                    # Снятие архива root.tgz на эталоне
├── README.md
└── deploy/                            # Каталог бандла + конфиг установки
    ├── install.env                    # ЕДИНСТВЕННЫЙ изменяемый конфиг
    ├── deploy.bundle.tar.gz           # Готовый бандл установщика
    └── deploy/                        # Содержимое бандла
        ├── runner.sh
        ├── lib/
        │   ├── disk.sh
        │   ├── efi.sh
        │   ├── fs.sh
        │   ├── log.sh
        │   └── wipe.sh
        ├── os/
        │   ├── alt/80_chroot.sh       # CHROOT‑этап ALT Linux
        │   └── redos/80_chroot.sh     # CHROOT‑этап RedOS
        └── steps/                     # Последовательные шаги 00..70
            ├── 00_env.sh
            ├── 05_cleanup_mounts.sh
            ├── 10_global_wipe.sh
            ├── 20_pick_disks.sh
            ├── 30_partition_system.sh
            ├── 45_neutralize_esps.sh
            ├── 50_varlog_prepare.sh
            ├── 60_copy_payload.sh
            └── 70_personalize.sh
```

> **Важно:** структура внутри `alt/` и `redos/` — пример. Конкретный подкаталог с `root.tgz`/`fstab` (и, при необходимости, `storcli*`) вы указываете в `install.env` через переменную `backup_dir`.

---

## 1) Снятие архива с эталонной системы

**Цель:** получить `root.tgz` (корень + `/boot`) для дальнейшего развёртывания.

1. На **эталонной системе** (любой поддерживаемой ОС) запустите:

   ```bash
   sudo /backup/make_archive.sh
   ```

   Скрипт создаст, как минимум:

   - `/mnt/recovery/root.tgz` — полный архив ОС.

2. Подготовьте файл **`fstab`**, который подходит под **будущую** разметку (см. §4 и §9), и положите его рядом с архивом в соответствующий каталог на сервере бэкапов, например:

   ```text
   /backup/alt/c10f2/{root.tgz,fstab}
   /backup/redos/redos73c-5-15/{root.tgz,fstab,storcli64,storcli2}
   ```

**Примечания:**

- Архив исключает `/home/*`, `/mnt/*`, `lost+found` и сам каталог назначения.
- При желании можно проверить содержимое:

  ```bash
  tar -tzf /mnt/recovery/root.tgz | head
  tar -tzf /mnt/recovery/root.tgz | grep '^boot/' | head
  ```

---

## 2) Организация хранилища бэкапов

На сервере бэкапов хранится **несколько эталонов** (разные ОС/роли). Примеры:

```text
/backup/alt/c10f2/                   # ALT для железа
/backup/alt/c10f2-virt/              # ALT с виртуализацией
/backup/redos/redos73c-5-15/         # RedOS для обычного сервера
/backup/redos/redos73c-5-15-libvirt/ # RedOS с libvirt
```

В `install.env` вы указываете **любой** такой путь:

```bash
backup_dir="/backup/alt/c10f2"
# или
#backup_dir="/backup/redos/redos73c-5-15"
```

`auto_install.sh` берёт `backup_dir` из `install.env` и передаёт его шагам — откуда те уже забирают `root.tgz` и `fstab` (а для RedOS ещё и `storcli*`, если есть).

> **Координаты** самого хранилища (IP, логин, пароль и базовый путь `/backup/deploy`) зашиты **только** в `auto_install.sh`. Логику там не меняем, при необходимости правим только `SERVER_IP/SERVER_USER/SERVER_PASS/REMOTE_BASE`.

---

## 3) Сборка бандла установщика

На сервере (где находится каталог `/backup/deploy`) выполните:

```bash
sudo /backup/deploy.sh
```

Скрипт сделает:

- переход в `/backup/deploy`;
- упаковку подкаталога `deploy/` в архив:

  ```bash
  /backup/deploy/deploy.bundle.tar.gz
  ```

Внутри архива верхним уровнем окажется каталог `deploy/` с `runner.sh`, `lib/`, `steps/`, `os/`.

> `install.env` лежит **рядом** с бандлом (`/backup/deploy/install.env`) и в архив **не** попадает — это отдельный конфиг, который можно менять без пересборки бандла.

---

## 4) Настройка `install.env` (единственный изменяемый конфиг)

Файл:

```text
/backup/deploy/install.env
```

редактируется **под каждую установку**.

Ключевые группы переменных (по текущей версии шагов):

### 4.1. Что ставим и откуда берём бэкап

```bash
# ОС, для которой есть os/${OS}/80_chroot.sh
OS=alt        # или redos

# Абсолютный путь к каталогу с root.tgz и fstab на сервере бэкапов:
backup_dir="/backup/alt/c10f2"
#backup_dir="/backup/redos/redos73c-5-15"
```

> `OS` только выбирает chroot‑скрипт (`os/<OS>/80_chroot.sh`).  
> Тип файловой системы корня теперь задаётся **отдельно** (см. ниже `root_fs`) и не «зашит» за конкретной ОС.

### 4.2. Выбор системных дисков и базовая разметка

```bash
# Диапазон размеров (GiB), по которому ищем диски под систему
min_size_gb=150
max_size_gb=350

# Размеры разделов (MiB)
esp_mb=200          # EFI System Partition (FAT32)
boot_mb=1024        # /boot (ext4, вне LVM)
swap_mb=4096        # swap (внутри LVM)
vg_name="alt"       # имя Volume Group (пример)
```

Шаги:

- находят 1–2 диска в указанном диапазоне;
- при двух дисках собирают RAID1 для `/boot` и LVM‑данных, ESP остаются отдельными на каждом диске;
- при одном диске создают GPT: ESP + `/boot` + раздел под LVM.

### 4.3. LVM‑схема и отдельный `/var`

```bash
# Если var_mb > 0 → новая схема: /var берёт 100%FREE, / получает root_mb.
# Если var_mb = 0 → старая схема: / получает 100%FREE, /var отдельным LV не создаётся.
var_mb=0

root_mb=20480       # используется только если var_mb > 0
tmp_mb=0
vartmp_mb=0
home_mb=0
varlog_lv_mb=0      # LV под /var/log, если НЕ используется отдельный диск
```

### 4.4. Типы файловых систем

```bash
# Доступные типы: xfs, ext4
root_fs=ext4
var_fs=ext4
tmp_fs=ext4
vartmp_fs=ext4
home_fs=ext4
varlog_lv_fs=ext4

# Флаги совместимости XFS (для старых ядер можно включить crc=0,finobt=0)
xfs_compat_flags=""
```

Обычно:

- для RedOS разумно ставить `root_fs=xfs`,
- для ALT — `root_fs=ext4`,

но это уже полностью настраивается здесь, а не «зашито по ОС».

### 4.5. Отдельный диск под `/var/log` (опционально)

```bash
use_varlog_disk=false
varlog_min_gb=15
varlog_max_gb=50
varlog_label="VARLOG"
```

Если `use_varlog_disk=true`, шаги ищут **отдельный диск** в указанном диапазоне размеров и используют его под `/var/log` (создаётся ФС с меткой `VARLOG`).  
При этом:

- LV под `/var/log` (`varlog_lv_mb`) **не** создаётся;
- в `fstab` должна быть строка вида `LABEL=VARLOG /var/log ...` (см. §9).

Если `use_varlog_disk=false` и `varlog_lv_mb>0`, `/var/log` создаётся как отдельный LV внутри `vg_name`.

### 4.6. Логи, метаданные, сеть

```bash
early_log="/tmp/deploy.log"              # лог на LiveCD
target_log="/mnt/target/root/deploy.log" # лог в целевой системе
meta_hostname="deploy"                   # временный hostname для установки

# Сетевые настройки, которые используются в chroot (RedOS)
net_cidr="192.168.7.0/24"
net_iface="eno3"
```

Переменные `net_cidr` и `net_iface` подставляются в `os/redos/80_chroot.sh`  
для генерации вспомогательного скрипта `/root/set-ip.sh`.

---

## 5) Запуск развёртывания на целевой машине (LiveCD)

1. Загрузитесь с LiveCD и убедитесь, что машина видит **сервер бэкапов** по сети.
2. Скопируйте на LiveCD скрипт `auto_install.sh` (например, заранее положив `/backup` на флешку или по сети).
3. На LiveCD выполните:

   ```bash
   bash /backup/auto_install.sh
   ```

`auto_install.sh`:

1. скачивает `/backup/deploy/install.env` с сервера (`scp` через `sshpass`);
2. подгружает его (`source`) и экспортирует переменные в окружение (в т.ч. `OS`, `backup_dir`);
3. выставляет `backup_ip` и `backup_passwd` для шагов;
4. скачивает `/backup/deploy/deploy.bundle.tar.gz` и распаковывает его в `/root/deploy`;
5. выполняет `/root/deploy/runner.sh`.

---

## 6) Что делает `runner.sh` (последовательность шагов)

Шаги исполняются **последовательно** (сурсингом), все переменные из `install.env` уже есть в окружении:

1. **00_env.sh** — базовая инициализация, временный `hostname` (из `meta_hostname`), настройка раннего логирования.
2. **05_cleanup_mounts.sh** — аккуратно снимает остаточные монтирования, останавливает md/LVM/dm, если что‑то осталось с предыдущих попыток.
3. **10_global_wipe.sh** — глобальная зачистка сигнатур (`wipefs`, `mdadm --zero-superblock`, `sgdisk --zap-all` и т.п.). Повторный запуск безопасен, но разрушителен для данных.
4. **20_pick_disks.sh** — выбирает 1–2 системных диска по `min_size_gb..max_size_gb`. Параллельно подбирает диски‑кандидаты под `/var/log`, если `use_varlog_disk=true`.
5. **30_partition_system.sh** — создаёт GPT‑таблицы и разделы, собирает RAID/LVM, создаёт ФС согласно `root_fs`, `var_fs` и т.п.
6. **45_neutralize_esps.sh** — обезвреживает **чужие** ESP (кроме тех, что создали мы): переименовывает метки, чистит содержимое `EFI/*`, уменьшая шанс загрузки старой ОС.
7. **50_varlog_prepare.sh** (если включено) — вынос `/var/log` на отдельный диск: одиночный раздел или RAID1, создаёт ФС с меткой `varlog_label` и монтирует в `/mnt/target/var/log`.
8. **60_copy_payload.sh** — берёт `root.tgz` и `fstab` из `backup_dir`, распаковывает систему в `/mnt/target`, кладёт `fstab` на место, а также (если присутствуют) копирует `storcli64` и `storcli2` в `/mnt/target/root/` для последующей установки в chroot.
9. **70_personalize.sh** — генерирует новый `machine-id`, `random-seed`, при необходимости добавляет записи для LV (`/var`, `/tmp`, `/var/tmp`, `/home`, `/var/log`) в `fstab` целевой системы и переключает логирование в целевую ОС (в `target_log`).
10. **os/${OS}/80_chroot.sh** — специфический chroot‑этап для ALT или RedOS (см. §7). После него происходит диагностика, размонтирование и перезагрузка.

---

## 7) CHROOT‑этапы

### ALT (`os/alt/80_chroot.sh`)

Основные действия внутри целевой системы:

- монтирует необходимые псевдо‑ФС (`devpts`, `efivarfs`);
- удаляет все существующие EFI Boot#### записи (очистка NVRAM);
- устанавливает GRUB в `/boot/efi` (и при наличии в `/boot/efi2`) в режимах `--bootloader-id=ALT` и `--removable`;
- создаёт явные EFI‑записи ALT для всех обнаруженных ESP (A/B‑схема);
- формирует `mdadm.conf`, собирает initrd (`make-initrd`) для всех ядер с поддержкой RAID/LVM;
- пересобирает конфигурацию GRUB (`update-grub`);
- при наличии LV `/tmp` создаёт unit‑файл `tmp.mount` и включает его, чтобы `/tmp` монтировался с заданными опциями как файловая система на LVM;
- при наличии `integalert` выполняет `integalert fix` (ALT‑специфика);
- выполняет «санитарную» очистку логов, истории и SSH‑ключей, затем выходит из chroot.

В результате:

- EFI‑загрузка ALT развёрнута на все ESP;
- initrd знает о RAID/LVM‑конфигурации;
- `/tmp` (при наличии соответствующего LV) монтируется как отдельная ФС.

### RedOS (`os/redos/80_chroot.sh`)

Основные действия внутри целевой системы:

- монтирует `devpts` и `efivarfs`, очищает все EFI Boot#### записи (NVRAM);
- фиксирует текущую конфигурацию md‑RAID (`mdadm.conf`);
- нормализует `GRUB_CMDLINE_LINUX` (`/etc/default/grub`) и BLS‑записи (`/boot/loader/entries`):
  - прописывает `root=UUID=<ROOT_UUID>`,
  - при необходимости добавляет `rd.auto=1`,
  - синхронизирует `MachineID` в именах файлов и в полях `MachineID=/machineid=`;
- пересобирает `initramfs` (`dracut`) для всех ядер:
  - основная попытка пишет во временный файл в `/tmp` с явным добавлением модулей `mdraid`/`lvm` и драйвера `raid1`,
  - при проблемах включается упрощённый fallback‑режим;
- генерирует `/boot/grub2/grub.cfg` (`grub2-mkconfig`/`grub-mkconfig`);
- для **каждой** обнаруженной ESP:
  - монтирует раздел,
  - выкладывает пары `shimx64.efi`/`grubx64.efi` (если есть) или собирает standalone‑загрузчик `BOOTX64.EFI`,
  - при наличии копирует `grub.cfg` в вендорский каталог,
  - создаёт соответствующую EFI Boot#### запись (`RedOS`) через `efibootmgr`;
- приводит rescue‑артефакты к текущему `MachineID` (переименование `vmlinuz-0-rescue-*`, `initramfs-0-rescue-*.img` и соответствующих BLS‑записей, повторная генерация `grub.cfg`);
- устанавливает `storcli`:
  - если в архиве были `storcli64`/`storcli2`, шаг 60 кладёт их в `/root/`,
  - chroot‑скрипт переносит их в `/opt/MegaRAID/storcli/` и `/opt/MegaRAID/storcli2/` с корректными правами;
- генерирует вспомогательный скрипт `/root/set-ip.sh`, который:
  - берёт `NET_CIDR` и `NET_IFACE` из `install.env`,
  - по последнему октету (`set-ip.sh <N>`) создаёт статический профиль `nmcli` и поднимает сеть;
- выполняет «санитарную» очистку логов, истории и SSH‑ключей, затем выходит из chroot.

---

## 8) Требования к окружению (LiveCD и chroot)

Желательно наличие:

- `sshpass`, `scp`, `tar`, `gzip`/`pigz`;
- `mdadm`, `lvm2`, `sgdisk`/`gdisk`, `parted`, `dosfstools` (`mkfs.fat`), `e2fsprogs`, `xfsprogs`;
- `efibootmgr`, утилит GRUB (`grub2-mkconfig`, `grub-mkstandalone` и т.п.);
- `dracut` (для RedOS) или `make-initrd` (для ALT);
- возможность монтировать `efivarfs` (UEFI‑режим);
- сеть до сервера бэкапов (`SERVER_IP`, `REMOTE_BASE` из `auto_install.sh`).

---

## 9) Требования к вашему `fstab` (в каталоге `backup_dir`)

Минимально должны быть строки, соответствующие разметке, которую создадут шаги.

Примеры:

**Корень (`/`)** — тип зависит от `root_fs`:

```text
/dev/mapper/<vg>-root   /         xfs   noatime                             0 1
# или
/dev/mapper/<vg>-root   /         ext4  noatime                             0 1
```

**`/boot`** — ext4 (обычно RAID1 `/dev/md0` при двух дисках):

```text
/dev/md0                /boot     ext4  noatime                             0 2
```

**ESP** (можно добавить для наглядности, хотя chroot‑этап и так работает с ESP напрямую):

```text
LABEL=ESP               /boot/efi  vfat  umask=0077,quiet                   0 2
# вторую ESP можно не прописывать (используется только для дубля загрузчика)
```

**swap**:

```text
/dev/mapper/<vg>-swap   swap      swap  defaults                           0 0
```

**Отдельный `/var/log`**:

- при `use_varlog_disk=true`:

  ```text
  LABEL=VARLOG          /var/log  ext4  noatime,nodev,nosuid,noexec        0 2
  ```

- при `use_varlog_disk=false` и `varlog_lv_mb>0`:

  ```text
  /dev/mapper/<vg>-varlog /var/log ext4  noatime,nodev,nosuid,noexec       0 0
  ```

Рекомендуется по возможности использовать `LABEL=`/`UUID=` — устойчивее к смене имён устройств.

---

## 10) Логи и где их смотреть

- Ранний лог (LiveCD):  
  `/tmp/deploy.log` — ведётся `auto_install.sh`.
- Основной лог в целевой ОС:  
  `/root/deploy.log` — пишет `runner.sh` и шаги.
- CHROOT‑лог:  
  `/var/log/deploy-chroot.log` (для ALT и RedOS).

Часто в конце chroot‑этапа дополнительно выводятся:

- `efibootmgr -v`
- `lsblk -fp`
- `mdadm --detail`
- `vgdisplay`, `lvdisplay`

---

## 11) TL;DR — быстрый сценарий

1. На эталонной системе:

   ```bash
   sudo /backup/make_archive.sh
   ```

   Скопируйте `root.tgz` и подготовленный `fstab` в нужный каталог на сервере, например:

   ```text
   /backup/alt/c10f2/
   ```

2. На сервере бандла:

   - Отредактируйте `/backup/deploy/install.env`:
     - `OS=alt` или `OS=redos`;
     - `backup_dir="/backup/alt/c10f2"` (или другой);
     - диапазоны дисков, LVM‑схему, типы ФС при необходимости;
     - флаги `use_varlog_disk`, `var_mb` и размеры LV.
   - Соберите бандл:

     ```bash
     sudo /backup/deploy.sh
     ```

3. На целевой машине (LiveCD + сеть до сервера):

   ```bash
   bash /backup/auto_install.sh
   ```

   Далее шаги отработают автоматически → перезагрузка.

---

## 12) Частые вопросы и диагностика

- **«Не нашлись диски под систему».**  
  Проверьте `min_size_gb..max_size_gb` в `install.env` и реальные размеры:

  ```bash
  lsblk -dn -o NAME,SIZE,TYPE
  ```

- **«/var/log не вынесся».**  
  Убедитесь, что:
  - `use_varlog_disk=true`, если ожидаете отдельный диск;
  - либо `use_varlog_disk=false` и `varlog_lv_mb>0`, если ждёте LV под `/var/log`;
  - диапазон `varlog_min_gb..varlog_max_gb` покрывает нужный диск (для отдельного диска);
  - `fstab` содержит корректную строку для `/var/log`.

- **«UEFI‑загрузки не создаются».**  
  Проверьте, что система загружена в режиме UEFI и доступен `efivars`:

  ```bash
  mount | grep efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  ```

- **«Система после развёртывания не грузится / rescue не работает».**  
  Проверьте `deploy.log`, `deploy-chroot.log`, вывод `efibootmgr -v` и корректность `root=`/`UUID` в `grub.cfg` и BLS‑записях.

- **«Архив создаётся слишком медленно».**  
  Установите `pigz` — `make_archive.sh` использует его автоматически вместо `gzip`.

- **«Не поднимается сеть после развёртывания RedOS».**  
  Используйте сгенерированный скрипт `/root/set-ip.sh`:

  ```bash
  cd /root
  ./set-ip.sh 42   # задаст IP ...42 из подсети NET_CIDR на интерфейсе NET_IFACE
  ```

---

## 13) Безопасность и предостережения

- Шаги **05/10/30/50** выполняют разрушительные операции (очистка сигнатур, обнуление superblock, `wipefs`, `sgdisk --zap-all` и возможный `dd` по началу/концу дисков). Используйте только на целевых дисках.
- `auto_install.sh` использует `sshpass` + `scp` с отключённой проверкой `known_hosts`. Для закрытых инфраструктур это удобно; в открытых сетях учитывайте риски MITM.
- `backup_dir` может указывать на **любой** каталог с `root.tgz`/`fstab` (и, опционально, `storcli*`) — внимательно проверяйте путь перед запуском.
- Перед запуском убедитесь, что LiveCD действительно загружен на **той** машине, диски которой вы готовы полностью стереть.

---

## 14) Чек‑лист перед запуском

- [ ] Готов `root.tgz` с нужной системой.
- [ ] Готов и проверен `fstab`, соответствующий разметке из `install.env`.
- [ ] В `install.env` выставлены:
  - `OS`,
  - `backup_dir`,
  - диапазоны дисков (`min_size_gb/max_size_gb`),
  - `vg_name` и LVM‑схема (`var_mb`, `root_mb`, дополнительные LV),
  - опции `/var` и `/var/log` (если нужны),
  - сетевые переменные (`net_cidr`, `net_iface`) для RedOS.
- [ ] На сервере собран свежий `deploy.bundle.tar.gz`.
- [ ] Целевая машина загружена в UEFI‑режиме (если планируется UEFI).
- [ ] Есть сеть до сервера бэкапов.

---

## 15) Пост‑проверки после ребута

На целевой системе:

```bash
lsblk -fp
cat /etc/fstab
efibootmgr -v
head -n 20 /boot/grub2/grub.cfg 2>/dev/null || head -n 20 /boot/grub/grub.cfg
blkid
cat /etc/machine-id
```

Убедитесь, что:

- корень примонтирован с ожидаемым типом ФС (`root_fs`);
- `/boot` — ext4 (RAID1 `/dev/md0`, если два диска);
- EFI‑записи присутствуют и указывают на нужные ESP;
- в `grub.cfg` корректные `UUID` и список ядер;
- при выносе `/var/log` он смонтирован либо по `LABEL=VARLOG`, либо с ожидаемым LV;
- SSH‑ключи на целевой системе сгенерированы заново (нет утечки ключей с эталона).

