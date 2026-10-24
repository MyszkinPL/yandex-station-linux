# Linux 6.18 for the Yandex Station 1

> Свежее ядро Linux для первой Яндекс Станции. Цель: родной Android с Алисой поверх него без изменений
> (в работе) или своя система (уже работает: Wi-Fi, звук, кольцо, кнопки). Стоковая прошивка остаётся на месте, образ ставится в слот recovery.

Mainline Linux on the first-generation Yandex Station (YNDX-0001, Allwinner A64),
in place of the vendor 3.10 kernel. Two ways to use it:

- **Linux mode**: our own userspace (busybox initramfs, then Debian from the
  Station's eMMC), with Wi-Fi, sound, the LED ring and the keys;
- **Android mode**: the Station's own Android 6 / Quasar on this kernel,
  unmodified (`android/`), for people who want to keep the stock assistant.

It boots from the recovery slot and leaves boot0, U-Boot, the vendor kernel and
Android where they are, so the Station always falls back to the stock firmware.

## Status

| | |
|---|---|
| CPU, 4 cores, DVFS through the vendor SCP firmware | works |
| eMMC, Wi-Fi (AP6356S, brcmfmac) | works |
| Speakers (2× TAS5751M), mic array (5× TLV320ADC3101) | works, vendor sound quality |
| LED ring, keys, RTC, thermal | works |
| HDMI console | works |
| Bluetooth | in progress |
| Android 6 on this kernel | init and services start; needs the GPU (Mali-400, in progress) for SurfaceFlinger |

## Layout

```
kernel/VERSION, linux.sha256   upstream stable release we build on
kernel/series, patches/        our patches, in order (git am / patch -p1)
kernel/station.config          kernel configuration
kernel/dts/                    the board's device tree (one source, DTB variants)
boot/                          boot shim and the image packer (pure Python)
initramfs/                     Linux-mode init
android/                       running the vendor Android on this kernel
scripts/                       build scripts used by CI
```

## Building

Every push builds in GitHub Actions (`.github/workflows/build.yml`): the
kernel, the DTBs, modules, the boot shim, and static busybox/kexec. The
artifacts are on the run's page. Locally, on Debian/Ubuntu:

```bash
sudo apt install gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev cpio kmod python3 ccache
scripts/build-kernel.sh
scripts/build-userspace.sh
```

### Packing a recovery image

The kernel has no built-in initramfs: the files that cannot be published
(your SSH key, the Wi-Fi firmware and the amplifier tuning from your own
Station) go into `private/`, which git ignores; see the top of
`initramfs/initramfs.list` for the list. Then, on any OS with Python 3:

```bash
python3 boot/pack.py --shim out/shim.bin --image out/Image --dtb out/dtb/station.dtb --initramfs initramfs/initramfs.list -D BUILD=out/userspace -D PRIVATE=private -o recovery.img
```

`pack.py` checks the memory layout against what the vendor U-Boot does
(see its header) and refuses images that would not boot.

## Licence

GPL-2.0, as the kernel (`COPYING`). `android/libion/` is Apache-2.0, as
Android's own libion. No vendor binaries are included.
