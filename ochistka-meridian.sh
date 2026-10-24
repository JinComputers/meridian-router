#!/bin/sh
# ochistka-meridian.sh — убрать установку Meridian с Keenetic (Entware) перед чистой переустановкой.
# По умолчанию ТОЛЬКО ПОКАЗЫВАЕТ, что найдено. Убирает с аргументом «da»; ничего не стирает, а ПЕРЕКЛАДЫВАЕТ в
# /opt/var/backup/meridian-ochistka-<время> (mv; из этого каталога всё можно вернуть обратно).
# Сначала останавливает свои процессы и снимает свои правила iptables; чужое (nfqws2, чужие правила) не трогает.
PATH="/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:${PATH:-}"; export PATH
[ "$#" -le 1 ] || { echo "аргументов не больше одного: da (убрать) или без аргументов (показать)"; exit 2; }
[ -d /opt/etc/init.d ] || { echo "ОТКАЗ: это не Entware (нет /opt/etc/init.d)"; exit 1; }
MODE=${1:-pokaz}; [ "$MODE" = da ] || [ "$MODE" = pokaz ] || { echo "аргумент: da или пусто"; exit 2; }
BAK="/opt/var/backup/meridian-ochistka-$(date +%Y%m%d-%H%M%S)"
LIST="/opt/etc/init.d/S99qwdtt /opt/etc/init.d/S98qwdtt-web /opt/etc/init.d/S81meridian-dns /opt/etc/init.d/S51meridian-antidpi
/opt/bin/qwdtt /opt/bin/qwdtt-ctl /opt/bin/qwdtt-probe.sh /opt/bin/qwdtt-web /opt/bin/meridian-route /opt/bin/meridian-route-min
/opt/bin/meridian-dns /opt/bin/meridian-antidpi /opt/bin/meridian-antidpi-ctl
/opt/etc/qwdtt /opt/etc/ndm/netfilter.d/50-meridian-dns.sh /opt/var/backup/qwdtt"
echo "== найдено:"; N=0
for p in $LIST; do [ -e "$p" ] && { echo "   $p"; N=$((N+1)); }; done
[ "$N" -gt 0 ] || { echo "ничего нашего нет — чисто"; exit 0; }
[ "$MODE" = da ] || { echo "== это только показ. Убрать: sh $0 da"; exit 0; }
FREE=$(df -Pk /opt | awk 'NR==2{print $4}'); [ "${FREE:-0}" -ge 1024 ] || { echo "ОТКАЗ: на /opt меньше 1 МБ"; exit 1; }
mkdir -p "$BAK" || { echo "ОТКАЗ: не создать $BAK"; exit 1; }
echo "== останавливаю свои службы"
for i in S51meridian-antidpi S81meridian-dns S98qwdtt-web S99qwdtt; do
  [ -x "/opt/etc/init.d/$i" ] && "/opt/etc/init.d/$i" stop < /dev/null >/dev/null 2>&1
done
sleep 2
for n in qwdtt-web meridian-dns meridian-antidpi qwdtt; do killall "$n" 2>/dev/null; done
echo "== перекладываю в $BAK"
for p in $LIST; do
  [ -e "$p" ] || continue
  d="$BAK$(dirname "$p")"; mkdir -p "$d"; mv "$p" "$d/" && echo "   убрано: $p" || echo "   НЕ УДАЛОСЬ: $p"
done
# строки расписания нашего пробника/DNS
CR=/opt/etc/crontabs/root
if [ -f "$CR" ]; then cp -p "$CR" "$BAK/crontab.root"; grep -v -e qwdtt -e meridian "$CR" > "$CR.new" && mv "$CR.new" "$CR"; fi
# наши цепочки iptables (только с нашими именами)
for t in nat mangle; do
  for c in MERIDIAN_DNS MERIDIAN_DNS_MARK; do
    iptables -t $t -S 2>/dev/null | grep -- "-j $c\$" | sed 's/^-A/-D/' | while read -r r; do iptables -t $t $r 2>/dev/null; done
    iptables -t $t -F $c 2>/dev/null; iptables -t $t -X $c 2>/dev/null
  done
done
iptables -t mangle -S 2>/dev/null | grep -q 'queue-num 500' && echo "ВНИМАНИЕ: остались правила NFQUEUE 500 (анти-DPI) — после перезагрузки роутера уйдут"
echo "== готово. Осталось процессов: $(ps w 2>/dev/null | grep -E 'qwdtt|meridian-(dns|antidpi)' | grep -v grep | grep -vc ochistka)"
echo "   вернуть всё: cp -a $BAK/opt/. /opt/"
