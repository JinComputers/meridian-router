#!/bin/sh
# ustanovka-out.sh — включить в ЧЁРНОМ режиме слой «DNS самого роутера идёт в туннель» (команда движка `meridian-route out`).
#
# ЗАЧЕМ. Список доменов (нейросети и пр.) резолвит наш meridian-dns через «чистые» DNS 1.1.1.1 и 9.9.9.9. У ряда провайдеров
# эти адреса режутся с перебоями; запасного пути у списка нет, и имена из списка получают SERVFAIL (клиент 2, 18.10.2026).
# Слой `out` помечает запросы самого роутера к этим адресам меткой туннеля — они идут в туннель, а не мимо него.
# Решение владельца 18.10.2026: «только DNS в чёрном режиме через туннель», всем.
#
# ЧТО ДЕЛАЕТ. Keenetic/Entware (`meridian-route out`, iptables) и, с 5.69, OpenWrt (`meridian-mode out`, nft: хост-маршруты чистых
# резолверов в туннель + сторож out_guard, кандидат 1114 Кота 1). Включает слой, ПРОВЕРЯЕТ, что имя из списка по-прежнему резолвится, и только
# тогда подтверждает. Не проверилось — слой снимается, всё как было. На обрыве скрипта (trap) неподтверждённый слой тоже снимается:
# у движка 1.110/1.111 после перезагрузки неподтверждённый слой остаётся навсегда (дыра, её чинит 1.112), поэтому оставлять его
# в состоянии «ждёт подтверждения» дольше нашего прогона нельзя.
#
# КОД ВЫХОДА: всегда 0 — это дополнение, установка клиента и панели от него не зависит. Итог — одна строка на экране.
# ПЕРЕМЕННЫЕ ДЛЯ СТЕНДА: QWDTT_MR (движок), QWDTT_DNSBIN (meridian-dns), QWDTT_DNSCONF, QWDTT_OUT_POLL (число опросов, 6),
# QWDTT_OUT_SLEEP (пауза между опросами, 2), QWDTT_OUT_CONFIRM (окно подтверждения, 120).
# OpenWrt: QWDTT_MODE (meridian-mode, /usr/sbin/meridian-mode), QWDTT_OUT_TUNWAIT (сколько секунд ждать подъёма туннеля, 20),
# QWDTT_FORCE_OWRT=1 (считать платформой OpenWrt без nft — для стенда).
set -u

MR="${QWDTT_MR:-/opt/bin/meridian-route}"
MODE_OWRT="${QWDTT_MODE:-/usr/sbin/meridian-mode}"
TUNWAIT="${QWDTT_OUT_TUNWAIT:-20}"
OWRT=0
DNSBIN="${QWDTT_DNSBIN:-/opt/bin/meridian-dns}"
DNSCONF="${QWDTT_DNSCONF:-/opt/etc/meridian/meridian-dns.yaml}"
POLL="${QWDTT_OUT_POLL:-6}"
PAUSE="${QWDTT_OUT_SLEEP:-2}"
CONFIRM="${QWDTT_OUT_CONFIRM:-120}"

say() { echo "[meridian] $*"; }

ARMED=0
cleanup() {
	trap '' INT TERM HUP
	if [ "$ARMED" = 1 ]; then
		# Слой включён и НЕ подтверждён: не оставляем. `out off` идемпотентна.
		"$MR" out off < /dev/null >/dev/null 2>&1
		ARMED=0
	fi
}
trap 'cleanup; exit 0' INT TERM HUP
trap 'cleanup' EXIT

# --- 0. Есть ли чем и где включать --------------------------------------------------------------------------------------
# Платформа: OpenWrt — если есть таблица nft meridian (или стенд просит). Тогда движок — meridian-mode, а не meridian-route.
if [ "${QWDTT_FORCE_OWRT:-0}" = "1" ]; then
	OWRT=1
elif command -v nft >/dev/null 2>&1 && nft list table inet meridian >/dev/null 2>&1; then
	OWRT=1
fi
if [ "$OWRT" = 1 ]; then
	MR="$MODE_OWRT"
	[ -x "$MR" ] || exit 0
	# Движок без слоя out (старый meridian-mode) — молча: слой появится вместе с обновлением скриптов.
	"$MR" out show < /dev/null >/dev/null 2>&1 || exit 0
else
	[ -x "$MR" ] || exit 0
fi

OUTSHOW=$("$MR" out show < /dev/null 2>/dev/null) || exit 0
case "$OUTSHOW" in
	*out=on*)
		case "$OUTSHOW" in
			*out_confirmed=yes*) exit 0 ;;   # уже включён и подтверждён — ничего не делаем
		esac
		# Включён, но НЕ подтверждён (остаток прежнего прогона, дыра после перезагрузки): проверим и подтвердим либо снимем.
		ARMED=1
		SKIP_ON=1
		;;
	*) SKIP_ON=0 ;;
esac

if [ "$OWRT" = 1 ]; then
	STATUS=$("$MR" status --machine < /dev/null 2>/dev/null) || exit 0
else
	STATUS=$("$MR" status < /dev/null 2>/dev/null) || exit 0
fi
val() { printf '%s\n' "$STATUS" | sed -n "s/^$1=//p" | head -n 1; }

# --- 1. Ворота: только чёрный подтверждённый режим, туннель поднят ----------------------------------------------------
if [ "$SKIP_ON" = 0 ]; then
	[ "$(val mode)" = "black" ] || exit 0
	[ "$(val confirmed)" = "yes" ] || exit 0
	if [ "$OWRT" = 1 ]; then
		# На OpenWrt туннель поднимается позже нас (сразу после установки клиента): подождём ограниченно.
		_w=0
		while ! ip -o link show meridian 2>/dev/null | grep -q '<[^>]*UP'; do
			[ "$_w" -ge "$TUNWAIT" ] && break
			sleep 1; _w=$((_w + 1))
		done
		if ! ip -o link show meridian 2>/dev/null | grep -q '<[^>]*UP'; then
			say "DNS списка через туннель: включится позже (туннель сейчас не поднят)"
			exit 0
		fi
	elif [ "$(val tunnel_state)" != "up" ] || [ "$(val iface_present)" != "yes" ]; then
		say "DNS списка через туннель: включится позже (туннель сейчас не поднят)"
		exit 0
	fi
	# IPv6-маршрут по умолчанию: слой его не покрывает.
	if command -v ip >/dev/null 2>&1; then
		if [ -n "$(ip -6 route show default 2>/dev/null | head -n 1)" ]; then
			say "DNS списка через туннель не включён: у роутера есть IPv6"
			exit 0
		fi
	fi
fi

# --- 2. Сервер DNS: жив, версия не старше 0.45, адрес прослушивания, имя для проверки ---------------------------------
[ -x "$DNSBIN" ] || exit 0
DS=$("$DNSBIN" -config "$DNSCONF" status < /dev/null 2>/dev/null) || exit 0
dval() { printf '%s\n' "$DS" | sed -n "s/^$1=//p" | head -n 1; }
[ "$(dval server_process)" = "alive" ] || { say "DNS списка через туннель: сервер DNS не отвечает, слой не включаю"; exit 0; }
DNSVER=$(dval server_version_running)
[ -n "$DNSVER" ] || DNSVER=$(dval version)
vmaj=${DNSVER%%.*}; vmin=${DNSVER#*.}; vmin=${vmin%%.*}
case "$vmaj$vmin" in
	*[!0-9]*|"") say "DNS списка через туннель: версия сервера DNS не прочиталась, слой не включаю"; exit 0 ;;
esac
if [ "$vmaj" -eq 0 ] && [ "$vmin" -lt 45 ]; then
	say "DNS списка через туннель: обновите сервер DNS (нужна 0.45 или новее), слой не включаю"
	exit 0
fi
LISTEN=$(dval listen)           # 192.168.88.8:5453
ADDR=${LISTEN%:*}
[ "$OWRT" = 1 ] && [ -z "$ADDR" ] && ADDR=127.0.0.1
[ -n "$ADDR" ] || exit 0
# Имя для проверки: первое доменное правило списка (то, что человек видит у себя). Список пуст — проверять нечего.
NAME=$(printf '%s\n' "$DS" | sed -n 's/^rule\.[^.]*\.domain=//p' | head -n 1)
[ -n "$NAME" ] || exit 0

# --- 3. Включаем с окном самоотката -----------------------------------------------------------------------------------------
if [ "$SKIP_ON" = 0 ]; then
	ONOUT=$("$MR" out on --confirm "$CONFIRM" < /dev/null 2>&1)
	ONRC=$?
	if [ "$ONRC" != 0 ]; then
		REASON=$(printf '%s\n' "$ONOUT" | grep -m1 '^ОТКАЗ' || true)
		[ -n "$REASON" ] || REASON="код $ONRC"
		say "DNS списка через туннель не включён: $REASON"
		exit 0
	fi
	ARMED=1
fi

# --- 4. Проверка: имя резолвится И пакеты помечены (после `out on` пул DNS сбрасывается и переподключается через туннель) ---
OKRES=0
i=0
while [ "$i" -lt "$POLL" ]; do
	i=$((i + 1))
	sleep "$PAUSE"
	RES=$(nslookup "$NAME" "$ADDR" < /dev/null 2>&1) || RES=""
	if [ "$OWRT" = 1 ]; then
		# «Помечено» на OpenWrt = хост-маршрут чистого резолвера действительно ведёт в туннель.
		MARKED=0
		_r=$("$MR" out show < /dev/null 2>/dev/null | sed -n 's/^out_resolvers=//p' | awk '{print $1; exit}')
		if [ -n "$_r" ] && ip route get "$_r" 2>/dev/null | grep -q 'dev meridian'; then MARKED=1; fi
	else
		MARKED=$("$MR" status < /dev/null 2>/dev/null | sed -n 's/^selfdns_marked=//p' | head -n 1)
	fi
	case "$MARKED" in ''|*[!0-9]*) MARKED=0 ;; esac
	case "$RES" in
		*"can't resolve"*|*SERVFAIL*|*"Temporary failure"*|"") continue ;;
	esac
	if [ "$MARKED" -gt 0 ]; then OKRES=1; break; fi
done

if [ "$OKRES" = 1 ]; then
	"$MR" out confirm < /dev/null >/dev/null 2>&1
	if [ "$?" = 0 ]; then
		ARMED=0
		say "DNS списка идёт через туннель: включено"
		exit 0
	fi
fi

"$MR" out off < /dev/null >/dev/null 2>&1
ARMED=0
say "DNS списка через туннель не включён: имена списка не ответили через туннель, всё оставлено как было"
exit 0
