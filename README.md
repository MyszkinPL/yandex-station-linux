# Linux 7.3 для Яндекс Станции 1

Свежее ядро Linux (mainline 7.3) для первой Яндекс Станции (YNDX-0001, Allwinner A64)
вместо вендорского 3.10 — основа своей системы для Станции, без Android: initramfs на busybox,
дальше Debian с eMMC Станции, с Wi-Fi, Bluetooth, звуком, кольцом и кнопками.

Образ ставится в слот recovery. boot0, U-Boot и стоковая прошивка остаются на месте,
так что Станция всегда может вернуться на неё.

**Хотите просто Debian на Станции?** → [docs/INSTALL-DEBIAN.md](docs/INSTALL-DEBIAN.md):
один файл из [выпусков](https://github.com/MyszkinPL/yandex-station-linux/releases), запускается
в Android Станции, всё проверяет и ставит сам.

## Что работает

| | |
|---|---|
| CPU, 4 ядра, DVFS через вендорскую прошивку SCP | работает |
| eMMC, Wi-Fi (AP6356S, brcmfmac) | работает |
| Динамики (2× TAS5751M), микрофоны (5× TLV320ADC3101) | работает, звук как у вендора |
| Кольцо, кнопки, RTC, датчики температуры | работает |
| Консоль на HDMI | работает |
| Bluetooth (BCM4356, 1,5 Мбод) | работает |

## Что где

```
kernel/VERSION, linux.sha256   версия upstream stable, на которой собираем
kernel/series, patches/        наши патчи по порядку (patch -p1 / git am)
kernel/station.config          конфиг ядра
kernel/dts/                    device tree платы (один исходник, несколько вариантов DTB)
boot/                          загрузочный shim и упаковщик образа (чистый Python)
initramfs/                     init Linux-режима
os/                            своя система поверх ядра, на Rust (службы Станции)
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

В ядре нет встроенного initramfs: то, что нельзя публиковать (свой SSH-ключ, прошивки Wi-Fi и Bluetooth
и настройки усилителей со своей же Станции), лежит в `private/`, которую git игнорирует.
Список файлов в начале `initramfs/initramfs.list`. Дальше на любой ОС с Python 3:

```bash
python3 boot/pack.py --shim out/shim.bin --image out/Image --dtb out/dtb/station.dtb --initramfs initramfs/initramfs.list -D BUILD=out/userspace -D PRIVATE=private -o recovery.img
```

`pack.py` сверяет раскладку памяти с тем, что делает вендорский U-Boot (см. начало файла),
и не соберёт образ, который не загрузится.

## Лицензия

GPL-2.0, как у ядра (`COPYING`). Вендорских бинарников в репозитории нет.

Запуск родного Android 6 на этом ядре (Android-режим) свёрнут; последнее его состояние —
в теге `android-mode-2026-10-25`.
