#!/bin/sh
# ustanovka-napryamuyu.sh — домены облака Keenetic/netcraze в список «напрямую» (07.10.2026, владелец: «выкатывай»;
# домены — Кот 1, на HERO стоят с 07.10). Удалённый доступ KeenDNS/netcraze.pro не должен идти через туннель.
# Зовётся кнопкой «Обновить веб-панель» (KOMPONENTY) и установщиком. Идемпотентно: что есть — не трогаем.
# Коды: 0 — всё на месте; 1 — не смог добавить ни одного; 2 — не узнали (нет сервера DNS).
[ "$#" -eq 0 ] || { echo "аргументов не принимаю"; exit 2; }
say() { echo "[napryamuyu] $1"; }
DOMENY="keenetic.ru keenetic.com keenetic.pro keenetic.link keenetic.name keenetic.io netcraze.ru netcraze.com netcraze.link netcraze.pro netcraze.club netcraze.io netcraze.name crazedns.ru omni.ru"
# СНИМКИ «RU НАПРЯМУЮ» ДЛЯ ДВИЖКА KEENETIC (08.10.2026). Движок грузит ru-ranges/ru-domains только с суммой, зашитой
# в нём самом; клал их лишь ustanovka-route.sh, и только при смене версии движка — роутеры, где движок поставил
# install.sh, их не получили: «ОТКАЗ: нет файла /opt/etc/qwdtt/ru-ranges-2026.08.18.txt». Имена и суммы — из движка.
ENG=/opt/bin/meridian-route
if [ -f "$ENG" ]; then
	for _k in RANGES DOMAINS; do
		_f=$(sed -n "s|^RU_${_k}_FILE=\"\\\$RUDIR/\(.*\)\"\$|\1|p" "$ENG" | head -1)
		_s=$(sed -n "s|^RU_${_k}_SHA=\"\([0-9a-f]*\)\"\$|\1|p" "$ENG" | head -1)
		[ -n "$_f" ] && [ -n "$_s" ] || continue
		_d=/opt/etc/qwdtt/$_f
		if [ -f "$_d" ] && [ "$(sha256sum "$_d" | cut -d' ' -f1)" = "$_s" ]; then continue; fi
		_ok=0
		for _b in http://10.77.77.1:8080/bin http://45.10.247.23/bin https://raw.githubusercontent.com/JinComputers/meridian-router/entware http://138.124.78.252:8080/bin; do
			rm -f "$_d.new"
			if command -v curl >/dev/null 2>&1; then curl -fsS -m 60 -o "$_d.new" "$_b/$_f" 2>/dev/null; else wget -q -T 60 -O "$_d.new" "$_b/$_f" 2>/dev/null; fi
			if [ -s "$_d.new" ] && [ "$(sha256sum "$_d.new" | cut -d' ' -f1)" = "$_s" ]; then mv -f "$_d.new" "$_d"; _ok=1; break; fi
		done
		rm -f "$_d.new"
		[ "$_ok" = 1 ] && say "снимок $_f положен (сумма сошлась с движком)" || say "ВНИМАНИЕ: снимок $_f не скачался — «RU напрямую» не включится"
	done
fi

if [ -x /opt/bin/meridian-dns ]; then
	BIN=/opt/bin/meridian-dns; CONF=${NAPR_CONF:-/opt/etc/qwdtt/meridian-dns-napryamuyu.yaml}; GR=direct
elif [ -x /usr/sbin/meridian-dns ]; then
	BIN=/usr/sbin/meridian-dns; CONF=${NAPR_CONF:-/etc/qwdtt/meridian-dns-napryamuyu.yaml}; GR="RU напрямую"
else
	say "сервера DNS нет — пропускаю"; exit 2
fi
if [ ! -f "$CONF" ]; then
	mkdir -p "$(dirname "$CONF")" && printf 'version: 0\ngroups: []\n' > "$CONF.new" && mv -f "$CONF.new" "$CONF" || { say "не создать $CONF"; exit 1; }
	say "создан $CONF"
fi
cp -p "$CONF" "$CONF.pered-napryamuyu" 2>/dev/null
est=0; dob=0; net=0
for d in $DOMENY; do
	if grep -q "rule: $d\$" "$CONF" 2>/dev/null; then est=$((est + 1)); continue; fi
	"$BIN" -config "$CONF" domains add "$d" --group "$GR" --create < /dev/null > /dev/null 2>&1
	case $? in 0|3) dob=$((dob + 1)) ;; *) net=$((net + 1)) ;; esac
done
say "домены Keenetic напрямую: уже было $est, добавлено $dob, не добавилось $net"
[ "$dob" -gt 0 ] || rm -f "$CONF.pered-napryamuyu"
if [ "$net" -gt 0 ] && [ "$dob" -eq 0 ] && [ "$est" -eq 0 ]; then
	[ -f "$CONF.pered-napryamuyu" ] && mv -f "$CONF.pered-napryamuyu" "$CONF"
	say "ИТОГ: ОТКАЗ — ни один домен не добавился"; exit 1
fi
say "ИТОГ: ЗЕЛЁНОЕ"; exit 0
