# What the Station stands on

The rule: nothing the Station does every day may hang on one thin piece that
can disappear without us noticing — a file in a temp folder, a partition of
someone else's system, one public server. Each such piece is listed here with
what happens when it goes, and what replaces it.

## Holding the whole system

| Piece | If it goes | Plan |
|---|---|---|
| ~~Debian userspace in Android's `/data`~~ | — | **done (2026-10-25):** our root filesystem, built by CI from `rootfs/packages` (mmdebstrap), installed with `update rootfs-install` into `/cache/station/rootfs`, read-only with a RAM layer; state explicit in `/cache/station/persist`; a new one is tried once and put aside if the network does not come up. Left: `/cache` is still Android's partition (a factory reset wipes it) — it moves to `system` together with the boot question below; Debian in `/data` stays only as the fallback |
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

## Crutches found (review of 2026-10-25)

Places where a symptom is hidden instead of the cause fixed, grouped by the
cause. Fixed in this order; each one struck out here when done.

1. **Two owners of one thing.** The panel's scene preview sends real ringd
   commands (`alert off` silences a ringing alarm, `bt pairing` opens a real
   pairing window, `timer off` hides a running timer); an alarm's `alert on`
   is sent once and lost if ringd is restarting; "timer done" is decided both
   by ringd's countdown and by timerd; the volume is counted by ringd (from 50
   after a restart) and kept by audiod; the pairing window lives in stationd
   but is read back from ringd's status. Fix: one owner each — timerd owns
   ringing and re-asserts it, audiod owns the volume (ringd sends relative
   turns), stationd owns pairing, ringd only shows; previews are a ringd
   overlay that expires by itself and touches nothing.
   **Done:** the rules are written down in `os/bus` (one owner; an owner
   says again what it owns on every reconnect; snapshot first, then
   events). timerd keeps the ringing in its state file and tells ringd until
   it has taken it; audiod follows timerd for the bell, ringd for `dial ±n`;
   stationd has its own socket for the pairing window; ringd's `preview`;
   the panel names the scene ringd reports. Checked on the Station: a
   preview and a ringd restart while a timer rings leave it ringing.
2. **Losing the network resets the Station into Android.** The health loop in
   init stops the watchdog after 60 s without Wi-Fi; DHCP runs once (`-q`, no
   renewal); `wpa_supplicant` is restarted with `killall; sleep 0.3`; the
   sound setup and its hand-over mark run only if DHCP succeeded; the
   `wpa_supplicant` debug log grows in RAM. Fix: the network is a supervised
   service (supplicant, udhcpc kept running, dropbear), the ring shows
   `offline`, sound comes up on its own; the watchdog resets only if init or
   the core services are stuck. **Done (E15):** init keeps the base —
   dropbear and wpa_supplicant started again if gone, udhcpc runs for good
   (renews, and asks again on every reconnection through wpa_cli's action),
   the channel hint is dropped after the boot, the supplicant's debug log
   only while it connects; the ring shows "offline" after 30 s, and init
   never resets for the network. Sound comes up before Wi-Fi. Checked: a
   disconnect showed "offline" and came back by itself after 2 min; a killed
   wpa_supplicant was back in 10 s.
3. **A stalled subscriber freezes the ring.** ringd (and timerd, playerd)
   write to every subscriber with a blocking write while holding the state
   lock; a suspended phone tab behind webd's event relay can stop the LEDs and
   the buttons. Fix: per-subscriber queues, sends outside the lock, a slow
   subscriber is dropped. **Done:** `bus::Hub` (each subscriber its own
   queue and writer; full queue — dropped), in ringd, timerd and playerd;
   webd's event relay has a write timeout.
4. **Supervision by sleeps.** `start` restarts after a fixed 2 s with no
   backoff or crash count; `bluetooth` starts its daemons with `pgrep || … &
   sleep 1` and never restarts them; `clock` kills an orphaned chronyd and
   sleeps; ringd's button threads return on an error and stay dead while the
   process lives; updates restart by `pkill`; webd's own service list misses
   audiod. Fix: every daemon its own supervised entry (exec, no orphans),
   ordered by waiting for what it needs (D-Bus names), backoff and a visible
   crash count, one restart routine, the list read from `start`.
5. **The fallback is the old system.** A failed new root filesystem falls
   back to Debian in `/data` without the persist binds (old timers, Wi-Fi,
   volume), while `rootfs.old` is kept and never used; the rootfs is accepted
   on network + SSH alone; it is built from the live Debian mirror, not
   pinned; an unreadable `timers.json` is silently replaced. Fix: fall back to
   `rootfs.old` with the same binds; accept on the core services; build from a
   fixed snapshot; keep a broken state file aside. **Done:** only a new root
   filesystem is on trial (rootfs.try from `update rootfs-install`, one boot),
   accepted when the core services run without restarting, else back to
   `rootfs.old`; a broken timers.json is kept as `.broken`. Left: the pinned
   build.
6. **Time.** The zone is applied in four places with four copies of the
   default; alarms are scheduled once and ignore a zone change or a clock step
   (all ring at once after chrony steps a late clock). Fix: one zone helper;
   reschedule on a zone change and on a clock step (`TFD_TIMER_CANCEL_ON_SET`),
   skip alarms long overdue.
7. **Text glue** (see above), with one live bug: SSIDs with non-ASCII
   characters come out of `wpa_cli` escaped, so they can't be added or
   forgotten. Status lines are matched with `contains` in five places; the
   panel picks music error banners by regex on yt-dlp's English text. Fix:
   D-Bus for wpa_supplicant and BlueZ, JSON status everywhere, error kinds
   from playerd.
8. **The panel.** Fetch errors shown as normal values ("будильника нет" when
   timerd is down); ring state patched by events and overwritten by a 5 s poll
   (events miss direction and timeouts, no snapshot on subscribe); ringd's
   scene priority copied twice (the copies disagree); the ring's timer counted
   down on the browser's clock; stale poll responses overwrite newer state;
   update has no follow-through; device lists hardcoded (log sources already
   out of date). Fix: snapshot-then-events from the device, the scene name
   from ringd, per-source error states, one poll helper.
