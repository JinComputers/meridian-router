#!/bin/sh
# qwdtt-probe.sh — минутный диагностический пробник канала meridian.
#
# Раз в минуту (из cron):
#   * ping -c2 -W3 -I meridian 8.8.8.8
#   * считает процессы клиента по шаблону '[q]wdtt (-peer|-mode)'
#   * пинг ОК   -> одна короткая строка "OK <дата> procs=N up=..."
#   * пинг ФЕЙЛ -> подробный блок: дата, число процессов, аптайм процесса
#                  qwdtt, причина от ping и последние 15 строк qwdtt.log
#
# Установка задания в cron:  /opt/bin/qwdtt-probe.sh install
# Снятие задания:            /opt/bin/qwdtt-probe.sh uninstall
#
# Пути можно переопределить переменными окружения (нужно для тестов).

IFACE="${PROBE_IFACE:-meridian}"
TARGET="${PROBE_TARGET:-8.8.8.8}"
LOG="${PROBE_LOG:-/opt/var/log/qwdtt-probe.log}"
SRCLOG="${PROBE_SRCLOG:-/opt/var/log/qwdtt.log}"
CRONFILE="${PROBE_CRONFILE:-/opt/etc/crontabs/root}"
PIDF="${PROBE_PIDF:-/opt/var/run/qwdtt-probe.pid}"

MAXBYTES=262144   # 256 КБ — порог обрезки лога
KEEPLINES=500     # сколько последних строк оставляем при обрезке
TAILLINES=15      # сколько строк qwdtt.log подшиваем к отчёту об обрыве

SELF=$(readlink -f "$0" 2>/dev/null) || SELF=""   # bb-ok: неудача обработана, дальше запасной путь
[ -n "$SELF" ] || SELF="$0"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# --- число процессов клиента -------------------------------------------------
# ВАЖНО: шаблон именно в одинарных кавычках и БЕЗ экранирования скобок —
# '[q]' здесь класс символов, он же отсекает строку самого grep из вывода ps.
# Экранированный '\[q\]' в grep -E ищет литеральный текст "[q]wdtt" и не
# находит ничего (см. CLAUDE.md, п.7).
count_procs() {
	ps w 2>/dev/null | grep -E '[q]wdtt (-peer|-mode)' | wc -l | tr -d ' \t'
}

first_pid() {
	ps w 2>/dev/null | grep -E '[q]wdtt (-peer|-mode)' | awk '{print $1; exit}'
}

# --- аптайм процесса по /proc/<pid>/stat ------------------------------------
# Поле 22 (starttime) в тиках с момента загрузки; comm может содержать пробелы,
# поэтому сначала срезаем "pid (comm) " и берём поле 20 остатка.
proc_uptime() {
	pid="$1"
	[ -n "$pid" ] && [ -r "/proc/$pid/stat" ] || { echo "нет процесса"; return; }
	start=$(sed 's/^[0-9]* ([^)]*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
	up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	hz=$(getconf CLK_TCK 2>/dev/null) || hz=""
	[ -n "$hz" ] || hz=100
	case "$start$up" in ''|*[!0-9]*) echo "н/д"; return;; esac
	secs=$((up - start / hz))
	[ "$secs" -ge 0 ] 2>/dev/null || secs=0
	d=$((secs / 86400)); h=$(((secs % 86400) / 3600))
	m=$(((secs % 3600) / 60)); s=$((secs % 60))
	if [ "$d" -gt 0 ]; then
		printf '%dд %02d:%02d:%02d' "$d" "$h" "$m" "$s"
	else
		printf '%02d:%02d:%02d' "$h" "$m" "$s"
	fi
}

# --- обрезка собственного лога ----------------------------------------------
rotate_log() {
	[ -f "$LOG" ] || return 0
	# Группировка, а не просто 2>/dev/null: при отсутствии файла ошибку
	# перенаправления печатает сама оболочка, и на команде её не перехватить
	# (тот же дефект, что вылез в апдейтере с /proc/<pid>/cmdline).
	sz=$( { wc -c < "$LOG"; } 2>/dev/null | tr -d ' \t')
	case "$sz" in ''|*[!0-9]*) return 0;; esac
	[ "$sz" -gt "$MAXBYTES" ] || return 0
	if tail -n "$KEEPLINES" "$LOG" > "$LOG.tmp" 2>/dev/null; then
		mv "$LOG.tmp" "$LOG" 2>/dev/null
		echo "$(ts) ROTATE лог обрезан до $KEEPLINES строк (было $sz Б)" >> "$LOG"
	else
		rm -f "$LOG.tmp" 2>/dev/null
	fi
}

# --- защита от наложения запусков -------------------------------------------
# На роутере ~248 МБ ОЗУ и активный OOM-киллер: зависший ping не должен
# накапливать по копии пробника каждую минуту (см. CLAUDE.md, п.8).
take_lock() {
	mkdir -p "$(dirname "$PIDF")" 2>/dev/null
	if [ -f "$PIDF" ]; then
		old=$(cat "$PIDF" 2>/dev/null)
		case "$old" in
			''|*[!0-9]*) ;;
			*) [ -d "/proc/$old" ] && [ "$old" != "$$" ] && exit 0 ;;
		esac
	fi
	echo $$ > "$PIDF" 2>/dev/null
	trap 'rm -f "$PIDF" 2>/dev/null' EXIT INT TERM
}

probe() {
	mkdir -p "$(dirname "$LOG")" 2>/dev/null
	take_lock
	rotate_log

	PROCS=$(count_procs)
	[ -n "$PROCS" ] || PROCS=0
	PID=$(first_pid)
	UP=$(proc_uptime "$PID")

	# ДАТЧИК S97 (23.09.2026, поручение владельца). S97meridian-router — init
	# СНЯТОГО С РАЗДАЧИ модуля DNS-обхода по доменам, а НЕ клиента. 18.08.2026
	# его изолировали и убрали из раздачи, но на роутерах, где он успел
	# встать, файл остался — на HERO он есть, это и поймал владелец.
	#
	# Зачем считать. Мы не знаем, на скольких роутерах парка он лежит, а
	# опросить их нечем: входящего канала управления на роутерах нет. Пробник
	# же приходит на каждый раз в минуту — значит за сутки он и даст картину,
	# если просто напишет факт в свою строку.
	#
	# ПРОВЕРЯЕМ СУЩЕСТВОВАНИЕ, А НЕ ИСПОЛНЯЕМОСТЬ. Первая редакция брала
	# [ -x ], и на HERO датчик написал «нет» при том, что файл там ЕСТЬ:
	# при изоляции 18.08.2026 с него сняли право на исполнение, режим стал
	# 644. Вопрос стоит «остался ли файл на роутере», а не «запустится ли
	# он» — [ -x ] отвечал не на тот вопрос и занизил бы счёт по всему парку.
	#
	# Различие «есть» и «есть-неисп» оставлено намеренно, оно само по себе
	# ответ: неисполняемый — это изолированный, как на HERO; исполняемый —
	# это модуль, который ещё может подняться сам, и такой роутер интереснее.
	#
	# Стоит это одну-две проверки файла ([ -e ] и [ -x ] — встроенные команды
	# оболочки, без запуска процесса). Требование «почти бесплатно» соблюдено.
	if [ -e /opt/etc/init.d/S97meridian-router ]; then
		if [ -x /opt/etc/init.d/S97meridian-router ]; then S97=есть; else S97=есть-неисп; fi
	else
		S97=нет
	fi

	OUT=$(ping -c2 -W3 -I "$IFACE" "$TARGET" 2>&1)
	if [ $? -eq 0 ]; then
		echo "$(ts) OK ping $TARGET via $IFACE, procs=$PROCS, s97=$S97" >> "$LOG"
		return 0
	fi

	{
		echo "$(ts) FAIL ping $TARGET via $IFACE | procs=$PROCS | pid=${PID:-нет} | аптайм qwdtt: $UP | s97=$S97"
		echo "  ping: $(echo "$OUT" | grep -v '^$' | tail -n 3 | tr '\n' ' ')"
		if [ -r "$SRCLOG" ]; then
			echo "  --- последние $TAILLINES строк $SRCLOG ---"
			tail -n "$TAILLINES" "$SRCLOG" 2>/dev/null | sed 's/^/  | /'
			echo "  --- конец фрагмента ---"
		else
			echo "  --- $SRCLOG недоступен ---"
		fi
	} >> "$LOG"
	return 1
}

# Убрать свои строки из crontab.
# ВНИМАНИЕ: код возврата grep -v проверять нельзя — если после фильтра не
# остаётся ни одной строки (в crontab была только наша задача), grep выходит
# с кодом 1, и "&& mv" молча не срабатывает: строка остаётся на месте.
strip_cron_line() {
	[ -r "$CRONFILE" ] || return 1
	grep -v "qwdtt-probe.sh" "$CRONFILE" > "$CRONFILE.tmp" 2>/dev/null
	[ -f "$CRONFILE.tmp" ] || return 1
	mv "$CRONFILE.tmp" "$CRONFILE" 2>/dev/null || { rm -f "$CRONFILE.tmp"; return 1; }
	return 0
}

reload_cron() {
	for c in /opt/etc/init.d/S*cron*; do
		[ -x "$c" ] && "$c" restart >/dev/null 2>&1 && return 0
	done
	# OpenWRT: расписание в /etc/crontabs, сервис называется просто cron
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 && return 0
	# перечитать расписание нечем — хотя бы убедиться, что crond жив
	ps w 2>/dev/null | grep -q '[c]rond' || crond -c "$(dirname "$CRONFILE")" >/dev/null 2>&1
	return 0
}


# --- ПЕРЕЕЗД НА ВХОД 1 (однократный, 23.09.2026) ----------------------------
# Пробник выбран носителем переезда сознательно: он уже стоит в cron у всех
# роутеров парка и запускается раз в минуту, а init-скрипты срабатывают
# только при перезапуске клиента, которого можно ждать неделями.
#
# ГЛАВНОЕ ТРЕБОВАНИЕ К ЭТОМУ КОДУ — БЫТЬ ПОЧТИ БЕСПЛАТНЫМ. Он выполняется
# каждую минуту на каждом роутере, и в 99,99% запусков обязан завершиться
# двумя проверками файла, без сети, без вызовов движка и без разбора логов.
PEREEZD_STARY="${PEREEZD_STARY:-138.124.78.252:56000}"
PEREEZD_NOVY="${PEREEZD_NOVY:-62.76.231.231:56000}"
PEREEZD_CONF="${PEREEZD_CONF:-/opt/etc/qwdtt/qwdtt.conf}"
PEREEZD_METKA="${PEREEZD_METKA:-/opt/etc/qwdtt/.pereezd-vhod1-sdelan}"
PEREEZD_ZAMOK="${PEREEZD_ZAMOK:-/opt/var/run/qwdtt-pereezd.pid}"
PEREEZD_LOG="${PEREEZD_LOG:-/opt/var/log/pereezd-vhod1.log}"
PEREEZD_ENG="${PEREEZD_ENG:-/opt/bin/meridian-route}"
PEREEZD_ZHDEM="${PEREEZD_ZHDEM:-90}"

pereezd_zapis() {
	mkdir -p "$(dirname "$PEREEZD_LOG")" 2>/dev/null
	echo "$(ts) $*" >> "$PEREEZD_LOG" 2>/dev/null
}

# СВОЙ замок, отдельный от замка пробника. Переезд длится до 90 секунд, а
# пробник приходит каждые 60 — то есть следующий запуск гарантированно
# застанет переезд в работе. Тот же приём, что у take_lock: pid в файле и
# проверка /proc, потому что flock на части прошивок отсутствует.
pereezd_zamok_vzyat() {
	mkdir -p "$(dirname "$PEREEZD_ZAMOK")" 2>/dev/null
	if [ -f "$PEREEZD_ZAMOK" ]; then
		_old=$(cat "$PEREEZD_ZAMOK" 2>/dev/null)
		case "$_old" in
			''|*[!0-9]*) ;;
			*)
				if [ -d "/proc/$_old" ] && [ "$_old" != "$$" ]; then
					return 1
				fi
				;;
		esac
	fi
	echo $$ > "$PEREEZD_ZAMOK" 2>/dev/null
	return 0
}

pereezd_perezapusk() {
	# ИСПРАВЛЕНО 23.09.2026 (владелец поймал на HERO). Прежние три способа
	# целились в S97meridian-router. Это НЕ клиент: S97meridian-router —
	# init снятого с раздачи модуля DNS-обхода по доменам (/opt/bin/
	# meridian-router, своя метка 0x4d52, таблица 200, ipset meridian_bypass).
	# На части парка он ОСТАЛСЯ — на HERO есть. Поэтому старая цепочка на
	# таком роутере перезапускала ЧУЖУЮ службу вместо клиента, а клиент
	# оставался на прежнем адресе. Настоящие имена — из установщиков:
	# entware /opt/etc/init.d/S99qwdtt, openwrt /etc/init.d/qwdtt (procd),
	# процесс называется qwdtt.
	if [ -x /opt/etc/init.d/S99qwdtt ]; then
		/opt/etc/init.d/S99qwdtt restart > /dev/null 2>&1
		echo S99qwdtt-entware
	elif [ -x /etc/init.d/qwdtt ]; then
		/etc/init.d/qwdtt restart > /dev/null 2>&1
		echo init.d-qwdtt-openwrt
	elif command -v qwdtt-ctl > /dev/null 2>&1; then
		qwdtt-ctl restart > /dev/null 2>&1
		echo qwdtt-ctl
	else
		killall qwdtt > /dev/null 2>&1
		echo killall-qwdtt
	fi
}

pereezd_tunnel_zhiv() {
	ping -c 1 -w 3 10.77.77.1 > /dev/null 2>&1
}

# pereezd_nuzhen — ДВЕ проверки файла и ничего больше. Это и есть та самая
# «почти бесплатная» ветка, которая отрабатывает каждую минуту.
pereezd_nuzhen() {
	[ -f "$PEREEZD_METKA" ] && return 1
	[ -f "$PEREEZD_CONF" ] || return 1
	# строку RELAY_PEER (её пишет relaypeer_*) переезд не трогает и за старый адрес не считает:
	# (сейчас она всегда :56004 и старого адреса :56000 не содержит; проверка — страховка от ручной правки).
	grep -v '^[[:space:]]*RELAY_PEER=' "$PEREEZD_CONF" 2>/dev/null | grep -F "$PEREEZD_STARY" > /dev/null 2>&1 || return 1
	return 0
}

pereezd_sdelat() {
	pereezd_zamok_vzyat || return 0

	# Метка ставится ДО первой правки. Если роутер перезагрузится посреди
	# переезда, второй попытки не будет: остаться на старом адресе и
	# разобраться руками лучше, чем крутить полупереезд по кругу.
	date '+%Y-%m-%d %H:%M:%S начат переезд на вход 1' > "$PEREEZD_METKA" 2>/dev/null

	pereezd_zapis "=== ПЕРЕЕЗД: $PEREEZD_STARY -> $PEREEZD_NOVY ==="

	_kopiya="$PEREEZD_CONF.pered-vhod1"
	cp "$PEREEZD_CONF" "$_kopiya" 2>/dev/null
	pereezd_zapis "копия конфига: $_kopiya"

	sed -i "/^[[:space:]]*RELAY_PEER=/!s|$PEREEZD_STARY|$PEREEZD_NOVY|g" "$PEREEZD_CONF" 2>/dev/null
	pereezd_zapis "после правки: $(grep -E '^[[:space:]]*(RAW_)?PEER=' "$PEREEZD_CONF" 2>/dev/null | tr '\n' ' ')"

	# keep build — только если движок умеет. Парк движок не обновляет, в нём
	# есть версии без этой команды; её отсутствие не повод срывать переезд:
	# в чёрном режиме трафик к адресу входа и так идёт мимо туннеля.
	if [ -x "$PEREEZD_ENG" ] && "$PEREEZD_ENG" keep build < /dev/null > /dev/null 2>&1; then
		pereezd_zapis "keep пересобран"
	else
		pereezd_zapis "keep build недоступен — пропускаю (в чёрном режиме петли нет)"
	fi

	pereezd_zapis "перезапуск клиента способом: $(pereezd_perezapusk)"

	_i=0
	_podnyalsya=net
	while [ "$_i" -lt "$PEREEZD_ZHDEM" ]; do
		if pereezd_tunnel_zhiv; then
			_podnyalsya=da
			pereezd_zapis "туннель поднялся на $_i-й секунде"
			_i="$PEREEZD_ZHDEM"
		else
			sleep 3
			_i=$((_i + 3))
		fi
	done

	if [ "$_podnyalsya" = "da" ]; then
		sleep 5
		_put=$(tail -n 60 "$SRCLOG" 2>/dev/null | grep '\[ПУТЬ\]' | tail -1)
		pereezd_zapis "путь: ${_put:-строки ПУТЬ нет}"
		# ИСПРАВЛЕНО 23.09.2026: реальные подписи из pathbeacon.go/session_raw_path.go
		# — "быстрый путь" и "резервный путь, медленнее" (VK-релей). Слова
		# "ретранслятор" клиент не печатает никогда — старое условие всегда
		# проваливалось в default и врало "быстрый путь" даже на резервном.
		case "$_put" in
			*резервный*)  pereezd_zapis "ИТОГ: ЗЕЛЁНОЕ, но путь резервный (через VK-релей)" ;;
			*быстрый*)    pereezd_zapis "ИТОГ: ЗЕЛЁНОЕ, быстрый путь" ;;
			*)            pereezd_zapis "ИТОГ: путь не опознан по подписи — смотреть строку выше глазами" ;;
		esac
	else
		pereezd_zapis "за $PEREEZD_ZHDEM с не поднялся — ОТКАТ на $PEREEZD_STARY"
		cp "$_kopiya" "$PEREEZD_CONF" 2>/dev/null
		[ -x "$PEREEZD_ENG" ] && "$PEREEZD_ENG" keep build < /dev/null > /dev/null 2>&1
		pereezd_perezapusk > /dev/null
		sleep 10
		if pereezd_tunnel_zhiv; then
			pereezd_zapis "ИТОГ: КРАСНОЕ — вход 1 не поднялся, откат выполнен, связь вернулась"
		else
			pereezd_zapis "ИТОГ: КРАСНОЕ — не поднялось ни через вход 1, ни после отката, нужна консоль"
		fi
	fi

	rm -f "$PEREEZD_ZAMOK" 2>/dev/null
}

# --- СТРОКА RELAY_PEER В КОНФИГ (однократно, 24.09.2026) ---------------------
# Клиент 4.2 берёт адрес шлюза для резервного пути из RELAY_PEER. Строку кладём
# ЗАРАНЕЕ, пробником: клиент не перезапускаем, он подхватит её при обновлении ядра.
# Только режим raw (MODE="raw" или MODE не задан — умолчание init raw); wg не трогаем.
# Значение: <шлюз>:56004 всегда (RAW_PEER не читается: 56000 — wdtt-server, а не raw-шлюз).
# Строка RELAY_PEER уже есть — не трогаем. Как и переезд: своя метка, свой pid-замок,
# одна попытка; в 99,99% запусков это несколько проверок файла без сети.
RELAYPEER_CONF="${RELAYPEER_CONF:-/opt/etc/qwdtt/qwdtt.conf}"
RELAYPEER_HOST="${RELAYPEER_HOST:-138.124.78.252}"
RELAYPEER_PORT_DEF="${RELAYPEER_PORT_DEF:-56004}"
RELAYPEER_METKA="${RELAYPEER_METKA:-/opt/etc/qwdtt/.relay-peer-sdelan}"
RELAYPEER_ZAMOK="${RELAYPEER_ZAMOK:-/opt/var/run/qwdtt-relaypeer.pid}"
RELAYPEER_LOG="${RELAYPEER_LOG:-/opt/var/log/relay-peer.log}"

relaypeer_zapis() {
	mkdir -p "$(dirname "$RELAYPEER_LOG")" 2>/dev/null
	echo "$(ts) $*" >> "$RELAYPEER_LOG" 2>/dev/null
}

relaypeer_zamok_vzyat() {
	mkdir -p "$(dirname "$RELAYPEER_ZAMOK")" 2>/dev/null
	if [ -f "$RELAYPEER_ZAMOK" ]; then
		_old=$(cat "$RELAYPEER_ZAMOK" 2>/dev/null)
		case "$_old" in
			''|*[!0-9]*) ;;
			*)
				if [ -d "/proc/$_old" ] && [ "$_old" != "$$" ]; then
					return 1
				fi
				;;
		esac
	fi
	echo $$ > "$RELAYPEER_ZAMOK" 2>/dev/null
	return 0
}

# значение последней строки KEY=... из конфига, без кавычек и пробелов по краям
relaypeer_znachenie() {
	grep -E "^[[:space:]]*$1=" "$RELAYPEER_CONF" 2>/dev/null | tail -n 1 | sed -e 's/^[^=]*=//' -e "s/^[[:space:]\"']*//" -e "s/[[:space:]\"']*\$//"
}

# relaypeer_nuzhen: 0 — надо писать; 2 — строка уже есть (только пометить); 1 — не нужно
relaypeer_nuzhen() {
	[ -f "$RELAYPEER_METKA" ] && return 1
	[ -f "$RELAYPEER_CONF" ] || return 1
	grep -Eq '^[[:space:]]*RELAY_PEER=' "$RELAYPEER_CONF" 2>/dev/null && return 2
	_rp_mode=$(relaypeer_znachenie MODE)
	case "$_rp_mode" in
		''|raw) return 0 ;;
		*) return 1 ;;
	esac
}

relaypeer_sdelat() {
	relaypeer_zamok_vzyat || return 0
	relaypeer_nuzhen
	_rp_rc=$?
	if [ "$_rp_rc" = 1 ]; then
		rm -f "$RELAYPEER_ZAMOK" 2>/dev/null
		return 0
	fi
	if [ "$_rp_rc" = 2 ]; then
		date '+%Y-%m-%d %H:%M:%S RELAY_PEER уже есть, не трогаю' > "$RELAYPEER_METKA" 2>/dev/null
		relaypeer_zapis "уже есть, не трогаю: $(grep -E '^[[:space:]]*RELAY_PEER=' "$RELAYPEER_CONF" 2>/dev/null | tr '\n' ' ')"
		rm -f "$RELAYPEER_ZAMOK" 2>/dev/null
		return 0
	fi
	# порт ВСЕГДА 56004 (raw-шлюз Парижа, DTLS); RAW_PEER не читаем: 56000 там — wdtt-server,
	# и ошибочный порт основного адреса в запасной путь переносить нельзя (решение владельца 24.09.2026)
	_rp_port="$RELAYPEER_PORT_DEF"
	_rp_znach="$RELAYPEER_HOST:$_rp_port"
	# метка ДО правки: одна попытка, без кругов
	date '+%Y-%m-%d %H:%M:%S начата запись RELAY_PEER' > "$RELAYPEER_METKA" 2>/dev/null
	_rp_kopiya="$RELAYPEER_CONF.pered-relay-peer"
	[ -f "$_rp_kopiya" ] || cp "$RELAYPEER_CONF" "$_rp_kopiya" 2>/dev/null
	# конфиг может не кончаться переводом строки — иначе строка приклеится к последней
	if [ -n "$(tail -c1 "$RELAYPEER_CONF" 2>/dev/null)" ]; then echo >> "$RELAYPEER_CONF" 2>/dev/null; fi
	printf 'RELAY_PEER="%s"\n' "$_rp_znach" >> "$RELAYPEER_CONF" 2>/dev/null
	if grep -qx "RELAY_PEER=\"$_rp_znach\"" "$RELAYPEER_CONF" 2>/dev/null; then
		relaypeer_zapis "записана RELAY_PEER=\"$_rp_znach\" ; клиент не перезапускаю, подхватит при обновлении ядра; копия: $_rp_kopiya"
	else
		cp "$_rp_kopiya" "$RELAYPEER_CONF" 2>/dev/null
		relaypeer_zapis "ОШИБКА записи RELAY_PEER, конфиг возвращён из копии $_rp_kopiya"
	fi
	rm -f "$RELAYPEER_ZAMOK" 2>/dev/null
}

install_cron() {
	CRONLINE="* * * * * $SELF >/dev/null 2>&1"
	mkdir -p "$(dirname "$CRONFILE")" 2>/dev/null
	[ -f "$CRONFILE" ] || : > "$CRONFILE"
	if grep -q "qwdtt-probe.sh" "$CRONFILE" 2>/dev/null; then
		if grep -qxF "$CRONLINE" "$CRONFILE" 2>/dev/null; then
			echo "задание уже в $CRONFILE — ничего не меняю"
			ps w 2>/dev/null | grep -q '[c]rond' || crond -c "$(dirname "$CRONFILE")" >/dev/null 2>&1
			return 0
		fi
		# путь к скрипту изменился — заменяем только свою строку
		strip_cron_line || { echo "не смог переписать $CRONFILE"; return 1; }
	fi
	echo "$CRONLINE" >> "$CRONFILE"
	reload_cron
	echo "$(ts) INSTALL пробник добавлен в cron: $CRONLINE" >> "$LOG"
	echo "готово: $CRONLINE"
}

uninstall_cron() {
	[ -f "$CRONFILE" ] || { echo "$CRONFILE не найден"; return 0; }
	grep -q "qwdtt-probe.sh" "$CRONFILE" 2>/dev/null || { echo "задания нет"; return 0; }
	strip_cron_line || { echo "не смог переписать $CRONFILE"; return 1; }
	reload_cron
	echo "$(ts) UNINSTALL задание снято с cron" >> "$LOG"
	echo "задание снято"
}

case "$1" in
	install)   install_cron ;;
	uninstall) uninstall_cron ;;
	tail)      tail -n "${2:-40}" "$LOG" 2>/dev/null ;;
	""|run)
		# ПЕРЕЕЗД ПЕРВЫМ ДЕЛОМ: две проверки файла, и в подавляющем
		# большинстве запусков управление сразу уходит в probe.
		if pereezd_nuzhen; then
			pereezd_sdelat
		else
			relaypeer_nuzhen
			[ "$?" = 1 ] || relaypeer_sdelat
		fi
		probe
		;;
	*)
		echo "использование: $SELF [install|uninstall|run|tail [N]]"
		exit 1
		;;
esac
