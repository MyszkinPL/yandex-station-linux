# Linux 6.18 для Яндекс Станции 1

Свежее ядро Linux (mainline 6.18) для первой Яндекс Станции (YNDX-0001, Allwinner A64)
вместо вендорского 3.10. Два режима:

- **Linux-режим**: своя система (initramfs на busybox, дальше Debian с eMMC Станции),
  с Wi-Fi, звуком, кольцом и кнопками;
- **Android-режим**: родной Android 6 / Алиса Станции поверх этого ядра, без изменений
  в самом Android (`android/`). В работе.

Образ ставится в слот recovery. boot0, U-Boot, вендорское ядро и Android остаются на месте,
так что Станция всегда может вернуться на стоковую прошивку.

## Что работает

| | |
|---|---|
| CPU, 4 ядра, DVFS через вендорскую прошивку SCP | работает |
| eMMC, Wi-Fi (AP6356S, brcmfmac) | работает |
| Динамики (2× TAS5751M), микрофоны (5× TLV320ADC3101) | работает, звук как у вендора |
| Кольцо, кнопки, RTC, датчики температуры | работает |
| Консоль на HDMI | работает |
| Bluetooth | в работе |
| Android 6 на этом ядре | init и службы стартуют; для SurfaceFlinger нужна GPU (Mali-400, в работе) |

## Что где

```
kernel/VERSION, linux.sha256   версия upstream stable, на которой собираем
kernel/series, patches/        наши патчи по порядку (patch -p1 / git am)
kernel/station.config          конфиг ядра
kernel/dts/                    device tree платы (один исходник, несколько вариантов DTB)
boot/                          загрузочный shim и упаковщик образа (чистый Python)
initramfs/                     init Linux-режима
android/                       запуск вендорского Android на этом ядре
scripts/                       скрипты сборки (их же запускает CI)
```

Описания патчей в `kernel/patches/` на английском: это формат ядра, иначе их не примут в mainline.

## Сборка

Каждый пуш собирается в GitHub Actions (`.github/workflows/build.yml`): ядро, DTB, модули,
shim, статические busybox и kexec. Готовые файлы лежат на странице запуска (Artifacts).
Локально, на Debian/Ubuntu:

```bash
sudo apt install gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev cpio kmod python3 ccache wireless-regdb
scripts/build-kernel.sh
scripts/build-userspace.sh
```

### Сборка образа recovery

В ядре нет встроенного initramfs: то, что нельзя публиковать (свой SSH-ключ, прошивка Wi-Fi
и настройки усилителей со своей же Станции), лежит в `private/`, которую git игнорирует.
Список файлов в начале `initramfs/initramfs.list`. Дальше на любой ОС с Python 3:

```bash
python3 boot/pack.py --shim out/shim.bin --image out/Image --dtb out/dtb/station.dtb --initramfs initramfs/initramfs.list -D BUILD=out/userspace -D PRIVATE=private -o recovery.img
```

`pack.py` сверяет раскладку памяти с тем, что делает вендорский U-Boot (см. начало файла),
и не соберёт образ, который не загрузится.

## Лицензия

GPL-2.0, как у ядра (`COPYING`). `android/libion/` под Apache-2.0, как libion самого Android.
Вендорских бинарников в репозитории нет.
