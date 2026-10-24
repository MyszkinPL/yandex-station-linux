# Android-режим

Родной Android 6 / Алиса Станции поверх нашего ядра. Сам Android не меняется: ядро
запускается через kexec из Linux-режима, а все отличия собраны в ramdisk и в библиотеках,
которые подменяются bind-монтированием поверх `/system` (на eMMC ничего не пишется).

```
ramdisk/mkramdisk.py              ramdisk из boot.img Станции плюс наши файлы
ramdisk/station-init.sh           первый процесс: зеркало журнала ядра в misc, затем /init
ramdisk/station-android.sh        служба вместо вендорского watchdogd: watchdog, дедлайн, логи
ramdisk/station-android-kexec.sh  запуск из Linux-режима, командная строка как у U-Boot
libion/libion.c                   libion поверх DMA-BUF heaps вместо вендорского ION
hwcomposer/hwcomposer.c           HWC 1.1 поверх DRM/KMS вместо hwcomposer.tulip
```

## Что отличается от вендорского ядра и как это закрыто

| Вендорское ядро 3.10 | Здесь |
|---|---|
| binder как misc-устройство | binderfs, `/dev/binder` — ссылка |
| ashmem | перенос ashmem (патч ядра 0013) |
| SELinux-политика v30 в раскладке Android 6 | ядро читает её (патч 0022) |
| Mali r6p0 (API 800) | ARM r10p0 с интерфейсом r6p0 (`gpu/mali`, патч 0101) |
| ION | DMA-BUF heaps + `libion/`; буферы вывода — из CMA-кучи (`cma=128M`) |
| дисплейный драйвер Allwinner (`/dev/disp`), hwcomposer.tulip | DRM/KMS + `hwcomposer/` (PRIME, page flip, vsync) |
| дисплей есть всегда | HDMI включается принудительно (`video=...@60e`) |
| старый sync-драйвер (`SYNC_IOC_WAIT`, старые MERGE/FENCE_INFO; их зовут libsync и libGLES_mali) | эти ioctl рядом с `sync_file` (патч 0026, `CONFIG_SYNC_FILE_ANDROID6`) |
| 32-битные системные вызовы со старым `time_t` (futex у 32-битного ART) | `CONFIG_COMPAT_32BIT_TIME` |
| ueventd кладёт кучи в `/dev/<имя>` | `subsystem dma_heap` в ueventd.rc → `/dev/dma_heap/*` |
| `install-recovery.sh` возвращает стоковый recovery | служба `flash_recovery` выключена: в recovery живёт mainline |
| серийный номер от U-Boot | вычисляется из eFuse SID так же, как в U-Boot |

## Сборка и запуск

```bash
python3 android/ramdisk/mkramdisk.py --boot-img boot.img --busybox out/userspace/busybox --mali out/mali.ko --libion64 out/android/lib64/libion.so --libion32 out/android/lib/libion.so --hwcomposer out/android/lib64/hw/hwcomposer.drm.so -o android-ramdisk.cpio.gz
```

`boot.img` — вендорский, с самой Станции или из её OTA. На Станции в Linux-режиме:

```bash
station-android-kexec Image station-android.dtb android-ramdisk.cpio.gz
```

С `STATION_DEBUG=1` init Android работает в своём PID-пространстве (его перезагрузка не
сбрасывает Станцию), logcat дублируется в журнал ядра, а журнал сохраняется в misc
(14 МБ от начала раздела) и читается после возврата в стоковый Android.

Для пробного запуска можно добавить аргументы ядра через `STATION_CMDLINE`, например
`initcall_blacklist=tas571x_i2c_driver_init` — без динамиков.

Статус: init и службы стартуют; SurfaceFlinger работает на Mali-400 через наш hwcomposer,
буферы gralloc выделяются из CMA; работа над запуском Java-части (zygote) идёт.
