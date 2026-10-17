#!/bin/sh
# ustanovka-antidpi.sh — исполнитель установки анти-DPI Кота 1 на Entware
# (Keenetic): движок meridian-antidpi, meridian-antidpi-ctl (группы, договор с
# панелью как на OpenWrt), автозапуск S51meridian-antidpi и независимое правило
# NFQUEUE 500. Зовётся кнопкой «Обновить веб-панель» через KOMPONENTY и
# установщиком. Владелец 29.09.2026: «запушить всем по кнопкам в панели…
# аккуратно с антиDPI, у некоторых может быть установлен nfqws2».
#
# КОДЫ ВОЗВРАТА — интерфейс, панель судит по ним:
#   0  стоит и ПЕРЕЖИЛО ПЕРЕЗАПУСК (или уже стояло ровно это)
#   1  отказ; всё, что меняли, возвращено назад (только mv); причина напечатана
#   2  проверка не выполнена (не узнали; не «хорошо» и не «плохо»)
#
# qwdtt-ctl не зовётся ни разу: клиент и туннель не трогаются.
#
# ЗАМЕНА nfqws2 — по ответу Кота 1 (29.09.2026):
#   - opkg remove НЕ делаем: кнопку жмут без человека, откат обязан работать
#     без сети. Останавливаем init nfqws2 и отводим его (mv), вместе с
#     крючком NDM в /opt/etc/ndm/netfilter.d/ — иначе правила nfqws2 вернутся
#     при первом же перечитывании файрвола.
#   - имена файлов берём у самого пакета: opkg files nfqws2-keenetic; ищем
#     по 'nfqws2', НЕ по 'nfqws' (ndnproxy_nfqws.conf у прошивки).
#   - веб-панель nfqws-keenetic-web, ip-политику «nfqws» и ndnproxy не трогаем.
#   - после всего в iptables-save -t mangle не должно быть NFQUEUE, кроме
#     нашей очереди 500. Осталось — откат.
# ПРОВЕРКИ ДО ЛЮБЫХ ИЗМЕНЕНИЙ: MemAvailable ≥ 20 МБ и модули ядра NFQUEUE
# (пробная цепочка). Нет — отказ, ничего не тронуто.
#
# КРЮЧОК NDM (Кот 1, 29.09.2026): NDM при пересборке netfilter (переподключение
# WAN/4G) стирает наши правила в mangle FORWARD, движок остаётся жить, обход
# молча пропадает — так было на HERO. Крючок
# /opt/etc/ndm/netfilter.d/60-meridian-antidpi.sh зовёт «S51meridian-antidpi
# rules» и возвращает их. Ставится вместе со всем, в откате убирается; в
# приёмке правила снимаем руками и зовём крючок — правил должно стать снова 2.

# ---------- КАНАЛ И ИСТОЧНИКИ — тем же приёмом, что ustanovka-dns.sh ----------
if [ -z "${QWDTT_CHANNEL+SET}" ]; then
  QWDTT_CHANNEL=bin
elif [ -z "$QWDTT_CHANNEL" ]; then
  echo "[antidpi] ОТКАЗ: QWDTT_CHANNEL задан ПУСТЫМ — канал потерялся по дороге. Ничего не тронуто." >&2
  exit 1
fi
case "$QWDTT_CHANNEL" in
  bin|beta) ;;
  *) echo "[antidpi] ОТКАЗ: QWDTT_CHANNEL='$QWDTT_CHANNEL' неизвестен. Можно: bin, beta" >&2; exit 1 ;;
esac
# PATH: в пайпе/ssh-оболочке Keenetic в нём может не быть /opt/sbin и /sbin — там iptables/ip/nfqws.
# 02.10.2026, живой случай у клиента: «нет iptables» при том, что команда есть в /opt/sbin.
PATH="/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:${PATH:-}"; export PATH
local_ipv4() {
	if command -v ip >/dev/null 2>&1; then
		ip -4 addr show 2>/dev/null | awk '$1 == "inet" { split($2, a, "/"); print a[1] }'
		return 0
	fi
	if command -v ifconfig >/dev/null 2>&1; then
		ifconfig 2>/dev/null | sed -n 's/.*addr:\([0-9][0-9.]*\).*/\1/p'
		ifconfig 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\).*/\1/p'
		return 0
	fi
	return 1
}
same_net16() {
	_addrs=$(local_ipv4) || return 1
	[ -n "$_addrs" ] || return 1
	echo "$_addrs" | awk -v gw="$1" '
		BEGIN { split(gw, g, ".") }
		{ split($1, o, "."); if (o[1] == g[1] && o[2] == g[2]) { found = 1 } }
		END { exit found ? 0 : 1 }'
}
BASE_LIST=""
for _ip in ${QWDTT_INTERNAL_BASES-10.77.77.1}; do
	if same_net16 "$_ip"; then
		BASE_LIST="${BASE_LIST:+$BASE_LIST }http://$_ip:8080/$QWDTT_CHANNEL"
	fi
done
BASE_LIST="${BASE_LIST:+$BASE_LIST }http://138.124.78.252:8080/$QWDTT_CHANNEL"
# Источники. QWDTT_DOCHERNIE_BASES — список ЖИВЫХ источников от install.sh (он их уже проверил); без него добавляем
# RU-зеркало (без него клиент с недоступным Парижем не мог поставить ничего). Зеркало есть только у канала bin.
if [ -n "${QWDTT_DOCHERNIE_BASES:-}" ]; then
  BASE_LIST="$QWDTT_DOCHERNIE_BASES"
elif [ "$QWDTT_CHANNEL" = bin ] && [ -n "${QWDTT_PUBLIC_BASE_URL_RU-http://45.10.247.23/bin}" ]; then
  BASE_LIST="$BASE_LIST ${QWDTT_PUBLIC_BASE_URL_RU-http://45.10.247.23/bin}"
fi
# ANTIDPI_BASES — только для проверки на тестовом роутере (кандидатский
# каталог вместо канала). В бою не задаётся: кнопка и установщик его не знают.
[ -n "${ANTIDPI_BASES:-}" ] && BASE_LIST="$ANTIDPI_BASES"

OPT=${ANTIDPI_OPT:-/opt}
T="/tmp/qwdtt-antidpi-ust.$$"
CLIENT="$OPT/bin/qwdtt"
ENG="$OPT/bin/meridian-antidpi"
CTL="$OPT/bin/meridian-antidpi-ctl"
INIT="$OPT/etc/init.d/S51meridian-antidpi"
HOOK="$OPT/etc/ndm/netfilter.d/60-meridian-antidpi.sh"
NFQ_CONF="$OPT/etc/nfqws2/nfqws2.conf"
STAMP=$(date +%Y%m%d-%H%M%S)
# Сумма ШАБЛОНА init из раздачи, по которому собран стоящий init (сам init
# отличается портами роутера, по его сумме сверять нельзя).
METKA="$OPT/etc/meridian-antidpi/.init-shablon.sha256"
# Копии из netfilter.d (свой .prev крючка, отведённый крючок nfqws2) — ВНЕ
# netfilter.d: NDM зовёт исполняемые файлы оттуда, отведённый крючок nfqws2
# там вернул бы его правила при первой пересборке.
OTVOD="$OPT/etc/meridian-antidpi/otvedeno"
kopiya() {  # $1 файл, $2 суффикс → путь копии
  case "$1" in
    */netfilter.d/*) echo "$OTVOD/$(basename "$1")$2" ;;
    *) echo "$1$2" ;;
  esac
}
QNUM=500
NFQ_MARK="0x1c9/0x1ff"
# По умолчанию — список Кота 1 (S51 на HERO), если nfqws2.conf нет.
TCP_DEF="80,443,1984,2053,2083,2087,2096,5222,8443"
UDP_DEF="443,590:600,1400,3478:3481,5349,19294:19344"
MEM_MIN_KB=20480
ZAPAS_KB=1024

say() { echo "[antidpi] $*"; }

# ---------- ЗАГРУЗЧИК — тот же, что в ustanovka-dns.sh ----------
# run_limited <секунд> <команда...> — жёсткий предел для загрузчика без своего таймаута (тот же приём, что в install.sh 5.28).
# 02.10.2026: недоступный Париж держал BusyBox wget минутами на каждом файле.
run_limited() {
  _rl_s="$1"; shift
  "$@" &
  _rl_p=$!
  (
    _rl_i=0
    while [ "$_rl_i" -lt "$_rl_s" ]; do
      sleep 1
      kill -0 "$_rl_p" 2>/dev/null || exit 0
      _rl_i=$((_rl_i + 1))
    done
    kill -TERM "$_rl_p" 2>/dev/null
    sleep 2
    kill -KILL "$_rl_p" 2>/dev/null
  ) >/dev/null 2>&1 &
  _rl_w=$!
  _rl_r=0
  wait "$_rl_p" || _rl_r=$?
  kill "$_rl_w" 2>/dev/null || true
  wait "$_rl_w" 2>/dev/null || true
  return "$_rl_r"
}
LIM_SEK=300   # предел одного файла; для манифеста skachat_baza ставит 30
SPOSOB_VYBRAN=""
odnim_sposobom() {  # $1 способ, $2 адрес, $3 куда
  rm -f "$3"
  case "$1" in
    curl)          curl -fsSL --connect-timeout 15 -m "$LIM_SEK" -o "$3" "$2" < /dev/null ;;
    "wget -T")     run_limited "$LIM_SEK" wget -q -T 300 -O "$3" "$2" < /dev/null ;;   # bb-ok: падение ловится кодом возврата, рядом вариант без -T
    "wget без -T") run_limited "$LIM_SEK" wget -q -O "$3" "$2" < /dev/null ;;
    *) return 1 ;;
  esac
  _krc=$?
  if [ "$_krc" = 0 ] && [ -s "$3" ]; then return 0; fi
  rm -f "$3"
  return 1
}
skachat() {
  if [ -n "$SPOSOB_VYBRAN" ]; then
    if odnim_sposobom "$SPOSOB_VYBRAN" "$1" "$2"; then return 0; fi
    SPOSOB_VYBRAN=""
  fi
  for _sp in curl "wget -T" "wget без -T"; do
    if [ "$_sp" = curl ] && ! command -v curl >/dev/null 2>&1; then continue; fi
    if odnim_sposobom "$_sp" "$1" "$2"; then SPOSOB_VYBRAN="$_sp"; return 0; fi
  done
  return 1
}
skachat_baza() {
  # Манифест — проба источника: недоступный (не ответил за 30 с) выкидываем из списка, остальные файлы к нему не ходят.
  _bz_man=0; [ "$1" = SHA256SUMS ] && _bz_man=1
  _bz_lim="$LIM_SEK"; [ "$_bz_man" = 1 ] && LIM_SEK=30
  _bz_ost=""; _bz_ok=1
  for _baza in $BASE_LIST; do
    if [ "$_bz_ok" = 0 ]; then _bz_ost="$_bz_ost $_baza"; continue; fi
    if skachat "$_baza/$1" "$2"; then _bz_ok=0; _bz_ost="$_bz_ost $_baza"; continue; fi
    [ "$_bz_man" = 1 ] && say "    источник $_baza не отвечает — дальше его не использую"
    [ "$_bz_man" = 1 ] || _bz_ost="$_bz_ost $_baza"
  done
  LIM_SEK="$_bz_lim"
  [ "$_bz_man" = 1 ] && BASE_LIST="${_bz_ost# }"
  return "$_bz_ok"
}
manifest_sha() { awk -v n="$1" '$2 == n {print $1}' "$T/SHA256SUMS" | head -1; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
kb() { _b=$(wc -c < "$1" 2>/dev/null); echo $(( (${_b:-0} + 1023) / 1024 )); }
svobodno_kb() {
  _s=$(df -Pk "$OPT" 2>/dev/null | awk 'NR==2{print $4}')
  case "$_s" in ''|*[!0-9]*) _s=$(df -k "$OPT" 2>/dev/null | awk 'NR==2{print $4}') ;; esac
  echo "$_s"
}

# ---------- АРХИТЕКТУРА — по ELF, как в ustanovka-dns.sh ----------
opoznat_arch() {
  _a=""; ARCH=""; ARCH_ISTOCHNIK=""
  for _f in "$CLIENT" "$OPT/bin/qwdtt-web" /bin/busybox /bin/sh /bin/cat; do
    [ -f "$_f" ] || continue
    head -c 4 "$_f" 2>/dev/null | grep -q 'ELF' || continue
    _k=$(dd if="$_f" bs=1 skip=4 count=1 2>/dev/null)
    _d=$(dd if="$_f" bs=1 skip=5 count=1 2>/dev/null)
    _m=$(dd if="$_f" bs=1 skip=18 count=1 2>/dev/null)
    _m2=$(dd if="$_f" bs=1 skip=19 count=1 2>/dev/null)
    if [ "$_d" = "$(printf '\2')" ]; then
      if [ "$_m2" = "$(printf '\10')" ]; then _a=mips; fi
    else
      if [ "$_k" = "$(printf '\2')" ]; then
        if [ "$_m" = "$(printf '\267')" ]; then _a=arm64; fi
      else
        if [ "$_m" = "$(printf '\10')" ]; then _a=mipsle; fi
        if [ "$_m" = "$(printf '\50')" ]; then _a=armv7; fi
      fi
    fi
    if [ -n "$_a" ]; then ARCH="$_a"; ARCH_ISTOCHNIK="$_f"; return 0; fi
  done
  case "$(uname -m 2>/dev/null)" in
    aarch64)       ARCH=arm64; ARCH_ISTOCHNIK="uname -m"; return 0 ;;
    armv7*|armv6*) ARCH=armv7; ARCH_ISTOCHNIK="uname -m"; return 0 ;;
  esac
  return 1
}

# ---------- ОТКАТ: стек отмен, только mv ----------
UNDO="$T/undo"
add() { echo "$*" >> "$UNDO"; }
ubrat_t() { case "$T" in /tmp/qwdtt-antidpi-ust.*) rm -rf "$T" ;; esac; }
otkat() {
  trap '' INT TERM HUP
  say "КРАСНОЕ: $1"
  say "ОТКАТ (только mv):"
  if [ -s "$UNDO" ]; then
    awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$UNDO" > "$UNDO.r"
    while read -r _op _a _b; do
      case "$_op" in
        stop_our)  [ -x "$INIT" ] && "$INIT" stop >/dev/null 2>&1; say "  наш анти-DPI остановлен" ;;
        start_our) [ -x "$INIT" ] && "$INIT" start >/dev/null 2>&1; say "  прежний анти-DPI запущен обратно" ;;
        mv)        [ -e "$_a" ] && mv -f "$_a" "$_b" && say "  mv $_a -> $_b" ;;
        rm)        rm -f "$_a" && say "  снят $_a" ;;
        start_old) ( trap '' HUP; sh "$_a" start ) </dev/null >/dev/null 2>&1; say "  запущен обратно: $_a start" ;;
      esac
    done < "$UNDO.r"
  fi
  say "ИТОГ: НЕ ЗЕЛЁНОЕ — $1"
  ubrat_t
  exit 1
}
otkaz() { say "ИТОГ: ОТКАЗ, ничего не менял: $*"; [ "${IPT_POSTAVLEN:-0}" = 1 ] && { opkg remove iptables >/dev/null 2>&1; say "  (поставленный мной iptables убран обратно)"; }; ubrat_t; exit 1; }

if [ $# -gt 0 ]; then
  echo "[antidpi] ОТКАЗ: исполнитель не принимает аргументов."
  exit 2
fi
mkdir -p "$T" 2>/dev/null && [ -d "$T" ] || { echo "[antidpi] ОТКАЗ: нет рабочего каталога $T"; exit 1; }
: > "$UNDO"
trap 'otkaz "прервано до начала"' INT TERM HUP

say "=== УСТАНОВКА анти-DPI (канал $QWDTT_CHANNEL), $(date '+%F %T') ==="

# ---------- 1. АРХИТЕКТУРА ----------
opoznat_arch || otkaz "архитектуру не опознать (uname -m: $(uname -m 2>/dev/null))"
say "арх: $ARCH (по $ARCH_ISTOCHNIK)"

# ---------- 2. ПАМЯТЬ ----------
MEM=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
case "$MEM" in ''|*[!0-9]*) otkaz "не прочитать MemAvailable из /proc/meminfo" ;; esac
[ "$MEM" -ge "$MEM_MIN_KB" ] || otkaz "мало памяти: MemAvailable $((MEM / 1024)) МБ, нужно не меньше $((MEM_MIN_KB / 1024)) МБ"
say "память: доступно $((MEM / 1024)) МБ"

# ---------- 3. МОДУЛИ ЯДРА NFQUEUE — делом, пробной цепочкой ----------
IPT_POSTAVLEN=0
if ! command -v iptables >/dev/null 2>&1; then
  say "iptables не найден — ставлю пакет Entware (opkg install iptables)"
  command -v opkg >/dev/null 2>&1 || otkaz "нет iptables, и нет opkg, чтобы его поставить"
  _sv=$(svobodno_kb); case "$_sv" in ''|*[!0-9]*) _sv=0 ;; esac
  [ "$_sv" -ge 4096 ] || otkaz "нет iptables, а места на $OPT мало для его установки: свободно $((_sv / 1024)) МБ, нужно не меньше 4 МБ"
  LIM_SEK=120; run_limited 120 opkg update >/dev/null 2>&1 || say "  opkg update не прошёл — пробую ставить по имеющемуся списку"
  LIM_SEK=300
  run_limited 300 opkg install iptables || say "  opkg install iptables вернул ошибку"
  command -v iptables >/dev/null 2>&1 || otkaz "iptables не поставился из Entware (причина — строкой выше)"
  IPT_POSTAVLEN=1
  say "iptables установлен"
fi
# МОДУЛИ ЯДРА (05.10.2026): после обновления прошивки Keenetic перестал сам подгружать xt_multiport — файл модуля
# на месте, но правило с -m multiport не встаёт («No chain/target/match»), и анти-DPI молча не получает трафик
# (замерено на HERO). Грузим нужное сами: modprobe, а нет его — insmod из /lib/modules.
zagruzit_moduli() {
  for _m in xt_multiport xt_mark xt_connbytes xt_NFQUEUE nfnetlink_queue; do
    grep -q "^$_m " /proc/modules 2>/dev/null && continue
    modprobe "$_m" 2>/dev/null || insmod "/lib/modules/$(uname -r)/$_m.ko" 2>/dev/null || true
  done
}

zagruzit_moduli
iptables -t mangle -F MADPI_T 2>/dev/null; iptables -t mangle -X MADPI_T 2>/dev/null
if iptables -t mangle -N MADPI_T 2>/dev/null && \
   iptables -t mangle -A MADPI_T -p tcp -m mark ! --mark "$NFQ_MARK" -m multiport --dports 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null; then
  iptables -t mangle -F MADPI_T 2>/dev/null; iptables -t mangle -X MADPI_T 2>/dev/null
  say "модули ядра NFQUEUE: есть"
else
  iptables -t mangle -F MADPI_T 2>/dev/null; iptables -t mangle -X MADPI_T 2>/dev/null
  # Компонент ставится только через прошивку Keenetic (с перезагрузкой) — сами не ставим, говорим, как (04.10.2026).
  say "Чтобы анти-DPI заработал, включите компонент прошивки:"
  say "  веб-интерфейс роутера → «Управление» → «Параметры системы» → «Изменить набор компонентов»"
  say "  → отметьте «Модули ядра подсистемы Netfilter» → «Установить обновление» (роутер перезагрузится)."
  say "  После перезагрузки нажмите в панели Meridian «Обновить веб-панель» — анти-DPI доустановится сам."
  say "  Клиент, панель и DNS работают и без анти-DPI."
  otkaz "нужен компонент прошивки «Модули ядра подсистемы Netfilter» (правило NFQUEUE не встаёт)"
fi

# ---------- 4. ФАЙЛЫ ИЗ РАЗДАЧИ, сверка по SHA256SUMS ----------
skachat_baza SHA256SUMS "$T/SHA256SUMS" || otkaz "не скачать SHA256SUMS — сверять нечем"
# УЖЕ СТОИТ ровно это — решаем по манифесту, ДО скачивания: исполнитель
# зовётся каждым нажатием «Обновить веб-панель» (в KOMPONENTY «-»), качать
# каждый раз 2–3 МБ движка ради сверки незачем.
if [ -n "$(manifest_sha "meridian-antidpi-$ARCH")" ] && \
   [ "$(sha "$ENG")" = "$(manifest_sha "meridian-antidpi-$ARCH")" ] && \
   [ "$(sha "$CTL")" = "$(manifest_sha meridian-antidpi-ctl-entware)" ] && \
   [ "$(cat "$METKA" 2>/dev/null)" = "$(manifest_sha meridian-antidpi-init-entware)" ] && \
   [ -n "$(manifest_sha meridian-antidpi-hook-entware)" ] && \
   [ "$(sha "$HOOK")" = "$(manifest_sha meridian-antidpi-hook-entware)" ] && [ -x "$HOOK" ] && \
   [ -x "$INIT" ] && pidof meridian-antidpi >/dev/null 2>&1; then
  say "ИТОГ: анти-DPI уже стоит этой версии и работает — ничего не менял"
  ubrat_t
  exit 0
fi
for _p in "meridian-antidpi-$ARCH:eng" "meridian-antidpi-ctl-entware:ctl" "meridian-antidpi-init-entware:init" "meridian-antidpi-hook-entware:hook"; do
  _imya=${_p%%:*}; _kuda=${_p##*:}
  _want=$(manifest_sha "$_imya")
  [ -n "$_want" ] || otkaz "в SHA256SUMS нет строки для $_imya"
  skachat_baza "$_imya" "$T/$_kuda" || otkaz "не скачать $_imya"
  [ "$(sha "$T/$_kuda")" = "$_want" ] || otkaz "сумма $_imya не сошлась с SHA256SUMS"
  say "  $_imya: $(kb "$T/$_kuda") КБ, сумма сошлась"
done
head -c 4 "$T/eng" | grep -q ELF || otkaz "движок из раздачи не ELF"
grep -q '^	rules)' "$T/init" || otkaz "в шаблоне init нет команды rules — крючку NDM звать нечего"

# ---------- 5. ПОРТЫ — из nfqws2.conf, без 49152:65535 (Кот 1) ----------
TCP=""; UDP=""; OTKUDA="по умолчанию (nfqws2.conf нет)"
if [ -f "$NFQ_CONF" ]; then
  TCP=$(sed -n "s/^TCP_PORTS=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}.*/\1/p" "$NFQ_CONF" | head -1)
  UDP=$(sed -n "s/^UDP_PORTS=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}.*/\1/p" "$NFQ_CONF" | head -1)
  OTKUDA="из $NFQ_CONF"
fi
[ -n "$TCP" ] || { TCP=$TCP_DEF; [ -f "$NFQ_CONF" ] && OTKUDA="$OTKUDA (TCP_PORTS нет — по умолчанию)"; }
[ -n "$UDP" ] || UDP=$UDP_DEF
UDP=$(echo "$UDP" | awk -F, '{ o=""; for (i=1;i<=NF;i++) if ($i != "" && $i != "49152:65535") o = o (o=="" ? "" : ",") $i; print o }')
[ -n "$UDP" ] || UDP=$UDP_DEF
case "$TCP$UDP" in *[!0-9,:]*) otkaz "порты разобраны неверно: TCP «$TCP», UDP «$UDP»" ;; esac
say "порты $OTKUDA: TCP $TCP; UDP $UDP"

# Свой init — шаблон Кота 1, подставлены порты этого роутера.
sed -e "s/^NFQ_TCP_PORTS=.*/NFQ_TCP_PORTS=\"$TCP\"/" -e "s/^NFQ_UDP_PORTS=.*/NFQ_UDP_PORTS=\"$UDP\"/" "$T/init" > "$T/init.gotov" \
  || otkaz "не подготовить init"
grep -q "^NFQ_TCP_PORTS=\"$TCP\"$" "$T/init.gotov" && grep -q "^NFQ_UDP_PORTS=\"$UDP\"$" "$T/init.gotov" \
  || otkaz "в шаблоне init нет строк NFQ_TCP_PORTS=/NFQ_UDP_PORTS= — порты не подставить"

# ---------- 7. МЕСТО ----------
NADO=$(( $(kb "$T/eng") + $(kb "$T/ctl") + $(kb "$T/init.gotov") + $(kb "$T/hook") + ZAPAS_KB ))
EST=$(svobodno_kb)
case "$EST" in ''|*[!0-9]*) otkaz "место не проверить (df «$EST»)" ;; esac
[ "$EST" -ge "$NADO" ] || otkaz "мало места: нужно $NADO КБ (с запасом 1 МБ), свободно $EST КБ"
say "место: нужно $NADO КБ, свободно $EST КБ"

trap 'otkat "прервано сигналом"' INT TERM HUP

# ---------- 8. nfqws2 — остановить и отвести (не удалять) ----------
NFQ_FILES=""
if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -q '^nfqws2-keenetic '; then
  NFQ_FILES=$(opkg files nfqws2-keenetic 2>/dev/null | grep -E '/init\.d/|/netfilter\.d/' | grep 'nfqws2')
fi
if pidof nfqws2 >/dev/null 2>&1 && [ -z "$NFQ_FILES" ]; then
  otkaz "nfqws2 запущен, но пакет nfqws2-keenetic не найден в opkg — чем его остановить, не знаю; разбираться руками"
fi
for _f in $NFQ_FILES; do
  [ -f "$_f" ] || continue
  case "$_f" in
    */init.d/*)
      say "nfqws2: останавливаю $_f"
      sh "$_f" stop >/dev/null 2>&1
      add start_old "$_f"
      ;;
  esac
done
_i=0
while pidof nfqws2 >/dev/null 2>&1 && [ "$_i" -lt 10 ]; do sleep 1; _i=$((_i + 1)); done
if pidof nfqws2 >/dev/null 2>&1; then
  kill -KILL $(pidof nfqws2) 2>/dev/null; sleep 1
  pidof nfqws2 >/dev/null 2>&1 && otkat "nfqws2 не остановился даже KILL'ом"
fi
mkdir -p "$OTVOD" 2>/dev/null
for _f in $NFQ_FILES; do
  [ -f "$_f" ] || continue
  _k=$(kopiya "$_f" ".PERED-ANTIDPI-$STAMP")
  mv -f "$_f" "$_k" && add mv "$_k" "$_f" \
    || otkat "не отвести $_f"
  say "nfqws2: отведён $_f -> $_k"
done
# Прошлые прогоны (28–29.09) отводили крючок nfqws2 рядом, в netfilter.d, —
# выносим оттуда.
for _f in "$OPT"/etc/ndm/netfilter.d/*.PERED-ANTIDPI-*; do
  [ -f "$_f" ] || continue
  _k="$OTVOD/$(basename "$_f")"
  mv -f "$_f" "$_k" && add mv "$_k" "$_f" || otkat "не вынести $_f из netfilter.d"
  say "вынесен из netfilter.d: $_f -> $_k"
done

# ---------- 9. ПОДМЕНА (mv, прежнее — в сторону) ----------
# Работал прежний анти-DPI — в откате его запустить обратно (стек отмен
# обратный: start_our выполнится последним, после возврата файлов и stop_our).
pidof meridian-antidpi >/dev/null 2>&1 && add start_our
if [ -x "$INIT" ]; then "$INIT" stop >/dev/null 2>&1; fi
add stop_our
mkdir -p "$OPT/etc/init.d" "$OPT/bin" "$OPT/var/log" "$(dirname "$HOOK")" 2>/dev/null
for _p in "eng:$ENG:755" "ctl:$CTL:755" "init.gotov:$INIT:755" "hook:$HOOK:755"; do
  _iz=${_p%%:*}; _r=${_p#*:}; _v=${_r%%:*}; _m=${_r##*:}
  # ОДНО ПОКОЛЕНИЕ КОПИЙ, как во всём проекте: место на роутерах тесное
  # (HERO, 28.09.2026 — 4.9 МБ), копии каждого обновления копились бы.
  for _st in "$_v".prev-* "$(kopiya "$_v" .prev-)"*; do [ -f "$_st" ] && rm -f "$_st"; done
  if [ -f "$_v" ]; then
    _k=$(kopiya "$_v" ".prev-$STAMP")
    mv -f "$_v" "$_k" && add mv "$_k" "$_v" || otkat "не отвести прежний $_v"
  else
    add rm "$_v"
  fi
  chmod "$_m" "$T/$_iz"
  mv -f "$T/$_iz" "$_v" || otkat "не поставить $_v"
done
say "файлы на месте: $ENG, $CTL, $INIT, $HOOK"
mkdir -p "$(dirname "$METKA")" 2>/dev/null
[ -f "$METKA" ] && { mv -f "$METKA" "$METKA.prev-$STAMP" && add mv "$METKA.prev-$STAMP" "$METKA"; } || add rm "$METKA"
manifest_sha meridian-antidpi-init-entware > "$METKA"

# ---------- 10. ЗАПУСК И ПРОВЕРКА ----------
proverka() {
  _i=0
  while ! pidof meridian-antidpi >/dev/null 2>&1; do
    _i=$((_i + 1)); [ "$_i" -ge 10 ] && { PRICHINA="движок не поднялся за 10 с (см. $OPT/var/log/meridian-antidpi.log)"; return 1; }
    sleep 1
  done
  # Вид правила — дело init (окно connbytes 1:12 с 06.10, 1:8 с 08.10, без него — если модуля нет). Проверяем ФАКТ:
  # по одному правилу TCP и UDP в нашу очередь, а не точное написание (08.10.2026 — урок 06.10: новый вид правила
  # откатывал всем установку).
  _ns=$(iptables -t mangle -S FORWARD 2>/dev/null | grep -- "--queue-num $QNUM")
  echo "$_ns" | grep -q -- "-p tcp" || { PRICHINA="правило TCP в очередь $QNUM не встало"; return 1; }
  echo "$_ns" | grep -q -- "-p udp" || { PRICHINA="правило UDP в очередь $QNUM не встало"; return 1; }
  # Цепочки прошивки _NDM_* (например _NDM_OUTPUT_DELAY → очередь 64511, собственная служба Keenetic) — не чужой
  # обходчик: клиент 3286bdaa 06.10.2026 откатывался из-за неё.
  _chuzhie=$(iptables-save -t mangle 2>/dev/null | grep NFQUEUE | grep -v -- '^-A _NDM_' | grep -v -- "--queue-num $QNUM " | grep -vc -- "--queue-num $QNUM$")
  [ "${_chuzhie:-0}" = 0 ] || { PRICHINA="в mangle остались чужие правила NFQUEUE ($_chuzhie) — крючок nfqws2 не отведён"; return 1; }
  _nashi=$(iptables-save -t mangle 2>/dev/null | grep -c -e "--queue-num $QNUM " -e "--queue-num $QNUM$")
  [ "$_nashi" = 2 ] || { PRICHINA="правил очереди $QNUM в mangle $_nashi, а должно быть ровно 2"; return 1; }
  return 0
}
# Приёмка крючка NDM: снять наши правила, как это делает пересборка netfilter,
# позвать крючок так, как зовёт NDM, — правила обязаны вернуться.
proverka_kryuchka() {
  # снять ВСЕ наши правила очереди, какого бы вида они ни были (имитация стирания NDM)
  _i=0
  while iptables -t mangle -S FORWARD 2>/dev/null | grep -q -- "--queue-num $QNUM" && [ "$_i" -lt 20 ]; do
    _r=$(iptables -t mangle -S FORWARD | grep -- "--queue-num $QNUM" | head -1 | sed 's/^-A /-D /')
    eval iptables -t mangle $_r 2>/dev/null || break
    _i=$((_i + 1))
  done
  iptables -t mangle -D FORWARD -p udp -m mark ! --mark "$NFQ_MARK" -m multiport --dports "$UDP" -m connbytes --connbytes 1:12 --connbytes-dir original --connbytes-mode packets -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null
  _bez=$(iptables-save -t mangle 2>/dev/null | grep -c -e "--queue-num $QNUM " -e "--queue-num $QNUM$")
  [ "$_bez" = 0 ] || { PRICHINA="правила очереди $QNUM не снялись для проверки крючка ($_bez)"; return 1; }
  type=iptables table=mangle "$HOOK" >/dev/null 2>&1
  # 08.10.2026: на HERO первый прогон после смены init поймал правила не сразу — до трёх попыток с паузой 1 с.
  _pk=0
  until proverka; do
    _pk=$((_pk + 1)); [ "$_pk" -ge 3 ] && { PRICHINA="крючок NDM не вернул правила: $PRICHINA"; return 1; }
    sleep 1
  done
  return 0
}
"$INIT" start >/dev/null 2>&1
proverka || otkat "$PRICHINA"
say "запущен, правила очереди $QNUM на месте, чужих NFQUEUE нет"
# Перезапуск — код 0 значит «пережило перезапуск».
"$INIT" restart >/dev/null 2>&1
proverka || otkat "после перезапуска: $PRICHINA"
say "пережил перезапуск"
proverka_kryuchka || otkat "$PRICHINA"
say "крючок NDM: правила сняты и возвращены крючком, их снова 2"

trap '' INT TERM HUP
# Зелёное: копия, побайтно равная поставленному, откатывать не к чему — место
# на роутерах тесное (HERO 29.09: движок 2.7 МБ лежал дважды).
for _v in "$ENG" "$CTL" "$INIT" "$HOOK"; do
  _k=$(kopiya "$_v" ".prev-$STAMP")
  [ -f "$_k" ] && [ "$(sha "$_k")" = "$(sha "$_v")" ] && rm -f "$_k"
done
if [ -n "$NFQ_FILES" ]; then
  say "nfqws2 остановлен и отведён (файлы *.PERED-ANTIDPI-$STAMP, крючок — в $OTVOD), пакет не удалён"
fi
say "ИТОГ: ЗЕЛЁНОЕ — анти-DPI стоит и работает (очередь $QNUM, порты $OTKUDA)"
ubrat_t
exit 0
