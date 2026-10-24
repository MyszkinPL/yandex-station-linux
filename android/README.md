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
```

## Что отличается от вендорского ядра и как это закрыто

| Вендорское ядро 3.10 | Здесь |
|---|---|
| binder как misc-устройство | binderfs, `/dev/binder` — ссылка |
| ashmem | перенос ashmem (патч ядра 0013) |
| SELinux-политика v30 в раскладке Android 6 | ядро читает её (патч 0022) |
| Mali r6p0 (API 800) | ARM r10p0 с интерфейсом r6p0 (`gpu/mali`, патч 0101) |
| ION | DMA-BUF heaps + `libion/` |
| дисплейный драйвер Allwinner (`/dev/disp`), hwcomposer.tulip | DRM; hwcomposer скрыт, SurfaceFlinger работает через framebuffer HAL на `/dev/fb0` |
| fb0 есть всегда | `CONFIG_FB_DEVICE`, HDMI включается принудительно (`video=...@60e`) |
| серийный номер от U-Boot | вычисляется из eFuse SID так же, как в U-Boot |

## Сборка и запуск

```bash
python3 android/ramdisk/mkramdisk.py --boot-img boot.img --busybox out/userspace/busybox --mali out/mali.ko --libion64 out/android/lib64/libion.so --libion32 out/android/lib/libion.so -o android-ramdisk.cpio.gz
```

`boot.img` — вендорский, с самой Станции или из её OTA. На Станции в Linux-режиме:

```bash
station-android-kexec Image station-android.dtb android-ramdisk.cpio.gz
```

С `STATION_DEBUG=1` init Android работает в своём PID-пространстве (его перезагрузка не
сбрасывает Станцию), logcat дублируется в журнал ядра, а журнал сохраняется в misc
(14 МБ от начала раздела) и читается после возврата в стоковый Android.

Статус: init и службы стартуют, GPU-драйвер загружается; работа над SurfaceFlinger идёт.
