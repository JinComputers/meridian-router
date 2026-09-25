#!/bin/sh
# S98qwdtt-web — автозапуск панели управления (Entware).
#
# Раздаётся файлом (qwdtt-web-init-entware.sh) с 17.08.2026. До этого скрипт
# существовал только внутри install.sh, то есть у уже установленных роутеров он
# не обновлялся НИЧЕМ: любая правка автозапуска доезжала только переустановкой.
BIN="${QWDTT_WEB_BIN:-/opt/bin/qwdtt-web}"
LOG="${QWDTT_WEB_LOG:-/opt/var/log/qwdtt-web.log}"
PIDF="${QWDTT_WEB_PIDF:-/opt/var/run/qwdtt-web.pid}"
PROCROOT="${QWDTT_PROCROOT:-/proc}"   # переопределяется только прогоном

start() {
	[ -x "$BIN" ] || exit 1
	# ТОТ ЖЕ номер — не тот же процесс. Прежняя проверка (`kill -0`) отвечала
	# «уже запущен», когда номер мёртвой панели доставался чужой программе, и
	# запуск не делал НИЧЕГО. Навсегда: следующий запуск получал тот же ответ.
	if pid_is_panel "$(cat "$PIDF" 2>/dev/null)"; then echo "уже запущен"; return 0; fi
	mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDF")"
	# Лог прошлого запуска СОХРАНЯЕТСЯ, а не затирается.
	#
	# 17.08.2026 панель упала сама, оставив дамп горутин, — и причину установить
	# не удалось: здесь стояло `> "$LOG"`, панель перезапустили, улика исчезла.
	# Каждое падение расследовать нечем, если служба стирает свой лог при старте.
	if [ -s "$LOG" ]; then mv -f "$LOG" "$LOG.1"; fi
	# Проверяем существование ДО чтения: без этого при первом запуске оболочка
	# печатает «cannot open …log.1», и человек ищет поломку там, где её нет.
	SZ=0
	[ -f "$LOG.1" ] && SZ=$(wc -c < "$LOG.1" 2>/dev/null || echo 0)
	if [ "${SZ:-0}" -gt 2097152 ]; then tail -c 1048576 "$LOG.1" > "$LOG.1.tmp" && mv -f "$LOG.1.tmp" "$LOG.1"; fi
	"$BIN" < /dev/null >> "$LOG" 2>&1 &
	echo $! > "$PIDF"
	watchdog_start
}

# ---------- СТОРОЖ ----------
#
# Заведён 03.09.2026. Повод: панель владельца замолчала 01.09 в 16:22 и пролежала
# ДВОЕ СУТОК. Никто не поднял её, потому что поднимать было некому: у клиента
# сторож есть (21 упоминание в его init), у панели не было ни одного. А `status`
# при этом отвечал «работает», и снаружи всё выглядело исправным.
#
# ПРИЗНАК ЗДОРОВЬЯ — ОТВЕТ, А НЕ ЖИВОЙ ПРОЦЕСС (правило 19). Панель может висеть
# процессом и не отвечать; для человека это то же самое, что её нет.
WDPIDF="${QWDTT_WEB_WDPIDF:-/opt/var/run/qwdtt-web.watchdog.pid}"
WDEVERY="${QWDTT_WEB_WDEVERY:-60}"
WDPORT="${QWDTT_WEB_PORT:-8090}"

# panel_answers — ОТВЕТИЛА ли панель. Пусто в ответ на «нечем спросить»: тогда
# решаем по процессу и ГОВОРИМ об этом, а не выдаём незнание за здоровье.
panel_answers() {
	if command -v curl >/dev/null 2>&1; then
		curl -s -m 5 "http://127.0.0.1:$WDPORT/healthz" 2>/dev/null | grep -q '^ok ' && return 0
		return 1
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -O - "http://127.0.0.1:$WDPORT/healthz" 2>/dev/null | grep -q '^ok ' && return 0
		return 1
	fi
	return 2
}

watchdog_loop() {
	_silent=0
	while :; do
		sleep "$WDEVERY"
		# Сторож живёт, пока живёт запуск. Убрали pid-файл — уходим сами, иначе
		# после `stop` он поднимал бы панель обратно.
		[ -f "$PIDF" ] || exit 0
		panel_answers
		_answer=$?
		if [ "$_answer" = 2 ]; then
			# Спросить нечем. Решаем по процессу, но НЕ молча.
			if pid_is_panel "$(cat "$PIDF" 2>/dev/null)"; then continue; fi
			echo "$(date '+%Y/%m/%d %H:%M:%S') [СТОРОЖ] панели нет в процессах, спросить её нечем (нет curl и wget) — поднимаю" >> "$LOG"
		elif [ "$_answer" = 0 ]; then
			_silent=0
			continue
		else
			# Не ответила. Повтор не печатаем (правило 21): при устойчивом отказе
			# строка шла бы каждую минуту и за сутки дала бы полторы тысячи.
			if [ "$_silent" = 0 ]; then
				echo "$(date '+%Y/%m/%d %H:%M:%S') [СТОРОЖ] панель не отвечает на :$WDPORT — поднимаю" >> "$LOG"
			fi
			_silent=1
		fi
		stop_quiet
		sleep 1
		start_quiet
	done
}

watchdog_start() {
	if [ -f "$WDPIDF" ] && kill -0 "$(cat "$WDPIDF" 2>/dev/null)" 2>/dev/null; then return 0; fi
	watchdog_loop < /dev/null >> "$LOG" 2>&1 &
	echo $! > "$WDPIDF"
}

watchdog_stop() {
	_wp=$(cat "$WDPIDF" 2>/dev/null)
	[ -n "$_wp" ] && kill "$_wp" 2>/dev/null
	rm -f "$WDPIDF"
}

# start_quiet / stop_quiet — то же самое, но без сторожа: иначе он поднимал бы
# сам себя вторым экземпляром при каждом восстановлении.
start_quiet() {
	[ -x "$BIN" ] || return 1
	mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDF")"
	"$BIN" < /dev/null >> "$LOG" 2>&1 &
	echo $! > "$PIDF"
}

stop_quiet() {
	_p=$(cat "$PIDF" 2>/dev/null)
	if pid_is_panel "$_p"; then kill "$_p" 2>/dev/null; fi
	kill_panel_procs
}

# kill_panel_procs — добить процессы панели, НЕ ТРОГАЯ СЕБЯ.
#
# Было: `for p in $(ps w | grep '[q]wdtt-web' | awk '{print $1}'); do kill "$p"; done`.
# Это находило САМ ЭТОТ СКРИПТ: его имя (S98qwdtt-web) содержит qwdtt-web, а BusyBox
# `ps` показывает ВСЕ процессы. На шаге stop скрипт убивал себя, и до start дело не
# доходило никогда — то есть `restart` панели был сломан в бою на всех роутерах.
# Замечено не сразу, потому что после перезагрузки панель поднимает автозапуск, а не
# restart. Тот же класс, что правило 25 и `armed_stop` в движке; подход взят оттуда:
# решаем по /proc/<pid>/cmdline и ПОЛНОМУ совпадению argv[0] с путём панели, свой PID
# и родителя пропускаем.
# pid_is_panel <pid> — принадлежит ли номер ИМЕННО панели.
#
# `kill -0 <pid>` отвечает на другой вопрос: «занят ли номер». После смерти
# панели её номер переиспользует любая следующая программа, и проверка честно
# скажет «работает». Замерено 03.09.2026 на роутере владельца: панели нет в `ps`,
# порт 8090 закрыт, curl отвечает кодом 7 — а `status` печатал «работает».
# Проверка, которая не может покраснеть, хуже отсутствующей: на неё полагаются.
#
# Тот же приём, что в kill_panel_procs ниже: argv[0] ЦЕЛИКОМ, а не подстрока.
pid_is_panel() {
	[ -n "$1" ] || return 1
	[ -r "$PROCROOT/$1/cmdline" ] || return 1
	_a0=$( { tr '\0' '\n' < "$PROCROOT/$1/cmdline"; } 2>/dev/null | head -1 )
	[ "$_a0" = "$BIN" ]
}

# kill_panel_procs — ЦЕЛИКОМ ПОД СТОРОЖЕМ ПО ВРЕМЕНИ (не дольше 5 с).
#
# 22.09.2026, разбор кота 1 и кота 2 по пяти зависшим `restart` на HERO:
# PPid у всех пяти — 1 (родитель уже умер, реparent на init), времена старта
# разбросаны на 21мин-3.5ч, ни одного совпадения с границей крона — то есть
# не гонка повторных вызовов, а КАЖДЫЙ ИЗ ПЯТИ САМ НИКОГДА НЕ ВЕРНУЛСЯ.
# Единственное место в этом файле, которое читает /proc ЧУЖОГО процесса
# (не своего pid-файла) в цикле по ВСЕМ pid — этот цикл. Чтение
# /proc/<pid>/cmdline процесса, застрявшего в непрерываемом ожидании ядра
# (D-state — обычная штука на встраиваемых системах при заминке в сетевом
# драйвере/NFQUEUE), блокируется НАВСЕГДА, без укладывающегося в разброс
# правдоподобного иного объяснения.
#
# Внешнего `timeout` на этом роутере не гарантировано (правило уже
# подтверждалось для другого компонента проекта) — свой сторож поверх `&`.
# Цена: раз в разы реже, чем сам повод, один проход может не долечить
# одного зависшего кандидата — следующий restart или watchdog (раз в
# минуту) досчитает.
kill_panel_procs() {
	( for d in "$PROCROOT"/[0-9]*; do
		p="${d##*/}"
		[ "$p" = "$$" ] && continue
		[ "$p" = "$PPID" ] && continue
		[ -r "$d/cmdline" ] || continue
		# argv[0] целиком, а не подстрока: имя скрипта и путь панели различаются
		# именно первым аргументом.
		a0=$( { tr '\0' '\n' < "$d/cmdline"; } 2>/dev/null | head -1 )
		[ "$a0" = "$BIN" ] || continue
		kill "$p" 2>/dev/null
	done ) &
	_kpw=$!
	( sleep 5; kill -9 "$_kpw" 2>/dev/null ) &
	_kpg=$!
	wait "$_kpw" 2>/dev/null
	kill "$_kpg" 2>/dev/null
}

stop() {
	# По номеру из pid-файла бьём ТОЛЬКО убедившись, что это наш процесс: номер
	# мёртвой панели мог достаться чужой программе, и слепой kill убил бы её.
	_p=$(cat "$PIDF" 2>/dev/null)
	if pid_is_panel "$_p"; then
		kill "$_p" 2>/dev/null
	fi
	rm -f "$PIDF"
	watchdog_stop
	kill_panel_procs
}

case "$1" in
	start) start ;;
	stop) stop ;;
	restart) stop; sleep 1; start ;;
	status)
		if pid_is_panel "$(cat "$PIDF" 2>/dev/null)"; then
			echo работает
		else
			echo остановлен
		fi
		;;
	*) echo "использование: $0 {start|stop|restart|status}" ;;
esac
