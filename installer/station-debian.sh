# Debian on the Yandex Station 1: the installer. Runs on the Station, inside
# Yandex Android, as root, under our own busybox (station-debian.run carries
# it: scripts/pack-installer.sh). Every step is checked before and after; a
# failure stops it and says what to do, and running it again goes on from
# where it stopped. Its text is Russian; its log is /data/local/station/install.log.
# For apps that drive it: docs/INTEGRATION.md (--machine, exit codes).
#
#   sh station-debian.run [install|check|download|status|log|enter|stay|unstay|access|update|uninstall|version]
#     --key "ssh-ed25519 ..."   SSH key for root in Debian    --password   a root password instead
#     --wifi "<name>" "<pass>"  one more Wi-Fi network        --tz Europe/Moscow
#     --mode debian|android|direct   what the Station boots    --from DIR   files already downloaded
#     --yes                     no questions (defaults)       --machine    "@..." lines on stdout for apps
#
# Pinned by the packer: the release this installer belongs to.
VERSION=@VERSION@
URL=@URL@
IMG=@IMG@ IMG_SHA=@IMG_SHA@ IMG_SIZE=@IMG_SIZE@
BOOT_IMG=@BOOT_IMG@ BOOT_SHA=@BOOT_SHA@ BOOT_SIZE=@BOOT_SIZE@
ROOTFS=@ROOTFS@ ROOTFS_SHA=@ROOTFS_SHA@
# The bootloaders direct boot (--mode direct) was tried on: boot0 (sectors
# 16-79) and U-Boot (toc1's first item, sectors 32806-34789) of firmware
# 20261013. Direct boot leans on what they do (boota from boot, the PMIC
# flag into recovery), so it is offered only where they are these.
BOOT0_OK="6c064c4b6393f438fe2eca4d806962413d7a71c439a646cc4fb7962623c18b10"
UBOOT_OK="592a9b3656ab165221324b564288c4013cb70a25fbd56a83bf8d9bb22f1eabcd"

set -u
# Android's umask is 077: Debian's own users (_apt, _chrony) must see its files
umask 022
export PATH=/data/local/station/bin:/system/bin:/system/xbin
BB=${BB:-/data/local/station/bin/busybox}
S=/data/local/station            # ours in Android's /data
DL=$S/dl                         # downloads (/data has the room)
B=$S/backup                      # what was there before us
LOG=$S/install.log
C=/cache/station                 # Debian and what it keeps
LOG_SEEK=3072 LOG_BLOCKS=1024    # 4 KiB blocks: our log in the last 4 MiB of misc
PMIC=/sys/bus/platform/devices/axp81x_board/axp81x_reg
RC=/system/etc/rc.local
MAGIC=STATION-MAINLINE
NEED_CACHE_MB=400 NEED_DATA_MB=150
HOOK='( setsid /system/bin/sh /data/local/station/handoff.sh </dev/null >/dev/null 2>&1 & )'

# exit codes (docs/INTEGRATION.md)
E_FAIL=1 E_BLOCKED=2 E_NOT_STATION=3 E_NO_ROOT=4 E_NET=5 E_SPACE=6 E_WRITE=7 E_NOT_INSTALLED=8
E_CANCELLED=9 E_NO_DIRECT=10 E_USAGE=11

# --- output: people get text; with --machine, apps get "@..." lines on
# stdout and the text goes to stderr ---------------------------------------
MACHINE=""
for a in "$@"; do [ "$a" = --machine ] && MACHINE=yes; done
if [ -n "$MACHINE" ]; then exec 3>&1 1>&2; fi
m() { [ -n "$MACHINE" ] && echo "@$*" >&3; return 0; }
mkdir -p $S $DL
log() { echo "$(date '+%F %T') $*" >> $LOG; }
say() { echo "$*"; log "$*"; }
# colour on a terminal (green done, yellow note, red stop)
COLOR=""
[ -z "$MACHINE" ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && COLOR=yes
c() { [ -n "$COLOR" ] && printf '\033[%sm' "$1"; return 0; }
ok() { echo "  $(c 32)[ok]$(c 0) $*"; log "ok: $*"; m ok "$*"; }
warn() { echo "  $(c 33)[!]$(c 0)  $*"; log "warn: $*"; m warn "$*"; }
step() { echo; echo "$(c 1)== $*$(c 0)"; log "== $*"; m step "$*"; }
die() { # $1 what, $2 what to do, $3 exit code
	echo; echo "  $(c 31)[x]$(c 0)  $1"; log "FAIL: $1"
	[ -n "${2:-}" ] && echo "       $2"
	echo; echo "  Остановился здесь; всё, что сделано до этого, проверено. Журнал: $LOG"
	m fail "${3:-$E_FAIL}" "$1${2:+ | $2}"
	exit ${3:-$E_FAIL}
}

# --- the Station as it is ---------------------------------------------------
# Partitions by where they are on the eMMC (sectors), as init finds them.
part_at() {
	n=""; c=0
	for d in /sys/class/block/mmcblk0p*; do
		[ "$(cat $d/start 2>/dev/null)" = "$1" ] && [ "$(cat $d/size 2>/dev/null)" = "$2" ] && { n=${d##*/}; c=$((c+1)); }
	done
	[ $c = 1 ] && echo /dev/block/$n
}
MISC=$(part_at 4464640 32768) REC=$(part_at 4497408 65536) SYS=$(part_at 204800 4194304)
CACHE=$(part_at 4562944 3145728) DATA=$(part_at 12559356 2710532) BOOT=$(part_at 172032 32768)

in_android() { [ -e /system/build.prop ] && [ -x /system/bin/getprop ]; }
pmic_reg() { echo 0f > $PMIC 2>/dev/null && cat $PMIC 2>/dev/null; }
misc_head() { dd if=$MISC bs=4096 skip=$LOG_SEEK count=1 2>/dev/null | head -n1 | tr -d '\000'; }
misc_ours_or_free() {
	[ "$(dd if=$MISC bs=4096 skip=$LOG_SEEK count=1 2>/dev/null | head -c 16)" = $MAGIC ] && return 0
	[ "$(dd if=$MISC bs=4096 skip=$LOG_SEEK count=$LOG_BLOCKS 2>/dev/null | tr -d '\000' | head -c 1 | wc -c)" = 0 ]
}
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
head_sha() { head -c $2 $1 | sha256sum | cut -d' ' -f1; }   # $1 device, $2 bytes
rec_sha() { head_sha $REC ${1:-$IMG_SIZE}; }
rec_full_sha() { sha256sum $REC | cut -d' ' -f1; }
mb_free() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'; }
# write a whole file to a partition and read it back: 0 if it took
put() { # $1 file, $2 partition
	dd if=$1 of=$2 bs=1048576 conv=fsync 2>/dev/null; sync; echo 3 > /proc/sys/vm/drop_caches
	[ "$(head_sha $2 $(stat -c %s $1))" = "$(sha_of $1)" ]
}
# Android's own mount: busybox's says yes to a remount of /system and leaves
# it read-only; /proc/mounts is what tells
remount_system() {
	/system/bin/mount -o remount,$1 /system 2>/dev/null
	awk '$2 == "/system" { split($4, o, ","); print o[1] }' /proc/mounts | grep -qx $1
}
plain_rootfs() { [ -e $C/rootfs/etc/station/plain ]; }
# Yandex's stock recovery, as Android itself knows it: install-recovery.sh
# names its size and sha1 (and can rebuild it from boot)
IR=/system/bin/install-recovery.sh
stock_recovery() {
	set -- $(sed -n 's/.*applypatch -c EMMC:[^:]*recovery:\([0-9]*\):\([0-9a-f]*\).*/\1 \2/p' $IR 2>/dev/null | head -1)
	[ -n "${2:-}" ] && [ "$(head -c $1 $REC | sha1sum | cut -d' ' -f1)" = $2 ]
}
# direct boot: ours in boot (the release's, or one installed by update)
boot_is_ours() {
	set -- $(cat $S/boot.sha256 2>/dev/null)
	[ -n "${1:-}" ] && [ "$(head_sha $BOOT ${2:-0})" = "$1" ] || [ "$(head_sha $BOOT $BOOT_SIZE)" = "$BOOT_SHA" ]
}
direct_ok() {
	[ "$(dd if=/dev/block/mmcblk0 bs=512 skip=16 count=64 2>/dev/null | sha256sum | cut -d' ' -f1)" = $BOOT0_OK ] &&
		[ "$(dd if=/dev/block/mmcblk0 bs=512 skip=32806 count=1984 2>/dev/null | sha256sum | cut -d' ' -f1)" = $UBOOT_OK ]
}

# A problem found by the check: kept, and all of them are shown at its end
# with what to do (the basics - Android, the Station, root - stop at once:
# nothing after them could be checked)
PROBLEMS="" PCODE=""
problem() { # $1 what, $2 what to do, $3 exit code
	warn "$1"; [ -n "${2:-}" ] && echo "       $2"
	PROBLEMS="$PROBLEMS$1|${2:-}
"
	[ -n "$PCODE" ] || PCODE=${3:-$E_FAIL}
	m problem "${3:-$E_FAIL}" "$1${2:+ | $2}"
}
report_problems() {
	echo
	echo "  $(c 31)$(c 1)Установка не начнётся: на Станции надо поправить вот что$(c 0)"
	printf %s "$PROBLEMS" | awk -F '|' '{ printf "  %d. %s\n", NR, $1; if ($2 != "") printf "     → %s\n", $2 }'
	echo; echo "  Поправьте и запустите ту же команду снова: на Станции ничего не менялось."
}

checks() {
	step "Проверка Станции (ничего не меняет)"
	in_android || die "Это запускается в Android Станции." "Войдите в Android по SSH под root и запустите там." $E_NOT_STATION
	[ "$(getprop ro.board.platform)" = tulip ] && [ "$(getprop ro.build.version.release)" = 6.0.1 ] ||
		die "Это не Яндекс Станция 1 (YNDX-0001): $(getprop ro.product.model) на $(getprop ro.board.platform)." "Установщик только для неё." $E_NOT_STATION
	FW=$(getprop ro.build.version.incremental)
	ok "Яндекс Станция 1, прошивка $FW"
	[ "$(id -u)" = 0 ] || die "Нужен root." "Запустите от root." $E_NO_ROOT
	eff=$(awk '/^CapEff/ { print $2 }' /proc/self/status)
	[ $(( (0x$eff >> 21) & 1 )) = 1 ] ||
		die "root без полных прав (CapEff $eff): с ним не записать разделы." "Нужна оболочка root с полными правами (SSH под root, adb root)." $E_NO_ROOT
	ok "root с полными правами"
	[ -n "$MISC" ] && [ -n "$REC" ] && [ -n "$SYS" ] && [ -n "$CACHE" ] && [ -n "$DATA" ] && [ -n "$BOOT" ] ||
		die "Разметка eMMC не такая, как на проверенных Станциях." \
			"Пришлите: for p in /sys/class/block/mmcblk0p*; do echo \$p \$(cat \$p/start \$p/size); done" $E_NOT_STATION
	ok "разметка eMMC как на проверенных Станциях"
	r=$(pmic_reg)
	if [ "$r" = "REG[f]=e" ]; then ok "флаг загрузки в PMIC в норме"
	else problem "Флаг загрузки в PMIC не в обычном состоянии ($r)." "Выключите Станцию из розетки на 10 секунд, включите и повторите." $E_FAIL; fi
	if misc_ours_or_free; then ok "место для журнала Debian в misc $(misc_head | grep -q $MAGIC && echo 'уже наше' || echo свободно)"
	else problem "Конец раздела misc занят чем-то чужим (там будет журнал Debian)." "Похоже, на Станции стоит что-то ещё. Пришлите журнал $LOG." $E_NOT_STATION; fi
	if [ -f $RC ] && grep -qE 'quasar/onboot\.sh|station/handoff\.sh' $RC; then :
	else problem "В $RC нет запуска Яндекса: прошивка не такая, как на проверенных Станциях." "Пришлите журнал $LOG и версию прошивки ($FW)." $E_NOT_STATION; fi
	if remount_system rw; then remount_system ro; ok "/system можно менять (одна строка в rc.local для передачи в Debian)"
	else problem "/system не делается записываемым." "Нужна оболочка root с полными правами (SSH под root, adb root)." $E_NO_ROOT; fi
	n=0
	for f in vendor/modules/fw_bcm4356a2_ag.bin:ff7351dae9bd36f47a494579ae22330dcbeee61bf755e902c67b7bb418928e55 \
		vendor/modules/nvram.txt:fa23dcba44074022314e9ac2eafb5993cf47f0a5b75df27f770f3e542f991560 \
		vendor/modules/BCM4354A2.hcd:a39b2736e9f698c95d24ddc5dca222c4586c1cac76bda977cf20643dede86dc7 \
		vendor/firmware/tas5751m-2a.txt:9df7ff949168a040f6f7db36a0c7ee4c1c932274622e9ac9d6f5d665864ddc1f \
		vendor/firmware/tas5751m-2b.txt:6fddd462a57681870ebba0ca22e902b6044e0c697bcea5d1540f33ea2efd450e; do
		p=/system/${f%%:*}
		if [ ! -e $p ]; then problem "В Android нет $p: без него в Debian не будет Wi-Fi или звука." "Прошивка Станции не такая, как на проверенных. Пришлите журнал $LOG." $E_NOT_STATION
		elif [ "$(sha_of $p)" = "${f#*:}" ]; then n=$((n+1))
		else warn "$p не такой, как на проверенных Станциях (Debian возьмёт его всё равно)"; fi
	done
	[ $n = 5 ] && ok "прошивки Wi-Fi, Bluetooth и усилителей на месте"
	if direct_ok; then ok "загрузчик как на проверенных Станциях: можно и быструю загрузку (--mode direct)"; DIRECT_OK=yes
	else ok "загрузчик другой, чем на проверенных Станциях: быстрая загрузка недоступна, обычная — да"; fi
	CF=$(mb_free /cache) DF=$(mb_free /data) space=yes
	if [ "${CF:-0}" -lt $NEED_CACHE_MB ] && ! plain_rootfs; then
		big=$(ls -S /cache/*.zip 2>/dev/null | head -1)
		problem "В /cache свободно ${CF:-?} МБ, а Debian нужно $NEED_CACHE_MB." \
			"${big:+Там лежит скачанное обновление Android ($(du -m $big | cut -f1) МБ), его можно удалить: rm $big}" $E_SPACE
		space=""
	fi
	if [ "${DF:-0}" -lt $NEED_DATA_MB ]; then
		problem "В /data свободно ${DF:-?} МБ, а нужно $NEED_DATA_MB." "Удалите ненужное из /data (например, старые файлы в /data/local/tmp)." $E_SPACE
		space=""
	fi
	[ -n "$space" ] && ok "место: /cache ${CF} МБ, /data ${DF} МБ"
	IPADDR=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet / { sub("/.*", "", $2); print $2; exit }')
	if [ -n "$IPADDR" ]; then ok "Wi-Fi: $IPADDR"
	else problem "Станция не в сети Wi-Fi: Debian нечего скачать и не к чему подключиться." "Подключите Станцию к Wi-Fi в приложении Яндекса и повторите." $E_NET; fi
	if [ -d $C/rootfs ] && ! plain_rootfs; then
		problem "В $C/rootfs уже стоит другая система (не этот Debian)." "Установщик её не трогает. Если она не нужна: rm -rf $C/rootfs" $E_BLOCKED
	fi
	[ -z "$PROBLEMS" ] && return 0
	case $CMD in
	install|update) report_problems; m fail $PCODE "problems found"; exit $PCODE ;;
	esac
}

# --- choices: a settings screen on a terminal, flags and defaults otherwise --
FW="" IPADDR="" CF="" DF="" NOTE="" KEY="" PASSWORD="" WIFI_NAME="" WIFI_PASS="" TZ_SET="" MODE="" YES="" FROM="" PASS="" DIRECT_OK=""
asking() { [ -t 0 ] && [ -z "$YES" ] && [ -z "$MACHINE" ]; }
ask() { # $1 prompt, $2 default -> REPLY
	if asking; then printf '%s [%s]: ' "$1" "$2"; read -r REPLY || REPLY=""; [ -n "$REPLY" ] || REPLY=$2
	else REPLY=$2; fi
}
have_login() { [ -s $C/persist/ssh/authorized_keys ] || [ -s $C/persist/ssh/root.hash ]; }
mode_name() { case $1 in debian) echo "Debian через Android" ;; android) echo Android ;; direct) echo "Debian сразу (быстрая загрузка)" ;; esac; }
TZ_LIST="Europe/Kaliningrad Europe/Moscow Europe/Samara Asia/Yekaterinburg Asia/Omsk Asia/Novosibirsk
	Asia/Krasnoyarsk Asia/Irkutsk Asia/Yakutsk Asia/Vladivostok Asia/Magadan Asia/Kamchatka"
tz_name() {
	case $1 in
	Europe/Kaliningrad) echo "Калининград (МСК−1)" ;; Europe/Moscow) echo "Москва (МСК)" ;;
	Europe/Samara) echo "Самара (МСК+1)" ;; Asia/Yekaterinburg) echo "Екатеринбург (МСК+2)" ;;
	Asia/Omsk) echo "Омск (МСК+3)" ;; Asia/Novosibirsk) echo "Новосибирск (МСК+4)" ;;
	Asia/Krasnoyarsk) echo "Красноярск (МСК+4)" ;; Asia/Irkutsk) echo "Иркутск (МСК+5)" ;;
	Asia/Yakutsk) echo "Якутск (МСК+6)" ;; Asia/Vladivostok) echo "Владивосток (МСК+7)" ;;
	Asia/Magadan) echo "Магадан (МСК+8)" ;; Asia/Kamchatka) echo "Камчатка (МСК+9)" ;;
	*) echo "$1" ;;
	esac
}
# Area/City, letters and the few signs zone names have
tz_ok() { case "$1" in [A-Z]*/[A-Za-z]*) [ "${1#*[!A-Za-z0-9_/+-]}" = "$1" ] ;; *) false ;; esac; }
mode_desc() {
	case $1 in
	debian) echo "Debian через Android — надёжно, ~3 мин после включения" ;;
	direct) echo "Debian сразу — быстро, ~15 с после включения" ;;
	android) echo "Android, как сейчас; Debian — по команде «enter»" ;;
	esac
}
login_desc() {
	if [ -n "$KEY" ]; then echo "ключ ${KEY%% *} (${KEY##* })"
	elif [ -n "$PASSWORD" ]; then echo "пароль — придумаю и покажу в конце"
	else echo "как было (ключ или пароль уже сохранены)"; fi
}
line() { echo "  $(c 36)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(c 0)"; }
screen() {
	[ -n "$COLOR" ] && printf '\033[2J\033[H'
	line
	echo "   $(c 1)Debian для Яндекс Станции 1$(c 0)                  $(c 2)$VERSION$(c 0)"
	line
	echo "   $(c 32)✓$(c 0) Станция проверена: прошивка $FW, Wi-Fi $IPADDR"
	echo "     место: /cache $CF МБ, /data $DF МБ$([ -n "$DIRECT_OK" ] && echo ", быстрая загрузка доступна")"
	echo
	echo "   $(c 1)Настройки$(c 0)"
	echo "   $(c 36)1$(c 0)  Загрузка        $(mode_desc $MODE)"
	echo "   $(c 36)2$(c 0)  Вход по SSH     $(login_desc)"
	echo "   $(c 36)3$(c 0)  Ещё сеть Wi-Fi  ${WIFI_NAME:-нет (Debian возьмёт сети, сохранённые в Android)}"
	echo "   $(c 36)4$(c 0)  Часовой пояс    $(tz_name $TZ_SET)"
	echo
	echo "   $(c 1)Enter$(c 0) — установить    $(c 1)1–4$(c 0) — изменить    $(c 1)q$(c 0) — выйти"
	line
	[ -n "$NOTE" ] && echo "   $(c 33)$NOTE$(c 0)"
	NOTE=""
	printf '  > '
}
pick_mode() {
	echo; echo "   $(c 1)Что запускать при включении Станции$(c 0)"
	echo "   $(c 36)1$(c 0)  Debian через Android — надёжно: Android включается первым и через"
	echo "      пару минут сам передаёт Станцию Debian"
	if [ -n "$DIRECT_OK" ]; then
		echo "   $(c 36)2$(c 0)  Debian сразу — быстро, ~15 с. Android переезжает в recovery:"
		echo "      кнопка Алисы 10 секунд — и Станция в Android"
	else
		echo "   $(c 2)2  Debian сразу — недоступно: загрузчик этой Станции ещё не проверяли$(c 0)"
	fi
	echo "   $(c 36)3$(c 0)  Android с Алисой, как сейчас; Debian — по команде «enter»"
	printf '  > '; read -r r || r=""
	case "$r" in
	1) MODE=debian ;; 3) MODE=android ;;
	2) if [ -n "$DIRECT_OK" ]; then MODE=direct; else NOTE="Быстрая загрузка на этой Станции недоступна."; fi ;;
	"") ;; *) NOTE="Выберите 1, 2 или 3." ;;
	esac
}
pick_login() {
	echo; echo "   $(c 1)Вход в Debian по SSH (root)$(c 0)"
	echo "   Вставьте свой открытый ключ одной строкой (ssh-ed25519 …)"
	echo "   или нажмите Enter — тогда будет пароль, он покажется один раз в конце."
	printf '  > '; read -r r || r=""
	case "$r" in
	ssh-*|ecdsa-*|sk-*) KEY=$r PASSWORD="" ;;
	"") KEY="" PASSWORD=yes ;;
	*) NOTE="Это не похоже на открытый ключ: он начинается с ssh-ed25519, ssh-rsa или ecdsa-." ;;
	esac
}
pick_wifi() {
	echo; echo "   $(c 1)Ещё одна сеть Wi-Fi$(c 0) (сети, сохранённые в Android, Debian возьмёт сам)"
	echo "   Имя сети (Enter — не добавлять):"
	printf '  > '; read -r n || n=""
	[ -n "$n" ] || { WIFI_NAME="" WIFI_PASS=""; return; }
	echo "   Пароль сети «$n» (Enter — открытая сеть):"
	printf '  > '; read -r w || w=""
	if [ -n "$w" ] && { [ ${#w} -lt 8 ] || [ ${#w} -gt 63 ]; }; then
		NOTE="Пароль Wi-Fi — от 8 до 63 знаков; сеть не добавлена."
	else
		WIFI_NAME=$n WIFI_PASS=$w
	fi
}
pick_tz() {
	echo; echo "   $(c 1)Часовой пояс$(c 0)"
	i=0
	for z in $TZ_LIST; do i=$((i+1)); printf '   %s%2d%s  %s\n' "$(c 36)" $i "$(c 0)" "$(tz_name $z)"; done
	echo "   или впишите свой, например Europe/Minsk"
	printf '  > '; read -r r || r=""
	case "$r" in
	"") ;;
	*[!0-9]*) if tz_ok "$r"; then TZ_SET=$r; else NOTE="Не знаю такой пояс: «$r»."; fi ;;
	*) set -- $TZ_LIST
		if [ "$r" -ge 1 ] && [ "$r" -le $# ]; then shift $((r - 1)); TZ_SET=$1; else NOTE="Выберите номер из списка."; fi ;;
	esac
}
choices() {
	step "Настройки"
	# the time zone Android is set to, if it is a real one
	[ -n "$TZ_SET" ] || { TZ_SET=$(getprop persist.sys.timezone); tz_ok "$TZ_SET" || TZ_SET=Europe/Moscow; }
	[ -n "$MODE" ] || MODE=debian
	[ -n "$KEY" ] || [ -n "$PASSWORD" ] || have_login || PASSWORD=yes
	if asking; then
		while :; do
			screen
			read -r REPLY || die "Отменено: на Станции ничего не менялось." "" $E_CANCELLED
			case "$REPLY" in
			"") break ;;
			1) pick_mode ;; 2) pick_login ;; 3) pick_wifi ;; 4) pick_tz ;;
			q|Q|й|Й) echo; echo "  Отменено: на Станции ничего не менялось."; m fail $E_CANCELLED cancelled; exit $E_CANCELLED ;;
			*) NOTE="Не понял «$REPLY»: Enter — установить, 1–4 — изменить, q — выйти." ;;
			esac
		done
		[ -n "$COLOR" ] && printf '\033[2J\033[H'
	fi
	case "$MODE" in debian|android|direct) ;; *) die "--mode: debian, android или direct, а не «$MODE»." "" $E_USAGE ;; esac
	[ $MODE = direct ] && [ -z "$DIRECT_OK" ] &&
		die "Быструю загрузку на этом загрузчике ещё не проверяли." "Поставьте обычную (--mode debian) или пришлите вывод «check»." $E_NO_DIRECT
	tz_ok "$TZ_SET" || die "Не знаю такой часовой пояс: «$TZ_SET»." "Например: Europe/Moscow, Asia/Yekaterinburg." $E_USAGE
	if [ -n "$WIFI_PASS" ] && { [ ${#WIFI_PASS} -lt 8 ] || [ ${#WIFI_PASS} -gt 63 ]; }; then
		die "Пароль Wi-Fi должен быть от 8 до 63 знаков." "" $E_USAGE
	fi
	ok "при включении: $(mode_desc $MODE); вход: $(login_desc); пояс: $(tz_name $TZ_SET)"
}

# --- steps ------------------------------------------------------------------
fetch() { # $1 name, $2 sha256 -> $DL/$1, checked
	f=$DL/$1
	[ "$(sha_of $f)" = "$2" ] && { ok "$1 уже скачан и проверен"; return; }
	if [ -n "$FROM" ]; then
		[ "$(sha_of $FROM/$1)" = "$2" ] || die "$FROM/$1 нет или он не тот (sha256 не совпал)." "Нужен файл из выпуска $VERSION." $E_NET
		cp $FROM/$1 $f.part && [ "$(sha_of $f.part)" = "$2" ] && mv $f.part $f && { ok "$1 взят из $FROM и проверен"; return; }
		die "Не скопировать $FROM/$1." "Место в /data: $(mb_free /data) МБ." $E_SPACE
	fi
	# Android's own curl (its resolver; a static busybox has none here). It
	# has no certificate store it can read (Android 6 keeps its own kind), so
	# -k: the sha256 pinned in this installer is what vouches for the file.
	for i in 1 2 3; do
		say "  скачиваю $1..."; m download "$1"
		rm -f $f.part
		curl -fsSLk --connect-timeout 20 --retry 2 -o $f.part "$URL/$1" 2>>$LOG &&
			[ "$(sha_of $f.part)" = "$2" ] && { mv $f.part $f; ok "$1 скачан, sha256 совпал"; return; }
		log "curl, try $i: $(ls -l $f.part 2>&1)"
	done
	rm -f $f.part
	die "Не удалось скачать $1 целиком (или sha256 не совпал)." \
		"Проверьте интернет и запустите снова. Или скачайте файлы выпуска на ПК, положите на Станцию и запустите с --from <папка>." $E_NET
}

backup_recovery() {
	if [ -s $B/recovery-stock.img ] && [ "$(sha_of $B/recovery-stock.img)" = "$(cat $B/recovery-stock.sha256 2>/dev/null)" ]; then
		ok "копия стокового recovery уже есть"; return
	fi
	if ! stock_recovery; then
		warn "в recovery сейчас не стоковый образ (уже что-то ставили?): копию не делаю; при удалении сток соберёт сам Android ($IR)"
		return
	fi
	mkdir -p $B
	dd if=$REC of=$B/recovery-stock.img bs=1048576 2>/dev/null; sync
	s=$(rec_full_sha)
	[ "$(sha_of $B/recovery-stock.img)" = "$s" ] || die "Копия recovery не совпала с разделом." "Ничего не записано. Повторите." $E_WRITE
	echo $s > $B/recovery-stock.sha256
	ok "стоковый recovery (сверен с Android) сохранён: $B/recovery-stock.img — лучше скопировать его и на ПК"
}

# Android's own boot image, kept before direct boot puts ours there: it goes
# to recovery (Android then starts from there) and back to boot on uninstall
backup_boot() {
	if [ -s $B/boot-android.img ] && [ "$(sha_of $B/boot-android.img)" = "$(cat $B/boot-android.sha256 2>/dev/null)" ]; then
		ok "копия загрузочного образа Android уже есть"; return
	fi
	boot_is_ours && die "В boot уже наше ядро, а копии образа Android нет." "Не трогаю. Пришлите журнал." $E_FAIL
	[ "$(head -c 8 $BOOT)" = "ANDROID!" ] || die "В разделе boot не образ Android." "Не трогаю." $E_NOT_STATION
	mkdir -p $B
	dd if=$BOOT of=$B/boot-android.img bs=1048576 2>/dev/null; sync
	s=$(sha256sum $BOOT | cut -d' ' -f1)
	[ "$(sha_of $B/boot-android.img)" = "$s" ] || die "Копия boot не совпала с разделом." "Ничего не записано. Повторите." $E_WRITE
	echo $s > $B/boot-android.sha256
	ok "загрузочный образ Android сохранён: $B/boot-android.img — лучше скопировать его и на ПК"
}

unpack_rootfs() {
	if plain_rootfs && [ "$(cat $C/rootfs.sha256 2>/dev/null)" = "$ROOTFS_SHA" ]; then ok "Debian этой версии уже распакован"; return; fi
	mkdir -p $C && rm -rf $C/rootfs.new && mkdir $C/rootfs.new
	say "  распаковываю Debian в $C (пара минут)..."; m unpack "$ROOTFS"
	tar -C $C/rootfs.new --numeric-owner -xzf $DL/$ROOTFS 2>>$LOG ||
		{ rm -rf $C/rootfs.new; die "Debian не распаковался." "Место в /cache: $(mb_free /cache) МБ. Повторите." $E_SPACE; }
	for f in usr/sbin/wpa_supplicant usr/sbin/dropbear etc/station/plain etc/station/start etc/station-rootfs; do
		[ -e $C/rootfs.new/$f ] || { rm -rf $C/rootfs.new; die "В распакованном Debian нет /$f." "Архив повреждён? Удалите $DL/$ROOTFS и повторите."; }
	done
	if [ -d $C/rootfs ]; then
		# the owner's changes (apt and all) are a layer over this one: over
		# another base they would not fit, so a new base starts it clean
		warn "прежний Debian и всё, что в нём менялось, заменяются чистым"
		rm -rf $C/rootfs.prev $C/upper $C/work && mv $C/rootfs $C/rootfs.prev
	fi
	mv $C/rootfs.new $C/rootfs && echo "$ROOTFS_SHA" > $C/rootfs.sha256 && sync && rm -rf $C/rootfs.prev
	ok "Debian распакован: $(cat $C/rootfs/etc/station-rootfs), $(du -sm $C/rootfs | cut -f1) МБ"
}

# The way into Debian, kept where init reads it at every boot: keys are
# added, a password replaces the one before (init sets it once it changes)
save_login() {
	K=$C/persist/ssh
	mkdir -p $K && chmod 700 $K
	if [ -n "$KEY" ]; then
		grep -qxF "$KEY" $K/authorized_keys 2>/dev/null || echo "$KEY" >> $K/authorized_keys
		chmod 600 $K/authorized_keys; grep -qxF "$KEY" $K/authorized_keys && ok "ключ SSH сохранён"
	fi
	if [ -n "$PASSWORD" ]; then
		PASS=$(tr -dc 'a-km-np-z2-9' < /dev/urandom | head -c 12)
		cryptpw -m sha512 "$PASS" > $K/root.hash.new 2>/dev/null
		grep -q '^\$6\$' $K/root.hash.new || { rm -f $K/root.hash.new; die "Не получилось задать пароль." ""; }
		mv $K/root.hash.new $K/root.hash && chmod 600 $K/root.hash && ok "пароль root задан (покажу в конце)"
	fi
	have_login || die "Нет ни ключа, ни пароля: в Debian будет не войти." "Запустите снова с --key \"ssh-ed25519 ...\" или с --password." $E_USAGE
}

show_password() {
	[ -n "$PASS" ] || return 0
	m password "$PASS"
	echo
	echo "  $(c 33)┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓$(c 0)"
	echo "     Пароль root в Debian:   $(c 1)$PASS$(c 0)"
	echo "     Запишите его: больше он нигде не покажется."
	echo "     Забудете — новый даст «sh station-debian.run access» из Android."
	echo "  $(c 33)┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛$(c 0)"
	echo
}

persist() {
	W=$C/persist/opt-station/etc/wifi.conf
	mkdir -p ${W%/*}
	save_login
	if [ -n "$WIFI_NAME" ]; then
		hex=$(printf %s "$WIFI_NAME" | od -An -tx1 | tr -d ' \n')
		touch $W && chmod 600 $W
		if ! grep -q "ssid=$hex\$" $W; then
			{ printf 'network={\n\tssid=%s\n' $hex
			  if [ -n "$WIFI_PASS" ]; then printf '\tpsk="%s"\n' "$WIFI_PASS"; else printf '\tkey_mgmt=NONE\n'; fi
			  printf '\tpriority=10\n}\n'; } >> $W
		fi
		grep -q "ssid=$hex\$" $W && ok "сеть Wi-Fi «$WIFI_NAME» сохранена (в Debian: station-wifi list)"
	fi
	if [ -n "$TZ_SET" ]; then
		[ -e $C/rootfs/usr/share/zoneinfo/$TZ_SET ] || die "Нет такого часового пояса: $TZ_SET." "Например: Europe/Moscow, Asia/Yekaterinburg." $E_USAGE
		mkdir -p $C/upper/etc && rm -f $C/upper/etc/localtime && ln -s /usr/share/zoneinfo/$TZ_SET $C/upper/etc/localtime &&
			echo "$TZ_SET" > $C/upper/etc/timezone && ok "часовой пояс $TZ_SET"
	fi
	sync
}

write_recovery() {
	[ "$(rec_sha)" = "$IMG_SHA" ] && { echo "$IMG_SHA $IMG_SIZE" > $S/recovery.sha256; ok "в recovery уже этот образ"; return; }
	say "  записываю ядро Debian в recovery..."; m write recovery
	if ! put $DL/$IMG $REC; then
		if [ -s $B/recovery-stock.img ]; then
			put $B/recovery-stock.img $REC && warn "стоковый recovery возвращён"
		fi
		die "Записанный recovery не совпал при обратном чтении." "Повторите; если повторится — пришлите журнал." $E_WRITE
	fi
	echo "$IMG_SHA $IMG_SIZE" > $S/recovery.sha256
	ok "ядро Debian в recovery записано и проверено обратным чтением"
}

# Direct boot: Android's boot image into recovery, then ours into boot. A
# boot that does not take gets Android's image back before anything else.
write_direct() {
	if [ "$(head_sha $REC $(stat -c %s $B/boot-android.img))" = "$(cat $B/boot-android.sha256)" ]; then
		ok "Android уже в recovery"
	else
		say "  переношу Android в recovery..."; m write recovery
		put $B/boot-android.img $REC || die "Android не записался в recovery." "boot не тронут: Станция как была. Повторите." $E_WRITE
		ok "Android записан в recovery и проверен обратным чтением"
	fi
	if [ "$(head_sha $BOOT $BOOT_SIZE)" = "$BOOT_SHA" ]; then
		ok "в boot уже это ядро"
	else
		say "  записываю ядро Debian в boot..."; m write boot
		if ! put $DL/$BOOT_IMG $BOOT; then
			put $B/boot-android.img $BOOT &&
				die "Ядро не записалось в boot; образ Android возвращён в boot." "Станция как была. Повторите." $E_WRITE
			m fail $E_WRITE "boot broken"
			die "Ни ядро, ни образ Android не записались в boot. НЕ ПЕРЕЗАГРУЖАЙТЕ Станцию." \
				"Запустите установщик снова; копия Android: $B/boot-android.img" $E_WRITE
		fi
		ok "ядро Debian в boot записано и проверено обратным чтением"
	fi
	echo "$BOOT_SHA $BOOT_SIZE" > $S/boot.sha256
	echo direct > $S/mode
}

# Back from direct boot: Android's image into boot first (the one write that
# matters), then recovery to what the caller puts there
undirect() {
	boot_is_ours || { rm -f $S/boot.sha256; return 0; }
	[ -s $B/boot-android.img ] && [ "$(sha_of $B/boot-android.img)" = "$(cat $B/boot-android.sha256 2>/dev/null)" ] ||
		die "В boot наше ядро, а копии образа Android нет или она испорчена." "Не трогаю boot. Пришлите журнал." $E_FAIL
	say "  возвращаю образ Android в boot..."; m write boot
	put $B/boot-android.img $BOOT ||
		die "Образ Android не записался в boot. НЕ ПЕРЕЗАГРУЖАЙТЕ Станцию." "Запустите ту же команду снова." $E_WRITE
	rm -f $S/boot.sha256
	ok "образ Android снова в boot (сверен)"
}

# Android's side of the hand-off (android/station-handoff.sh), put in by the packer
write_handoff() {
	cat <<'HANDOFF_EOF'
@HANDOFF@
HANDOFF_EOF
}

# Android's flash_recovery (install-recovery.sh) would put the stock
# recovery back over ours, where a firmware runs it (one with a stock boot):
# without its patch it cannot. Uninstall puts the patch back.
protect_recovery() {
	if [ -e /system/recovery-from-boot.p ]; then
		remount_system rw && mv /system/recovery-from-boot.p /system/recovery-from-boot.p.station-off; sync; remount_system ro
	fi
	[ ! -e /system/recovery-from-boot.p ] || die "Не убрать /system/recovery-from-boot.p." "Android может вернуть свой recovery поверх Debian." $E_WRITE
	ok "Android не вернёт стоковый recovery поверх Debian"
}

install_handoff() {
	cp $BB $S/busybox.new && chmod 755 $S/busybox.new && mv $S/busybox.new $S/busybox
	write_handoff > $S/handoff.sh.new && chmod 755 $S/handoff.sh.new && mv $S/handoff.sh.new $S/handoff.sh
	[ -x $S/busybox ] && grep -q STATION-MAINLINE-HANDOFF $S/handoff.sh || die "Передача не записалась в $S." "Место в /data: $(mb_free /data) МБ." $E_SPACE
	if ! grep -qF "$HOOK" $RC; then
		remount_system rw || die "/system не делается записываемым." "" $E_NO_ROOT
		[ -e $RC.before-station ] || cp -p $RC $RC.before-station
		# before Yandex's own start (quasar's onboot.sh), or rc.local's end
		awk -v hook="$HOOK" '!done && (/quasar\/onboot\.sh/ || /^[ \t]*wait[ \t]*$/ || /^[ \t]*exit 0/) { print hook; done = 1 }
			{ print } END { if (!done) print hook }' $RC > $S/rc.local.new &&
			[ $(grep -cF "$HOOK" $S/rc.local.new) = 1 ] && cat $S/rc.local.new > $RC
		rm -f $S/rc.local.new; sync; remount_system ro
	fi
	grep -qF "$HOOK" $RC || die "Строка передачи не встала в $RC." "Копия прежнего: $RC.before-station" $E_WRITE
	ok "Android передаёт Станцию Debian (строка в $RC)"
	if [ "$MODE" = android ]; then touch $S/stay && ok "при включении: Android (Debian — командой «enter»)"
	else rm -f $S/stay && ok "при включении: Debian"; fi
	echo $MODE > $S/mode
}

reboot_now() {
	m reboot "$1"
	sync; (sleep 2; /system/bin/reboot) >/dev/null 2>&1 </dev/null &
}

enter_debian() {
	if boot_is_ours; then
		say "Перезагружаюсь в Debian (быстрая загрузка). Через ~15 с он в сети: $(c 1)ssh root@${IPADDR:-<адрес Станции>}$(c 0)"
		reboot_now direct; return
	fi
	set -- $(cat $S/recovery.sha256 2>/dev/null)
	[ -n "${1:-}" ] && [ "$(rec_sha ${2:-0})" = "$1" ] || die "В recovery нет Debian." "Сначала: install." $E_NOT_INSTALLED
	misc_ours_or_free || die "Конец misc занят чужим." "" $E_NOT_STATION
	[ "$(pmic_reg)" = "REG[f]=e" ] || die "Флаг загрузки в PMIC не в обычном состоянии." "Выключите Станцию из розетки на 10 с и повторите."
	printf '%s-HANDOFF\n' $MAGIC | dd of=$MISC bs=4096 seek=$LOG_SEEK conv=notrunc,sync 2>/dev/null; sync
	echo 0f10 > $PMIC; echo 0f > $PMIC
	[ "$(cat $PMIC)" = "REG[f]=10" ] || die "Флаг загрузки в PMIC не встал." ""
	say "Перезагружаюсь в Debian. Через минуту он в сети: $(c 1)ssh root@${IPADDR:-<адрес Станции>}$(c 0)"
	say "Если что-то не так, Станция сама вернётся в Android; там: «sh station-debian.run status»."
	reboot_now recovery
}

# --- after the fact: what is installed, what Debian's last boot left in misc
status() {
	step "Состояние"
	installed=no mode=none rec=other last=none
	plain_rootfs && installed=yes
	stock_recovery && rec=stock
	set -- $(cat $S/recovery.sha256 2>/dev/null)
	[ -n "${1:-}" ] && [ "$(rec_sha ${2:-0})" = "$1" ] && rec=debian
	if boot_is_ours; then
		mode=direct; ok "быстрая загрузка: в boot ядро Debian$([ "$(head_sha $BOOT $BOOT_SIZE)" = "$BOOT_SHA" ] && echo " (выпуск $VERSION)")"
		[ -s $B/boot-android.img ] && [ "$(head_sha $REC $(stat -c %s $B/boot-android.img))" = "$(cat $B/boot-android.sha256 2>/dev/null)" ] &&
			rec=android && ok "Android — в recovery"
	elif [ $rec = debian ]; then
		ok "в recovery Debian$([ "$1" = "$IMG_SHA" ] && echo " (выпуск $VERSION)")"
		[ -e $S/stay ] && mode=android || mode=debian
		grep -qF "$HOOK" $RC && ok "передача из Android установлена" || warn "передачи из Android нет"
	else
		warn "Debian не загружается: ни в boot, ни в recovery его нет"
	fi
	[ $mode = none ] || echo "  при включении: $(mode_name $mode)"
	dd if=$MISC bs=4096 skip=$LOG_SEEK count=64 2>/dev/null | tr -d '\000' > $DL/last.log
	case "$(head -n1 $DL/last.log)" in
	"$MAGIC-ALIVE-B1 (early)"*) last=early; warn "Debian начал загружаться и остановился до сети" ;;
	"$MAGIC-ALIVE-B1 (to Android"*) last=to-android; warn "Debian вернул Станцию в Android: $(head -n1 $DL/last.log | sed 's/.*to Android: //; s/)$//')" ;;
	"$MAGIC-ALIVE-B1"*) last=ok; ok "последняя загрузка Debian: $(head -n1 $DL/last.log | sed 's/.*(//; s/)$//')" ;;
	"$MAGIC-STAY"*) last=stay; warn "Debian попросил остаться в Android (station-android или сбой)" ;;
	"$MAGIC-HANDOFF"*) last=handoff; warn "Станция ушла в Debian, а он не отметился: ядро не стартовало?" ;;
	*) echo "  Debian здесь ещё не загружался" ;;
	esac
	# what init said on that boot (its own section of the log, not dmesg's copy)
	awk '/^--- stage B/ { s = 1; next } /^---/ { s = 0 } s' $DL/last.log |
		grep -E "^(firmware:|NO wlan0|root filesystem|root password|no SSH key|no usable network|to Android|started from)|IP [0-9]" | head -8 | sed 's/^/       /'
	[ -s $S/handoff.log ] && [ $mode != direct ] && tail -2 $S/handoff.log | sed 's/^/  передача: /'
	m status "installed=$installed" "mode=$mode" "recovery=$rec" "last_boot=$last" "version=$VERSION" \
		"rootfs=$(cat $C/rootfs/etc/station-rootfs 2>/dev/null | tr ' ' '_')" "direct_ok=$(direct_ok && echo yes || echo no)"
}

uninstall() {
	step "Удаление: Станция возвращается к стоку"
	if asking; then printf '  Удалить Debian со всеми его данными? Напишите «да»: '; read -r REPLY; [ "$REPLY" = да ] || die "Отменено." "" $E_CANCELLED; fi
	undirect
	touch $S/stay
	remount_system rw || die "/system не делается записываемым." "" $E_NO_ROOT
	if [ -e $RC.before-station ]; then cat $RC.before-station > $RC && rm $RC.before-station
	else grep -vF "$HOOK" $RC > $S/rc.local.new && cat $S/rc.local.new > $RC; rm -f $S/rc.local.new; fi
	[ -e /system/recovery-from-boot.p.station-off ] && mv /system/recovery-from-boot.p.station-off /system/recovery-from-boot.p
	sync; remount_system ro
	grep -qF "$HOOK" $RC && die "Строка передачи осталась в $RC." "" $E_WRITE
	ok "передача из Android в Debian убрана"
	if [ -s $B/recovery-stock.img ] && [ "$(sha_of $B/recovery-stock.img)" = "$(cat $B/recovery-stock.sha256)" ]; then
		put $B/recovery-stock.img $REC
	fi
	# no copy, or it did not take: Android builds its own from boot
	stock_recovery || { sh $IR >> $LOG 2>&1; sync; echo 3 > /proc/sys/vm/drop_caches; }
	stock_recovery && ok "стоковый recovery на месте (сверен с Android)" ||
		warn "стоковый recovery вернуть не вышло: Android работает и без него, но пришлите журнал"
	rm -rf $C && ok "Debian и его данные удалены из /cache"
	misc_ours_or_free && dd if=/dev/zero of=$MISC bs=4096 seek=$LOG_SEEK count=$LOG_BLOCKS conv=notrunc 2>/dev/null; sync
	rm -rf $S && echo "  [ok] /data/local/station удалён"
	echo; echo "Готово: Станция как была. Перезагрузите её (из розетки)."
}

# --- main -------------------------------------------------------------------
CMD=install
while [ $# -gt 0 ]; do
	case "$1" in
	install|check|download|status|log|enter|stay|unstay|access|update|uninstall|version) CMD=$1 ;;
	--key) KEY=${2:-}; shift ;;
	--password) PASSWORD=yes ;;
	--wifi) WIFI_NAME=${2:-} WIFI_PASS=${3:-}; shift; [ $# -gt 1 ] && case "$2" in --*) ;; *) shift ;; esac ;;
	--tz) TZ_SET=${2:-}; shift ;;
	--mode) MODE=${2:-}; shift ;;
	--from) FROM=${2:-}; shift ;;
	--yes|-y) YES=yes ;;
	--machine) ;;
	-h|--help) sed -n '8,12p' "$0"; exit 0 ;;
	*) die "Не понимаю «$1»." "Справка: --help" $E_USAGE ;;
	esac
	[ $# -gt 0 ] && shift
done
log "--- $CMD, installer $VERSION"
echo "Debian для Яндекс Станции 1 — установщик $VERSION"
m start "$CMD" "$VERSION"
case $CMD in
version) m version "$VERSION"; echo "$VERSION" ;;
check) checks
	if [ -n "$PROBLEMS" ]; then report_problems; m blocked "$(printf %s "$PROBLEMS" | cut -d'|' -f1 | tr '\n' ';')"; exit $E_BLOCKED; fi
	echo; echo "  $(c 32)Станция готова к установке.$(c 0)" ;;
download) checks; step "Загрузка ($URL)"; fetch $IMG $IMG_SHA; fetch $ROOTFS $ROOTFS_SHA
	[ -n "$DIRECT_OK" ] && fetch $BOOT_IMG $BOOT_SHA
	tar -tzf $DL/$ROOTFS ./etc/station/plain > /dev/null 2>&1 && ok "архив Debian читается"
	echo; echo "Всё скачано и проверено, на Станции ничего не менялось." ;;
install|update)
	checks
	if [ $CMD = install ]; then choices
	else
		plain_rootfs || die "Debian не установлен." "Сначала: install." $E_NOT_INSTALLED
		if boot_is_ours; then MODE=direct; elif [ -e $S/stay ]; then MODE=android; else MODE=debian; fi
	fi
	step "Загрузка ($URL)"
	if [ $MODE = direct ]; then fetch $BOOT_IMG $BOOT_SHA; else fetch $IMG $IMG_SHA; fi
	[ $CMD = install ] && fetch $ROOTFS $ROOTFS_SHA
	step "Установка"
	# installer debian-v1 left these 700: none of Debian's own users could get in
	for d in $C/rootfs $C/upper; do [ -d $d ] && chmod 755 $d; done
	backup_recovery
	[ $MODE = direct ] && backup_boot
	# update: a new kernel; Debian itself its owner updates with apt
	[ $CMD = install ] && { unpack_rootfs; persist; }
	if [ $MODE = direct ]; then
		write_direct; protect_recovery
	else
		undirect; write_recovery; install_handoff; protect_recovery
	fi
	echo
	show_password
	m done "$CMD" "mode=$MODE"
	case $MODE in
	direct) enter_debian ;;
	debian) enter_debian ;;
	*) say "Готово. Загрузить Debian: sh station-debian.run enter" ;;
	esac ;;
status) status ;;
log) dd if=$MISC bs=4096 skip=$LOG_SEEK count=$LOG_BLOCKS 2>/dev/null | tr -d '\000' ;;
enter) in_android || die "Это запускается в Android." "" $E_NOT_STATION; enter_debian ;;
access)
	# a lost password or key: a new way in, from Android
	in_android || die "Это запускается в Android." "" $E_NOT_STATION
	plain_rootfs || die "Debian не установлен." "Сначала: install." $E_NOT_INSTALLED
	if [ -z "$KEY" ] && [ -z "$PASSWORD" ]; then
		asking && echo "  Новый вход в Debian: вставьте открытый ключ (ssh-ed25519 ...) или нажмите Enter — будет новый пароль."
		ask "  Ключ" ""; case "$REPLY" in ssh-*|ecdsa-*|sk-*) KEY=$REPLY ;; *) PASSWORD=yes ;; esac
	fi
	step "Новый вход в Debian"; save_login; sync; show_password
	m done access
	say "Он заработает при следующей загрузке Debian: sh station-debian.run enter" ;;
stay|unstay)
	boot_is_ours && die "При быстрой загрузке Станция всегда включается в Debian." \
		"Android: кнопка Алисы 10 с или station-android в Debian. Насовсем в Android: uninstall." $E_USAGE
	if [ $CMD = stay ]; then touch $S/stay && say "При включении: Android. Debian — «enter»."
	else rm -f $S/stay && say "При включении снова Debian."; fi
	m done $CMD ;;
uninstall) in_android || die "Удаление запускается из Android." "" $E_NOT_STATION; uninstall; m done uninstall ;;
esac
