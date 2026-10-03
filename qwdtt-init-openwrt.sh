#!/bin/sh /etc/rc.common
START=99; STOP=10; USE_PROCD=1
CONF="/opt/etc/qwdtt/qwdtt.conf"; BIN="/opt/bin/qwdtt"
LOG="/opt/var/log/qwdtt.log"
WG="/opt/etc/qwdtt/wg.conf"
TIMESYNCF="/opt/var/run/qwdtt.timesync"
TIME_SYNC_INTERVAL=3600
LOG_MAX_KB=512

# NTP по чистым IP (без DNS) — на случай, если DoT/DoH не может пройти
# TLS-проверку из-за неверного времени.
NTP_IPS="132.163.97.1 132.163.97.2 132.163.97.3 162.159.200.1 85.21.78.8"
NTP_HOSTS="ru.pool.ntp.org pool.ntp.org time.google.com"

rotate_log() {
	[ -f "$LOG" ] || return 0
	SIZE_KB=$(( $(wc -c < "$LOG" 2>/dev/null || echo 0) / 1024 ))
	if [ "$SIZE_KB" -gt "$LOG_MAX_KB" ] 2>/dev/null; then
		# ВАЖНО: обрезаем файл НА МЕСТЕ, а не подменяем его через mv.
		# Клиент запущен как `"$BIN" ... >> "$LOG"` и держит открытый
		# дескриптор на конкретный inode. После mv его вывод продолжает
		# уходить в УДАЛЁННЫЙ файл: в логе тишина до самого перезапуска
		# клиента, а место на флеше занято невидимо (du не видит, df
		# видит). Ровно так получилась дыра 22:00-08:39 в ночь на
		# 14.08.2026 при полностью живом туннеле.
		tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && cat "$LOG.tmp" > "$LOG"
		rm -f "$LOG.tmp"
		echo "$(date): лог обрезан (был ${SIZE_KB}KB)" >> "$LOG"
	fi
}

sync_time_if_needed() {
	YEAR=$(date +%Y 2>/dev/null)
	if [ -n "$YEAR" ] && [ "$YEAR" -ge 2024 ] 2>/dev/null; then
		return 0
	fi
	echo "$(date): системное время неверное (год=$YEAR), синхронизирую" >> "$LOG"
	command -v ntpd >/dev/null 2>&1 || { echo "$(date): ntpd не найден" >> "$LOG"; return 1; }
	for ip in $NTP_IPS; do
		ntpd -n -q -p "$ip" >/dev/null 2>&1
		Y2=$(date +%Y 2>/dev/null)
		if [ -n "$Y2" ] && [ "$Y2" -ge 2024 ] 2>/dev/null; then
			echo "$(date): время синхронизировано по IP $ip" >> "$LOG"; return 0
		fi
	done
	for srv in $NTP_HOSTS; do
		ntpd -n -q -p "$srv" >/dev/null 2>&1
		Y2=$(date +%Y 2>/dev/null)
		if [ -n "$Y2" ] && [ "$Y2" -ge 2024 ] 2>/dev/null; then
			echo "$(date): время синхронизировано по домену $srv" >> "$LOG"; return 0
		fi
	done
	echo "$(date): синхронизация не удалась" >> "$LOG"; return 1
}

# extract_wg_from_log / capture_wg_config — см. подробный комментарий в
# entware-версии скрипта. Кратко: лог многословный и быстро ротируется,
# поэтому блок конфига нужно ловить сразу после старта, а не искать в
# логе постфактум.
extract_wg_from_log() {
	[ -f "$LOG" ] || return 1
	PRIV=$(sed -n 's/.*[[:space:]]PrivateKey[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LOG" | tail -1)
	ADDR=$(sed -n 's/.*[[:space:]]Address[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LOG" | tail -1)
	PUB=$(sed -n 's/.*[[:space:]]PublicKey[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LOG" | tail -1)
	ALLOWED=$(sed -n 's/.*[[:space:]]AllowedIPs[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LOG" | tail -1)
	ENDPOINT=$(sed -n 's/.*[[:space:]]Endpoint[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$LOG" | tail -1)
	if [ -z "$PRIV" ] || [ -z "$ADDR" ] || [ -z "$PUB" ] || [ -z "$ENDPOINT" ]; then
		return 1
	fi
	[ -z "$ALLOWED" ] && ALLOWED="0.0.0.0/0"
	printf '[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = 1.1.1.1\nMTU = 1280\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s\nEndpoint = %s\nPersistentKeepalive = 25\n' \
		"$PRIV" "$ADDR" "$PUB" "$ALLOWED" "$ENDPOINT"
	return 0
}

capture_wg_config() {
	i=0
	while [ "$i" -lt 30 ]; do
		CFG=$(extract_wg_from_log)
		if [ -n "$CFG" ]; then
			echo "$CFG" > "$WG" 2>/dev/null
			echo "$(date): [конфиг] WG-конфиг пойман и сохранён в $WG" >> "$LOG"
			return 0
		fi
		sleep 2
		i=$((i+1))
	done
	echo "$(date): [конфиг] не удалось поймать WG-блок за 60 сек после старта" >> "$LOG"
}

# periodic_time_check: вызывается из watchdog, но реально синхронизирует
# не чаще TIME_SYNC_INTERVAL (раз в час), и делает это БЕЗУСЛОВНО — ловит
# не только "год явно неверный", но и постепенный дрейф часов в пределах
# того же года, который тоже может сломать TLS/DTLS-рукопожатие.
periodic_time_check() {
	NOW=$(date +%s 2>/dev/null || echo 0)
	LAST=0
	[ -f "$TIMESYNCF" ] && LAST=$(cat "$TIMESYNCF" 2>/dev/null || echo 0)
	DIFF=$((NOW - LAST))
	if [ "$DIFF" -lt "$TIME_SYNC_INTERVAL" ] 2>/dev/null && [ "$LAST" != "0" ]; then
		return 0
	fi
	command -v ntpd >/dev/null 2>&1 || return 1
	for ip in $NTP_IPS; do
		if ntpd -n -q -p "$ip" >/dev/null 2>&1; then
			echo "$(date): [время] периодическая синхронизация по IP $ip" >> "$LOG"
			date +%s > "$TIMESYNCF" 2>/dev/null
			return 0
		fi
	done
	for srv in $NTP_HOSTS; do
		if ntpd -n -q -p "$srv" >/dev/null 2>&1; then
			echo "$(date): [время] периодическая синхронизация по домену $srv" >> "$LOG"
			date +%s > "$TIMESYNCF" 2>/dev/null
			return 0
		fi
	done
	echo "$(date): [время] периодическая синхронизация не удалась (сеть недоступна?)" >> "$LOG"
	date +%s > "$TIMESYNCF" 2>/dev/null
	return 1
}

ensure_cron() {
	CRONLINE="*/5 * * * * /etc/init.d/qwdtt watchdog >/dev/null 2>&1"
	if ! crontab -l 2>/dev/null | grep -q "qwdtt watchdog"; then
		( crontab -l 2>/dev/null; echo "$CRONLINE" ) | crontab -
		/etc/init.d/cron restart >/dev/null 2>&1
	fi
}

# ---------- NAT из локалки в RAW-туннель ----------
# Проблема та же, что и на Entware: без подмены адреса клиент локальной сети
# уходит в туннель со СВОИМ 192.168.x.x, а NAT на шлюзе покрывает только
# 10.77.77.0/24 — пакеты уходят, ответы не возвращаются. С самого роутера
# пинг при этом проходит (у него источник 10.77.77.x), поэтому дефект
# выглядит как «туннель живой, а обход не работает».
#
# НО точка вставки здесь другая, и копировать Entware-вариант вслепую нельзя.
# На Keenetic трафик в туннель заводит MagiTrickle, а голое правило iptables
# ложится в общую таблицу и живёт до перезагрузки. На OpenWRT firewall
# декларативный: на свежих версиях это fw4/nftables, где команды iptables
# либо отсутствуют, либо ведут в пустую совместимость, и правило просто
# ничего не делает. Правильная точка — зона firewall с masq=1 поверх того
# самого UCI-интерфейса, который сам клиент регистрирует при создании TUN
# (network.wdttraw, см. session_raw.go), плюс проброс lan → эта зона.
# Вариант с iptables оставлен запасным — для fw3 (OpenWRT 19.07/21.02).
MASQ_ZONE="qwdttraw"
MASQ_NET="wdttraw"

masq_zone_section() {
	uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\(@zone\[[0-9]*\]\|[A-Za-z0-9_]*\)\.name='$MASQ_ZONE'$/\1/p" \
		| head -1
}

ensure_masq_uci() {
	command -v uci >/dev/null 2>&1 || return 1
	[ -f /etc/config/firewall ] || return 1
	ZONE=$(masq_zone_section)
	if [ -n "$ZONE" ]; then
		# Зона уже есть — доводим до нужного состояния, не пересоздавая:
		# лишний reload firewall рвёт установленные соединения.
		if [ "$(uci -q get firewall.$ZONE.masq)" != "1" ]; then
			uci set firewall.$ZONE.masq='1'
			uci commit firewall
			/etc/init.d/firewall reload >/dev/null 2>&1
			echo "$(date): [NAT] в зоне $MASQ_ZONE включён masq" >> "$LOG"
		fi
		return 0
	fi
	ZONE=$(uci add firewall zone 2>/dev/null) || return 1
	uci set firewall."$ZONE".name="$MASQ_ZONE"
	uci set firewall."$ZONE".network="$MASQ_NET"
	uci set firewall."$ZONE".masq='1'
	uci set firewall."$ZONE".mtu_fix='1'
	uci set firewall."$ZONE".input='REJECT'
	uci set firewall."$ZONE".output='ACCEPT'
	uci set firewall."$ZONE".forward='REJECT'
	FWD=$(uci add firewall forwarding 2>/dev/null) || { uci revert firewall; return 1; }
	uci set firewall."$FWD".src='lan'
	uci set firewall."$FWD".dest="$MASQ_ZONE"
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	echo "$(date): [NAT] создана зона $MASQ_ZONE (masq=1, сеть $MASQ_NET) и проброс lan→$MASQ_ZONE" >> "$LOG"
	return 0
}

ensure_masq_iptables() {
	command -v iptables >/dev/null 2>&1 || return 1
	IFACE="${RAW_TUN:-meridian}"
	iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null && return 0
	iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || return 1
	echo "$(date): [NAT] MASQUERADE на $IFACE добавлен (запасной путь, fw3/iptables)" >> "$LOG"
	return 0
}

ensure_masq() {
	. "$CONF" 2>/dev/null
	[ "${MODE:-wg}" = "raw" ] || return 0
	ip link show "${RAW_TUN:-meridian}" >/dev/null 2>&1 || return 1
	ensure_masq_uci && return 0
	ensure_masq_iptables && return 0
	echo "$(date): [NAT] не удалось настроить подмену адреса: нет ни uci+firewall, ни iptables" >> "$LOG"
	return 1
}

# Интерфейс поднимает сам клиент, уже ПОСЛЕ старта процесса, поэтому ждём его
# появления в фоне. Ограниченно: вечных ожиданий на роутере быть не должно.
ensure_masq_when_up() {
	i=0
	while [ "$i" -lt 60 ]; do
		if ensure_masq; then return 0; fi
		sleep 2
		i=$((i+1))
	done
	echo "$(date): [NAT] интерфейс ${RAW_TUN:-meridian} не появился за 120 с, подмена адреса не настроена" >> "$LOG"
	return 1
}

# remove_masq снимает ВОЛАТИЛЬНОЕ правило — то, что накапливается. Зону UCI
# намеренно не удаляем: это декларативный конфиг, а не правило в таблице, он
# не дублируется и без интерфейса просто ни на что не распространяется. Её
# удаление на каждой остановке означало бы reload firewall с обрывом всех
# установленных соединений роутера ради косметики.
remove_masq() {
	command -v iptables >/dev/null 2>&1 || return 0
	IFACE="${RAW_TUN:-meridian}"
	tries=0
	while iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; do
		iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || break
		echo "$(date): [NAT] MASQUERADE на $IFACE снят" >> "$LOG"
		tries=$((tries+1))
		[ "$tries" -gt 10 ] && break
	done
}

start_service() {
	. "$CONF" 2>/dev/null
	mkdir -p "$(dirname "$LOG")"
	rotate_log
	ensure_cron
	sync_time_if_needed
	if [ -z "$DEVICE_ID" ]; then
		DEVICE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '\n')
		[ -z "$DEVICE_ID" ] && DEVICE_ID="dev$(date +%s)$$"
		echo "DEVICE_ID=\"$DEVICE_ID\"" >> "$CONF"
	fi
	procd_open_instance
	if [ "${MODE:-wg}" = "raw" ]; then
		RAW_PEER_ACTUAL="${RAW_PEER:-}"
		if [ -z "$RAW_PEER_ACTUAL" ]; then
			RAW_HOST=$(echo "$PEER" | cut -d: -f1)
			RAW_PEER_ACTUAL="${RAW_HOST}:56004"
		fi
		procd_set_param command /bin/sh -c "exec '$BIN' -mode raw -tun '${RAW_TUN:-meridian}' -peer '$RAW_PEER_ACTUAL' -password '$PASSWORD' -vk '$VK_HASHES' -vk-anon-path '${ANON_PATH:-vkcalls}' -n '${N:-24}' -device-id '$DEVICE_ID' < /dev/null >> '$LOG' 2>&1"
		procd_set_param respawn 3600 5 0
		procd_close_instance
		echo "$(date): запущен в режиме RAW, peer=$RAW_PEER_ACTUAL tun=${RAW_TUN:-meridian}" >> "$LOG"
		# Интерфейс появится через пару секунд — тогда и настроим подмену
		# адреса, иначе локалка уйдёт в туннель со своим 192.168.x.x.
		( ensure_masq_when_up ) &
	else
		procd_set_param command /bin/sh -c "exec '$BIN' -peer '$PEER' -password '$PASSWORD' -vk '$VK_HASHES' -vk-anon-path '${ANON_PATH:-vkcalls}' -n '${N:-24}' -device-id '$DEVICE_ID' -listen 127.0.0.1:9000 < /dev/null >> '$LOG' 2>&1"
		procd_set_param respawn 3600 5 0
		procd_close_instance
		( capture_wg_config ) &
	fi
}

# stop_service вызывает procd при остановке сервиса — здесь снимаем за собой
# волатильное правило NAT, чтобы оно не копилось от перезапуска к перезапуску.
stop_service() {
	. "$CONF" 2>/dev/null
	remove_masq
}

watchdog() {
	rotate_log
	periodic_time_check
	# Ищем процесс по пути бинаря, а НЕ по "$BIN -peer": в RAW-режиме
	# командная строка начинается с "-mode raw -tun ...", и "-peer" стоит
	# третьим аргументом, поэтому старый шаблон не совпадал никогда —
	# watchdog каждые 5 минут считал живой RAW-туннель мёртвым и дёргал
	# start. Пробел в конце обязателен: без него шаблон совпадает ещё и с
	# "/opt/bin/qwdtt-ctl status", который панель запускает для статуса, и
	# тогда мёртвый туннель выглядел бы живым.
	if ! pgrep -f "$BIN " >/dev/null 2>&1; then
		echo "$(date): [watchdog] процесс не найден, поднимаю" >> "$LOG"
		/etc/init.d/qwdtt start
		return
	fi
	# порт 127.0.0.1:9000 существует только в режиме WG — в RAW-режиме
	# процесс его никогда не открывает, это нормально. Раньше проверка
	# была безусловной и убивала+пересоздавала рабочий RAW-туннель каждые
	# 5 минут, считая его зависшим.
	. "$CONF" 2>/dev/null
	if [ "${MODE:-wg}" != "raw" ]; then
		if ! netstat -ln 2>/dev/null | grep -q '127.0.0.1:9000'; then
			echo "$(date): [watchdog] порт 9000 не слушает — перезапуск" >> "$LOG"
			/etc/init.d/qwdtt restart
		fi
	else
		# Подмена адреса волатильна: правило исчезает вместе с пересозданным
		# интерфейсом, зона могла быть снесена вручную. Вызов идемпотентен.
		ensure_masq
	fi
}
