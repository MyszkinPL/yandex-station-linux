# What the Station stands on

The rule: nothing the Station does every day may hang on one thin piece that
can disappear without us noticing — a file in a temp folder, a partition of
someone else's system, one public server. Each such piece is listed here with
what happens when it goes, and what replaces it.

## Holding the whole system

| Piece | If it goes | Plan |
|---|---|---|
| **Debian userspace in Android's `/data`** (`/data/local/debian`, read-only lower layer): wpa_supplicant, dropbear, bluez, chrony, alsa-utils, perl | Android factory reset or Android touching `/data` — no network, no services; the watchdog takes the Station back to Android | Our own root filesystem on a partition we own, built reproducibly (CI), Debian packages chosen and pinned; `/data` read only for migration |
| **Boot only through Android**: U-Boot boots Yandex Android by default; ours comes up through the one-shot recovery flag (set from Android) | After a power cut the Station is back in Yandex Android, not in our system | Decide how ours becomes the default boot without touching boot0/U-Boot/env (rule): candidates — the `boot` partition (needs an explicit yes), or a hand-off from Android at its boot |
| **Wi-Fi networks from Android's `wpa_supplicant.conf`** | a new router password with Android gone | done: networks added in the panel live in `/opt/station/etc/wifi.conf` and come first |
| **Recovery images packed by hand** from local files | a lost workstation means no way to rebuild the image that boots | everything public built in CI; the private part (Wi-Fi firmware, SSH key, TAS scripts) packed by one script from `private/`; images kept out of temp folders (done: `private/images`) |
| **The SSH key and the tools in a temp folder** | a cleanup of the temp folder locks us out of our own system | done: `private/tools`; a copy must also live outside this computer |

## Features that use the outside world (must degrade, never break the rest)

| Piece | Used for | When it is gone |
|---|---|---|
| one Piped instance | music search | search fails with a message; add more instances and try them in turn |
| iTunes Search | covers of Bluetooth tracks | no cover, placeholder; the Station fetches and serves covers itself, the panel needs nothing outside |
| GitHub releases | self-update | update says it cannot reach it; the installed version keeps running, rollback is local |
| NTP pools | time | the RTC keeps time (synced by the kernel while NTP worked) |
| yt-dlp, YouTube | YouTube playback | blocked in Russia; search works, playback says why |

## Glue that can rot

Services read other programs' text output (`bluetoothctl`, `busctl`, `wpa_cli`,
`iw`, `amixer`). It holds while Debian is pinned (read-only lower layer), and
breaks silently on an upgrade. Plan: talk to the interfaces themselves —
D-Bus for BlueZ and wpa_supplicant, ALSA controls through the kernel API —
service by service, with tests like the ring's (`ringd/src/rules.rs`).
