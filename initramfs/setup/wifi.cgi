#!/bin/sh
# The Wi-Fi page of plain Debian's access point (init.sh: start_ap; ours
# has its own panel). It lists the networks init saw just before raising the
# access point, takes a name and a password, and saves them with the root
# filesystem's own station-wifi, which tells init to try them at once.
export PATH=/bin
R=${R:-/newroot}
SCAN=$R/run/station/scan.txt

html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
hex() { printf %s "$1" | od -An -tx1 -v | tr -d ' \n'; }
unhex() {
	h=$1
	while [ -n "$h" ]; do
		b=${h%"${h#??}"}; h=${h#??}
		printf "\\$(printf %o "0x$b")"
	done
}
# wpa_cli writes a name's other bytes as \xNN (printf turns them back)
unesc() { printf "$(printf %s "$1" | sed 's/%/%%/g')"; }
# one field of the posted form, decoded
field() {
	v=$(printf %s "$BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1 | sed 's/+/ /g')
	httpd -d "$v"
}
page() { # $1 title, then the body on stdin
	printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
	cat <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1</title><style>
body{font:16px/1.4 system-ui,sans-serif;margin:0;padding:16px;background:#f4f4f5;color:#18181b}
main{max-width:420px;margin:0 auto}h1{font-size:22px;margin:8px 0 16px}
.card{background:#fff;border-radius:12px;padding:16px;margin-bottom:12px}
label.net{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid #eee}
label.net:last-child{border:0}.sig{margin-left:auto;color:#71717a;font-size:14px}
input[type=text],input[type=password]{box-sizing:border-box;width:100%;font-size:16px;padding:10px;border:1px solid #d4d4d8;border-radius:8px;margin-top:6px}
button{width:100%;font-size:17px;padding:12px;border:0;border-radius:10px;background:#2563eb;color:#fff;margin-top:12px}
.warn{background:#fef3c7}.ok{background:#dcfce7}small{color:#71717a}
@media (prefers-color-scheme:dark){body{background:#18181b;color:#f4f4f5}.card{background:#27272a}
label.net{border-color:#3f3f46}.warn{background:#713f12}.ok{background:#14532d}
input[type=text],input[type=password]{background:#18181b;color:#f4f4f5;border-color:#52525b}}
</style></head><body><main>
EOF
	cat
	echo "</main></body></html>"
}

if [ "${REQUEST_METHOD:-GET}" = POST ]; then
	BODY=$(head -c "${CONTENT_LENGTH:-0}")
	name=$(field other)
	[ -n "$name" ] || name=$(unhex "$(field ssid)")
	pass=$(field pass)
	if [ -z "$name" ]; then
		err="Выберите сеть или впишите её имя."
	elif [ -n "$pass" ] && { [ ${#pass} -lt 8 ] || [ ${#pass} -gt 63 ]; }; then
		err="Пароль Wi-Fi — от 8 до 63 знаков."
	elif chroot $R /usr/bin/env -i PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		station-wifi add "$name" "$pass" > /dev/null 2>&1; then
		n=$(printf %s "$name" | html)
		page "Станция: сеть сохранена" <<EOF
<h1>Сеть сохранена</h1>
<div class="card ok">Станция пробует подключиться к «$n». Через несколько секунд эта
сеть Станции пропадёт — так и должно быть: Станция уходит в вашу сеть.</div>
<div class="card"><small>Если пароль неверный, через минуту Станция снова поднимет свою
сеть, а эта страница скажет об этом. Найти Станцию в вашей сети: адрес в роутере,
<code>ssh root@&lt;адрес&gt;</code>.</small></div>
EOF
		exit 0
	else
		err="Не получилось сохранить сеть."
	fi
fi

{
	echo "<h1>Wi-Fi для Станции</h1>"
	if [ -n "${err:-}" ]; then
		echo "<div class=\"card warn\">$err</div>"
	elif [ -e $R/run/station/net-failed ]; then
		echo "<div class=\"card warn\">Последняя сохранённая сеть не подключилась: проверьте пароль.</div>"
	fi
	echo '<form method="post" action="/cgi-bin/wifi"><div class="card">'
	n=0
	if [ -s $SCAN ]; then
		# bssid, frequency, signal, flags, name: the strongest of each name first
		tail -n +2 $SCAN | sort -t "$(printf '\t')" -k3,3nr | awk -F '\t' '$5 != "" && !seen[$5]++' |
		while IFS="$(printf '\t')" read -r bssid freq sig flags ssid; do
			raw=$(unesc "$ssid")
			lock=""; case "$flags" in *WPA*|*WEP*|*RSN*) lock=" 🔒" ;; esac
			echo "<label class=\"net\"><input type=\"radio\" name=\"ssid\" value=\"$(hex "$raw")\">$(printf %s "$raw" | html)$lock<span class=\"sig\">$sig dBm</span></label>"
		done
	else
		echo "<small>Сети вокруг не видны. Впишите имя своей сети ниже.</small>"
	fi
	cat <<'EOF'
</div><div class="card">
<label>Другая сеть (скрытая) — имя<input type="text" name="other" autocomplete="off" autocapitalize="none"></label>
<label style="display:block;margin-top:12px">Пароль (для открытой сети — пусто)
<input type="password" name="pass" autocomplete="off"></label>
<button type="submit">Подключить</button></div></form>
<div class="card"><small>Debian на Яндекс Станции. Эта сеть Станции открытая и появляется,
только когда Станция не нашла ни одной знакомой сети.</small></div>
EOF
} | page "Станция: Wi-Fi"
