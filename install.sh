#!/bin/sh
# ============================================================
#  qwdtt installer  —  Keenetic (Entware) + OpenWRT
#  Автоопределение архитектуры, установка, init.d автозапуск.
# ============================================================
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ПАРАМЕТРЫ ПОДКЛЮЧЕНИЯ — ВПИСЫВАЮТСЯ ЗДЕСЬ                               │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Заполнил эти три строки — установка проходит ОДНОЙ КОМАНДОЙ и НЕ задаёт ни
# одного вопроса. Оставил пустыми — установщик спросит пароль и хеши, как
# спрашивал всегда (это и есть раздаваемый вид: в парковой копии строки пусты).
#
# Пир вписывать не нужно: он у нас один и стоит умолчанием ниже. Строка
# VSHITO_PEER существует для того дня, когда адрес сменится, — тогда правится
# одно место, а не память человека.
#
# ЧЕГО ЗДЕСЬ БЫТЬ НЕ ДОЛЖНО. Заполненный пароль превращает файл в СЕКРЕТ:
# кому дали файл — тому дали доступ. Поэтому заполненная копия НЕ КЛАДЁТСЯ В
# РАЗДАЧУ и не рассылается — она делается под один роутер и отдаётся его
# хозяину. В /var/www/qwdtt-bin/install.sh эти строки обязаны быть пустыми, и
# это проверяется прогоном (test-install.sh, раздел 19).
#
# Приоритет, от сильного к слабому:
#   1) переменная окружения  (PASSWORD=... sh install.sh)  — для наших прогонов;
#   2) вписанное здесь;
#   3) вопрос человеку.
# Так сделано намеренно: прогон обязан уметь подменить ЛЮБОЕ значение, не
# правя файл (правило 20 — иначе проверка ходит в боевое), а человек, вписавший
# строку, не обязан помнить про окружение.

VSHITO_PEER=""
VSHITO_PASSWORD=""
VSHITO_VK_HASHES=""

# ============================================================
#  ИСТОЧНИКИ БИНАРЕЙ (пробуются по порядку, до первого успешного).
#
#  Первым идёт ВНУТРЕННИЙ адрес шлюза — раздача по самому туннелю. Это
#  нужно там, где мобильный интернет режется по белому списку: туннель живёт
#  (он идёт через VK-релей), а скачивание с публичного адреса VPS уходит мимо
#  туннеля, туда, где закрыто. Добавить публичный адрес в список обхода нельзя:
#  как появится прямой TCP-путь клиент↔VPS, это станет петлёй.
#
#  Внутренний адрес один: 10.77.77.1 — шлюз RAW-режима. Второй, 10.66.66.1
#  (WG), СНЯТ 13.09.2026 вместе с самим модулем WireGuard — держать источник
#  для несуществующего шлюза значило бы ждать таймаут на каждой установке,
#  где такого шлюза уже физически нет (см. test-install.sh, «=== 16.
#  источника WG нет ни на одном адресе /16 ===», инвариант перевёрнут той же
#  датой). Берём только те источники, чья подсеть реально есть на
#  интерфейсах: иначе при установке с нуля, когда туннеля ещё нет, каждая
#  попытка висела бы до таймаута. Публичный адрес всегда последний — он же и
#  единственный при установке на чистый роутер.
# QWDTT_PUBLIC_BASE_URL — ТОЛЬКО для прогонов. Без этой возможности проверка
# установщика ходила бы в БОЕВУЮ раздачу и проверяла бы её, а не себя
# (правило 20 в CLAUDE.md — на этом уже сгорели тесты панели).
# Через `-`, а не `:-`: ЯВНО заданное пустое значение означает «публичного
# источника нет», а не «возьми боевой по умолчанию». Разница не теоретическая:
# с `:-` прогон с пустым адресом молча уходил в БОЕВУЮ раздачу и «успешно»
# ставил боевые файлы — то есть проверял не установщик, а её.
# QWDTT_CHANNEL — ОДНА переменная, ОДИН путь раздачи для ВСЕХ источников
# сразу (правило/инвариант 36: путь раздачи — одна функция на все источники,
# не три раздельных). 22.09.2026, живой случай: тестировщик с QWDTT_CHANNEL=
# beta получил боевой клиент и движок — внутренний источник шлюза
# (10.77.77.1:8080) был зашит константой «/bin» прямо в build_base_urls() и
# ни один канал его не трогал, пока PUBLIC_BASE_URL/PUBLIC_BASE_URL_RU кто-то
# (вызывающий скрипт, вручную) подменял на /beta по отдельности — то есть
# ТРИ источника решались ТРЕМЯ разными путями, и один остался забыт молча.
# Теперь канал ОДИН, читается ЗДЕСЬ, и от него зависят все источники по
# умолчанию разом — новый источник добавится к этому же правилу, а не заведёт
# четвёртое место для той же развилки.
QWDTT_CHANNEL="${QWDTT_CHANNEL:-bin}"
case "$QWDTT_CHANNEL" in
	bin|beta) ;;
	*) echo "ОТКАЗ: QWDTT_CHANNEL='$QWDTT_CHANNEL' неизвестен. Можно: bin, beta" >&2; exit 1 ;;
esac
# ЭКСПОРТ — ОБЯЗАТЕЛЕН. 22.09.2026, живой случай (тестировщик 2): install.sh
# ЗНАЛ QWDTT_CHANNEL=beta, а ustanovka-dns.sh (вызывается ниже, ОТДЕЛЬНЫМ
# процессом через `sh "$DNS_INSTALLER"`) канал не получал вовсе — обычная
# shell-переменная не переживает границу процесса, только ЭКСПОРТИРОВАННАЯ.
# Шаг DNS беты молча ставил ПРОД (meridian-dns 0.16 вместо 0.35 из беты).
export QWDTT_CHANNEL

PUBLIC_BASE_URL="${QWDTT_PUBLIC_BASE_URL-http://138.124.78.252:8080/$QWDTT_CHANNEL}"

# QWDTT_PUBLIC_BASE_URL_RU -- ВТОРОЙ публичный источник, 15.09.2026: у части
# клиентов из РФ режется путь до dl.meridianvpn.org (Cloudflare) на самой
# СТАРТОВОЙ команде (см. bot.py) -- ту команду отсюда не починить, install.sh
# к тому моменту ещё не скачан. Но у основного адреса ВЫШЕ (прямой IP, порт
# 8080, БЕЗ Cloudflare) тот же класс риска остаётся на случай, если резать
# станут не только облако Cloudflare, но и сам этот IP. Второй источник --
# сервер физически в РФ, обычный HTTP, без TLS вовсе (см. комментарий в
# /root/sync-ru-mirror.sh -- секретности тут защищать нечего, сумму каждого
# файла install.sh и так сверяет сам).
#
# У RU-зеркала БЕТЫ ПОКА НЕТ (см. /root/sync-ru-mirror.sh) — при
# QWDTT_CHANNEL=beta этот источник просто ОТКЛЮЧЁН по умолчанию (пусто), а не
# молча указывает на боевой /bin: подставить чужой канал тайком хуже, чем не
# подставить источник вовсе (правило 39 — пустой список честнее ложного).
if [ "$QWDTT_CHANNEL" = beta ]; then
	PUBLIC_BASE_URL_RU="${QWDTT_PUBLIC_BASE_URL_RU-}"
else
	# ПУСТОЕ ЗНАЧЕНИЕ = ОТКЛЮЧЕНО, тем же приёмом через `-`, что и выше: прогон
	# теста способен явно обнулить оба публичных источника и не уйти в боевые.
	PUBLIC_BASE_URL_RU="${QWDTT_PUBLIC_BASE_URL_RU-http://45.10.247.23/$QWDTT_CHANNEL}"
fi

have_local_net() {
	# $1 — префикс адреса, например "10.77.77."
	if command -v ip >/dev/null 2>&1; then
		ip -4 addr show 2>/dev/null | grep -q "inet $1"
	elif command -v ifconfig >/dev/null 2>&1; then
		ifconfig 2>/dev/null | grep -q "addr:$1\|inet $1"
	else
		return 1
	fi
}

# local_ipv4 — все наши IPv4, по одному в строке.
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

# same_net16 — есть ли у нас адрес в ОДНОЙ /16 с указанным шлюзом.
#
# ПОЧЕМУ НЕ ПРЕФИКС СТРОКОЙ, как было до 31.08.2026. Прежняя проверка строила
# префикс отбрасыванием последнего октета — то есть всегда /24: у шлюза
# 10.66.66.1 получалось «10.66.66.», и роутер с адресом 10.66.0.5 совпадения не
# давал. Подсеть WG расширена 25.08 до 10.66.0.0/16, новые роутеры получают
# 10.66.0.x — и внутренний источник обновлений МОЛЧА выпадал из списка,
# оставляя только публичный адрес. Молча — потому что установка при этом
# проходит; заметно стало бы лишь там, где публичный путь недоступен, а у
# клиентов за CGNAT это ровно тот случай, где внутренний источник единственный.
#
# Адрес самого шлюза НЕ менялся: 10.66.66.1 и 10.77.77.1 прежние. Здесь правится
# только проверка «мой ли это адрес», а не список источников.
#
# Сравниваются ЧИСЛА октетов, а не начало строки: строковое сравнение молча
# перестаёт значить задуманное при любой смене маски, а число — нет.
same_net16() {
	_addrs=$(local_ipv4) || return 1
	[ -n "$_addrs" ] || return 1
	echo "$_addrs" | awk -v gw="$1" '
		BEGIN { split(gw, g, ".") }
		{ split($1, o, "."); if (o[1] == g[1] && o[2] == g[2]) { found = 1 } }
		END { exit found ? 0 : 1 }'
}

build_base_urls() {
	# Явные if вместо «check && urls=...»: под set -e список A && B со
	# сработавшим «нет» имеет статус 1 и уронил бы подстановку команды.
	#
	# Склейка через ${_urls:+$_urls } — чтобы не было ни ведущего пробела, ни
	# пустых элементов. Раньше при пустом $_urls список начинался с пробела, и
	# строка «Источники обновлений:  http://…» с двумя пробелами читалась как
	# «первый источник пустой». Сам цикл `for base in $BASE_URLS` пустые поля
	# отбрасывает, то есть беды от этого не было, — но диагноз по такому выводу
	# ставится неверный, а это стоит времени в аварии (18.08.2026 стоило).
	_urls=""
	# QWDTT_INTERNAL_BASES — ТОЛЬКО для прогонов: список внутренних адресов шлюза
	# видом «10.77.77.1 10.66.66.1». Пустое значение означает «внутренних
	# источников нет». Без этой возможности проверка установщика ходила бы в
	# БОЕВОЙ шлюз: он живёт на той же машине, где гоняются проверки, и его
	# подсеть на ней есть — то есть тест проверял бы боевую раздачу вместо себя
	# (правило 20, уже стоило нам зелёных тестов панели).
	# WG (10.66.66.1) СНЯТ 13.09.2026 вместе с самим модулем — умолчание
	# держит только живой шлюз RAW-режима.
	for _ip in ${QWDTT_INTERNAL_BASES-10.77.77.1}; do
		if same_net16 "$_ip"; then
			# ТОТ ЖЕ $QWDTT_CHANNEL, что и у публичных источников выше — не
			# отдельная константа «/bin». Это и есть правка 22.09.2026.
			_urls="${_urls:+$_urls }http://$_ip:8080/$QWDTT_CHANNEL"
		fi
	done
	# GITHUB — ОСНОВНОЙ ПУБЛИЧНЫЙ ИСТОЧНИК, 15.09.2026: владелец, дословно,
	# «сделай основным зеркало на гитхабе». Ветка (entware/openwrt) уже
	# подставлена в PUBLIC_BASE_URL_GH ДО вызова этой функции — build_base_urls
	# вызывается ПОСЛЕ detect_platform именно ради этого (см. место вызова).
	[ -n "$PUBLIC_BASE_URL_GH" ] && _urls="${_urls:+$_urls }$PUBLIC_BASE_URL_GH"
	_urls="${_urls:+$_urls }$PUBLIC_BASE_URL"
	# RU-зеркало ПОСЛЕДНИМ: у большинства клиентов основной путь и так
	# работает, а RU-сервер медленнее для тех, кто не в РФ, — пробуем его
	# только когда первые источники отказали.
	[ -n "$PUBLIC_BASE_URL_RU" ] && _urls="$_urls $PUBLIC_BASE_URL_RU"
	echo "$_urls"
}

# base_urls_sane — в списке источников нет пустых элементов и он не пуст.
# Отдельной функцией, чтобы это проверял и прогон, и публикация: пустой источник
# обязан быть заметной ошибкой при выкате, а не тихим первым элементом.
base_urls_sane() {
	_list="${1:-$BASE_URLS}"
	case "$_list" in
		"" ) echo "список источников пуст"; return 1 ;;
		" "*|*"  "*|*" " ) echo "в списке источников пустой элемент: «$_list»"; return 1 ;;
	esac
	for _u in $_list; do
		case "$_u" in
			http://*|https://*) : ;;
			*) echo "источник не похож на адрес: «$_u»"; return 1 ;;
		esac
	done
	return 0
}

# BASE_URLS СОБИРАЕТСЯ НИЖЕ, ПОСЛЕ detect_platform — не здесь. GitHub-адрес
# (PUBLIC_BASE_URL_GH) зависит от ветки entware/openwrt, а на этом месте
# файла $PLATFORM ещё не определён. Между этой строкой и первым реальным
# использованием $DL/BASE_URLS (pick_downloader, внутри check_env в самом
# низу файла) ничего их не трогает — перенос безопасен, проверено просмотром
# всех мест вызова 15.09.2026.
# ============================================================

set -e

# Пути. Переменные QWDTT_* — ТОЛЬКО для прогонов: установку нельзя проверять
# установкой на живой роутер, а не проверять её — это ровно то, чем обернулась
# авария 18.08.2026 (новый клиент не смог поставиться дважды подряд).
# ---------- ПЛАТФОРМА: Entware или нативный OpenWrt ----------
#
# ДВЕ РАЗНЫЕ СИСТЕМЫ, А НЕ ОДНА С ОГОВОРКАМИ. На Keenetic всё живёт в /opt —
# это каталог Entware, добавленный поверх прошивки. На нативном OpenWrt /opt
# нет вовсе: бинари идут в /usr/sbin, настройки в /etc, автозапуск — procd в
# /etc/init.d. Один и тот же файл install.sh обслуживает обе, и путать их
# нельзя: установка «как на Keenetic» на OpenWrt кладёт файлы туда, где их
# никто не ищет, и роутер выглядит установленным, не будучи им.
#
# КАК РАЗЛИЧАЕМ. По наличию Entware, а не по наличию procd: procd есть и на
# тех Keenetic, где рядом стоит Entware, а /opt/etc/init.d — признак именно
# Entware. Порядок проверки поэтому такой: сначала Entware, потом OpenWrt.
#
# QWDTT_PLATFORM — крючок для стенда: воспроизвести нативный OpenWrt на машине
# сборки иначе нечем, а ошибка в путях видна только на живом роутере.
detect_platform() {
	if [ -n "${QWDTT_PLATFORM:-}" ]; then
		PLATFORM="$QWDTT_PLATFORM"
		return 0
	fi
	if [ -d /opt/etc/init.d ] || [ -d /opt/bin ]; then
		PLATFORM="entware"
		return 0
	fi
	if [ -d /etc/init.d ] && { [ -f /etc/rc.common ] || [ -x /sbin/procd ] || [ -x /usr/sbin/procd ]; }; then
		PLATFORM="openwrt"
		return 0
	fi
	# Ни того, ни другого — это НЕ «наверное Entware». Молча выбрать платформу
	# значит разложить файлы наугад; отказ здесь дешевле половинной установки.
	PLATFORM=""
	return 1
}

detect_platform || true

# ВЕТКА GITHUB ПО ПЛАТФОРМЕ — entware/openwrt используют РАЗНЫЕ бинарники
# (qwdtt-web-arm64 против qwdtt-web-arm64-openwrt и т.д.), поэтому ветка
# выбирается здесь, сразу после того как $PLATFORM стал известен, и ПЕРЕД
# первым построением BASE_URLS. Пустая строка (QWDTT_PUBLIC_BASE_URL_GH="")
# отключает источник — тем же приёмом через `-`, что и у остальных
# PUBLIC_BASE_URL* переменных: прогон способен явно обнулить его.
GH_BRANCH="entware"
[ "${PLATFORM:-}" = "openwrt" ] && GH_BRANCH="openwrt"
# GITHUB — ТОЛЬКО ДЛЯ КАНАЛА bin. 22.09.2026, живой случай (тестировщик 2):
# ветка на GitHub всегда ПРОД (entware/openwrt, не завязана на QWDTT_CHANNEL
# вовсе) — раздачи под бету там нет и не заводили. При QWDTT_CHANNEL=beta
# источник молча предлагал прод-файлы вперемешку с честной бетой из
# остальных источников. Тем же приёмом, что уже применён к RU-зеркалу
# (PUBLIC_BASE_URL_RU выше): при beta источник просто ОТКЛЮЧЁН.
if [ "$QWDTT_CHANNEL" = beta ]; then
	PUBLIC_BASE_URL_GH="${QWDTT_PUBLIC_BASE_URL_GH-}"
else
	PUBLIC_BASE_URL_GH="${QWDTT_PUBLIC_BASE_URL_GH-https://raw.githubusercontent.com/JinComputers/meridian-router/$GH_BRANCH}"
fi
BASE_URLS=$(build_base_urls)

if [ "${PLATFORM:-}" = "openwrt" ]; then
	# НАТИВНЫЙ OpenWrt. Пути замерены по shag2/shag3, которыми мы ставили
	# вручную весь сентябрь, а не взяты по аналогии с Entware.
	INSTALL_DIR="${QWDTT_INSTALL_DIR:-/usr/sbin}"
	CONF_DIR="${QWDTT_CONF_DIR:-/etc/qwdtt}"
	# Лога-файла у клиента здесь НЕТ: под procd он пишет в logd, и файл не
	# появится никогда. Путь всё равно задан — его ждут mkdir и уборка, — но
	# смотреть журнал надо через logread.
	LOG_FILE="${QWDTT_LOG_FILE:-/var/log/qwdtt.log}"
	RUN_DIR="${QWDTT_RUN_DIR:-/tmp/qwdtt-run}"
	# Копии прежних версий — в /etc/qwdtt/backup, а не в /opt/var/backup:
	# второго раздела здесь нет, и всё наше должно лежать в одном месте.
	BACKUP_DIR="${QWDTT_BACKUP_DIR:-/etc/qwdtt/backup}"
else
	INSTALL_DIR="${QWDTT_INSTALL_DIR:-/opt/bin}"
	CONF_DIR="${QWDTT_CONF_DIR:-/opt/etc/qwdtt}"
	LOG_FILE="${QWDTT_LOG_FILE:-/opt/var/log/qwdtt.log}"
	RUN_DIR="${QWDTT_RUN_DIR:-/tmp/qwdtt-run}"
	BACKUP_DIR="${QWDTT_BACKUP_DIR:-/opt/var/backup/qwdtt}"
fi
CONF_FILE="$CONF_DIR/qwdtt.conf"
DEVICE_ID_FILE="$CONF_DIR/.device_id"
BIN_PATH="$INSTALL_DIR/qwdtt"
INITD_ENTWARE_DIR="${QWDTT_INITD_ENTWARE_DIR:-/opt/etc/init.d}"
# Каталог автозапусков OpenWrt — ПЕРЕМЕННОЙ по той же причине, что и всё
# остальное: стенд обязан писать в поддельное дерево, а не в настоящий /etc.
# Проверка «файл лёг куда надо» без этого превратилась бы в запись на машине
# сборки — то есть проверяла бы её, а не установщик (правило 20).
INITD_OPENWRT_DIR="${QWDTT_INITD_OPENWRT_DIR:-/etc/init.d}"
RCD_OPENWRT_DIR="${QWDTT_RCD_OPENWRT_DIR:-/etc/rc.d}"

# ЖУРНАЛ УСТАНОВКИ — полный вывод; на экран идёт короткий (владелец 02.10.2026: «вывод строчек установщика сократить,
# оставить диагностику для нас»). QWDTT_VERBOSE=1 — как раньше, всё на экран.
if [ -z "${QWDTT_INSTALL_LOG:-}" ]; then
	if [ -d /opt/var/log ]; then QWDTT_INSTALL_LOG=/opt/var/log/meridian-install.log; else QWDTT_INSTALL_LOG=/tmp/meridian-install.log; fi
fi
: > "$QWDTT_INSTALL_LOG" 2>/dev/null || QWDTT_INSTALL_LOG=/dev/null
# say — подробность: всегда в журнал; на экран — при QWDTT_VERBOSE=1 или если это предупреждение/сбой.
say() {
	echo "[meridian] $1" >> "$QWDTT_INSTALL_LOG" 2>/dev/null
	case "${QWDTT_VERBOSE:-0}:$1" in
		1:*|0:*ВНИМАНИЕ*|0:*ОШИБКА*|0:*ОТКАЗ*|0:*"!!!"*|0:*"не встал"*|0:*"не скача"*|0:*"не удалось"*|0:*"не поставил"*|0:*"НАПИШИ"*) echo "[meridian] $1" ;;
	esac
	return 0
}
# etap — название этапа: всегда на экран и в журнал.
etap() { echo "[meridian] $1"; echo "[meridian] $1" >> "$QWDTT_INSTALL_LOG" 2>/dev/null; return 0; }
# vecho — echo только при QWDTT_VERBOSE=1 (рамки и повторы).
vecho() { [ "${QWDTT_VERBOSE:-0}" = 1 ] && echo "$@"; return 0; }


# ---------- СОСТАВ НАТИВНОГО OpenWrt ----------
#
# ЧТО СТАВИТСЯ И КУДА (пути замерены по shag2/shag3, которыми мы ставили
# вручную весь сентябрь, а не выведены по аналогии с Entware):
#
#   /usr/sbin/qwdtt-run            запускатель клиента (procd не умеет stdin)
#   /etc/init.d/qwdtt              автозапуск клиента
#   /etc/qwdtt/meridian.nft        таблица inet meridian: наборы и пометка
#   /etc/init.d/meridian-nft       загрузчик этой таблицы
#   /usr/sbin/meridian-mode        переключатель чёрного/белого режима
#   /usr/sbin/meridian-antidpi     анти-DPI (+ ctl, init, antidpi.nft), если есть модули ядра
#   /etc/init.d/meridian-lan       защита LAN от совпадения с апстримом
#   /etc/init.d/meridian-route-min движок маршрута по метке
#   /usr/sbin/meridian-route-hold  предохранитель
#   /usr/sbin/meridian-dns         сервер DNS (владелец модели доменов)
#   /etc/init.d/meridian-dns       его автозапуск
#
# ПОЧЕМУ ОТДЕЛЬНОЙ ФУНКЦИЕЙ, А НЕ ВНУТРИ ОБЩЕГО ПОТОКА: на Entware ничего из
# этого нет и быть не должно. Смешав, мы получили бы ветвления в каждом шаге и
# однажды поставили бы кусок OpenWrt на Keenetic.
install_openwrt_part() { # install_openwrt_part <имя> <куда> <права> <вид: elf|script>
	_p_name="$1"; _p_dest="$2"; _p_mode="${3:-755}"; _p_kind="${4:-script}"
	note_created "$_p_dest"
	owrt_otlozhit "$_p_dest"
	# ВИД ФАЙЛА ПЕРЕДАЁТСЯ ЯВНО. fetch_to_target по умолчанию ждёт ELF, и
	# скрипт с шебангом она отвергает как «источник отдал не то» — отказ верный
	# по форме и бессмысленный по сути. Стенд поймал это на первом же прогоне:
	# клиент лёг, а qwdtt-run — нет, и причина в вызове, а не в файле.
	if ! fetch_to_target "$_p_name" "$_p_dest" 500 "$_p_kind"; then
		die "Не установить $_p_name в $_p_dest"
	fi
	chmod "$_p_mode" "$_p_dest" 2>/dev/null || true
	say "  поставлен: $_p_dest"
}

# enable_openwrt_service — включить автозапуск И ПРОВЕРИТЬ ФАКТ.
#
# `enable` у rc.common возвращает 0 и когда ссылка появилась, и когда нет
# (замер кота 1 в shag2). Поэтому смотрим на симлинк в /etc/rc.d, а не на код
# возврата: иначе «автозапуск настроен» окажется зелёным на роутере, где после
# перезагрузки ничего не поднимется.
enable_openwrt_service() { # enable_openwrt_service <имя>
	_e_name="$1"
	[ -x "$INITD_OPENWRT_DIR/$_e_name" ] || { say "  !!! нет $INITD_OPENWRT_DIR/$_e_name — включать нечего"; return 1; }
	# Прежние ссылки ЭТОЙ службы снимаем до enable (авария 30.09.2026: у клиента
	# остались и S99qwdtt от раннего init, и S95qwdtt от нового).
	"$INITD_OPENWRT_DIR/$_e_name" disable >/dev/null 2>&1 || true
	rm -f "$RCD_OPENWRT_DIR"/S[0-9][0-9]"$_e_name" "$RCD_OPENWRT_DIR"/K[0-9][0-9]"$_e_name" 2>/dev/null || true
	"$INITD_OPENWRT_DIR/$_e_name" enable >/dev/null 2>&1 || true
	if ls "$RCD_OPENWRT_DIR"/*"$_e_name" >/dev/null 2>&1; then
		say "  автозапуск включён: $_e_name"
		return 0
	fi
	# ИНИТ НЕ ПОД procd (meridian-lan, Кот 1 27.09.2026): enable молчит и
	# ссылку не ставит. Порядок старта назван в самом init строкой START= —
	# по нему ставим ссылку сами и говорим об этом прямо. Без START= не
	# угадываем: номер наугад хуже честного «не включился».
	_e_start=$(sed -n 's/^START=\([0-9][0-9]*\).*/\1/p' "$INITD_OPENWRT_DIR/$_e_name" 2>/dev/null | head -1)
	if [ -n "$_e_start" ]; then
		mkdir -p "$RCD_OPENWRT_DIR" 2>/dev/null || true
		ln -sf "../init.d/$_e_name" "$RCD_OPENWRT_DIR/S$_e_start$_e_name" 2>/dev/null || true
		if ls "$RCD_OPENWRT_DIR"/*"$_e_name" >/dev/null 2>&1; then
			say "  автозапуск включён: $_e_name (ссылка S$_e_start поставлена вручную — enable её не создал)"
			return 0
		fi
	fi
	say "  !!! автозапуск $_e_name НЕ включился — после перезагрузки служба не поднимется"
	say "      проверить: /etc/init.d/$_e_name enabled ; ls -l /etc/rc.d/ | grep $_e_name"
	return 1
}

install_openwrt_stack() {
	[ "$PLATFORM" = "openwrt" ] || return 0
	say "=== Состав для OpenWrt ==="

	# 1. ЗАПУСКАТЕЛЬ И АВТОЗАПУСК КЛИЕНТА.
	#
	# qwdtt-run обязателен: procd не умеет передавать stdin, а клиент читает
	# оттуда команды, и ЧУЖАЯ СТРОКА ГАСИТ ЕГО (замер 10.09.2026). Плюс он
	# отдаёт клиенту путь конфига: без этого клиент ищет парковый
	# /opt/etc/qwdtt/qwdtt.conf, не находит и МОЛЧА берёт умолчания — все
	# одиннадцать настроек сразу.
	install_openwrt_part "qwdtt-run" "$INSTALL_DIR/qwdtt-run" 755 script
	install_openwrt_part "qwdtt-init-openwrt" "$INITD_OPENWRT_DIR/qwdtt" 755 script

	# 2. ЭКРАН: таблица, загрузчик, защита LAN, движок маршрута, предохранитель.
	# Таблица nft — НЕ ELF и НЕ обычный скрипт, но у неё есть шебанг
	# (#!/usr/sbin/nft -f), поэтому проверка «script» ей подходит: она смотрит
	# именно на шебанг, а не на права.
	# РЕЖИМЫ (Кот 1, блок BL, 27.09.2026): таблица с наборами белого режима,
	# её загрузчик и переключатель meridian-mode. Имена в раздаче — с
	# суффиксом -openwrt: прежние meridian.nft/meridian-nft остаются для
	# старых установщиков, и новое содержимое не должно уехать к ним молча.
	install_openwrt_part "meridian.nft-openwrt" "$CONF_DIR/meridian.nft" 644 script
	install_openwrt_part "meridian-nft-init-openwrt" "$INITD_OPENWRT_DIR/meridian-nft" 755 script
	install_openwrt_part "meridian-mode-openwrt" "$INSTALL_DIR/meridian-mode" 755 script
	# СНИМКИ «RU НАПРЯМУЮ» (белый режим, владелец 27.09.2026). Замороженные,
	# имя с датой: новый снимок — новое имя здесь, старый роутер не получит
	# другой список молча. Из них meridian-mode Кота 1 сам делает наборы
	# meridian_ru4/meridian_rudns4 и конфиг dnsmasq — у набора один хозяин.
	install_openwrt_part "ru-ranges-2026.08.18.txt" "$CONF_DIR/ru-ranges.txt" 644 list
	install_openwrt_part "ru-domains-2026.09.25.txt" "$CONF_DIR/ru-domains.txt" 644 list
	# ДОМЕННАЯ ПОЛОВИНА RU-напрямую (Кот 1, 27.09.2026): готовая политика для
	# meridian-dns, набор meridian_direct_dns4. meridian-dns читает её сам на
	# рестарте — отдельной команды не нужно. ru-domains.txt выше — источник для
	# будущей регенерации этого файла, сам он в дело не идёт.
	install_openwrt_part "meridian-dns-napryamuyu.yaml" "$CONF_DIR/meridian-dns-napryamuyu.yaml" 644 yaml
	install_openwrt_part "meridian-lan" "$INITD_OPENWRT_DIR/meridian-lan" 755 script
	install_openwrt_part "meridian-route-min" "$INITD_OPENWRT_DIR/meridian-route-min" 755 script
	install_openwrt_part "meridian-route-hold" "$INSTALL_DIR/meridian-route-hold" 755 script

	# 3. СЕРВЕР DNS — владелец модели доменов.
	install_openwrt_part "$(dist_name "meridian-dns-$ARCH")" "$INSTALL_DIR/meridian-dns" 755 elf
	install_openwrt_part "meridian-dns-init-openwrt" "$INITD_OPENWRT_DIR/meridian-dns" 755 script

	# ФАЙЛ МОДЕЛИ ДОМЕНОВ — установщик ставил бинарь и автозапуск сервера DNS, но
	# никогда не создавал файл, без которого сервер падает при старте (LoadRules
	# фатально завершается, procd уходит в респавн раз в 5 секунд — выглядит как
	# «не стартует», а на деле циклически падает). Найдено 14.09.2026 на живом
	# роутере владельца КОТОМ 1: /etc/qwdtt/meridian-dns.yaml просто не было.
	#
	# ИДЕМПОТЕНТНОСТЬ ОБЯЗАТЕЛЬНА: install.sh зовётся и на чистой установке, и на
	# обновлении уже настроенного роутера. Если файл уже есть — НЕ ТРОГАТЬ его
	# никогда, иначе обновление сотрёт реальный список доменов владельца поверх
	# пустого. Формат и путь — по слову КОТА 1 (владельца модели), точь-в-точь
	# как в его собственном shag3.
	mkdir -p "$CONF_DIR"
	if [ ! -f "$CONF_DIR/meridian-dns.yaml" ]; then
		echo "groups: []" > "$CONF_DIR/meridian-dns.yaml"
		chmod 644 "$CONF_DIR/meridian-dns.yaml"
		say "Файл модели доменов создан пустым: $CONF_DIR/meridian-dns.yaml"
	fi

	# 4. АВТОЗАПУСКИ. Порядок важен: сначала защита LAN и таблица, потом клиент,
	# потом маршрут по метке и сервер DNS. Клиент, поднятый раньше таблицы,
	# работает — но помечать его трафик будет нечем до первой перезагрузки.
	for _s in meridian-lan meridian-nft qwdtt meridian-route-min meridian-dns; do
		enable_openwrt_service "$_s" || OPENWRT_AUTOSTART_INCOMPLETE=1
	done
}

# ---------- OpenWrt: копии перед заменой, откат, перезапуск, анти-DPI ----------
#
# 27.09.2026, релиз OpenWrt Кота 1. До этого замена на OpenWrt шла mv поверх
# стоящего файла без копии, а службы только включались (enable) — обновление
# выглядело прошедшим, а работал старый код до перезагрузки.
OWRT_UNDO=""
OWRT_PREV_DIR="$BACKUP_DIR/prev"
ANTIDPI_DIR="${QWDTT_ANTIDPI_DIR:-/etc/meridian-antidpi}"
ANTIDPI_STATUS="${QWDTT_ANTIDPI_STATUS:-/var/run/meridian-antidpi.status}"

# owrt_otlozhit ФАЙЛ — снять копию того, что сейчас стоит (один раз за
# запуск). Жёсткая ссылка: ноль байт сейчас, а после mv нового поверх она
# держит прежний файл. Не вышла ссылка — cp -p и сверка размером.
owrt_otlozhit() {
	[ "${PLATFORM:-}" = "openwrt" ] || return 0
	[ -f "$1" ] || return 0
	case " $OWRT_UNDO " in *" $1|"*) return 0 ;; esac
	mkdir -p "$OWRT_PREV_DIR" 2>/dev/null || die "не создать каталог копий $OWRT_PREV_DIR"
	_o_bak="$OWRT_PREV_DIR/$(echo "$1" | tr '/' '_').prev"
	rm -f "$_o_bak" 2>/dev/null
	if ! ln -f "$1" "$_o_bak" 2>/dev/null; then
		cp -p "$1" "$_o_bak" 2>/dev/null \
			&& [ "$(wc -c < "$_o_bak")" = "$(wc -c < "$1")" ] \
			|| { rm -f "$_o_bak"; die "копия $1 не снялась или записалось не полностью — дальше не иду, живое не тронуто"; }
	fi
	OWRT_UNDO="$OWRT_UNDO $1|$_o_bak"
}

# owrt_vernut_vse — вернуть всё заменённое в этом запуске (только mv) и
# поднять экран заново: stop прежнего meridian-nft мог снести запрет утечки,
# держатель ставит его при старте.
owrt_vernut_vse() {
	[ -n "$OWRT_UNDO" ] || return 0
	echo "[meridian] возвращаю заменённое (только mv):" >&2
	for _o_p in $OWRT_UNDO; do
		_o_d="${_o_p%%|*}"; _o_b="${_o_p#*|}"
		[ -f "$_o_b" ] || continue
		mv -f "$_o_b" "$_o_d" 2>/dev/null && echo "[meridian]   вернул $_o_d" >&2
	done
	OWRT_UNDO=""
	if [ "${PLATFORM:-}" = "openwrt" ]; then
		[ -x "$INITD_OPENWRT_DIR/meridian-nft" ] && "$INITD_OPENWRT_DIR/meridian-nft" restart >/dev/null 2>&1 || true
		[ -x "$INITD_OPENWRT_DIR/meridian-route-min" ] && "$INITD_OPENWRT_DIR/meridian-route-min" restart >/dev/null 2>&1 || true
		[ -x "$INITD_OPENWRT_DIR/meridian-dns" ] && "$INITD_OPENWRT_DIR/meridian-dns" restart >/dev/null 2>&1 || true
	fi
	return 0
}

# owrt_snyat_kopii — после успеха копии не нужны: на флеше OpenWrt модули
# заняли бы место дважды.
owrt_snyat_kopii() {
	for _o_p in $OWRT_UNDO; do
		rm -f "${_o_p#*|}" 2>/dev/null
	done
	if [ -n "$OWRT_UNDO" ]; then say "копии прежних версий сняты: всё новое проверено"; fi
	OWRT_UNDO=""
	return 0
}

owrt_sha() { if [ -f "$1" ] && command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; fi; return 0; }
owrt_tunnel() { ping -c 1 -W 3 10.77.77.1 >/dev/null 2>&1; }

# owrt_zapomnit — ДО замены клиента и панели: что стояло и жив ли туннель.
OWRT_KL_SHA0=""; OWRT_WEB_SHA0=""; OWRT_TUN0=0
owrt_zapomnit() {
	[ "${PLATFORM:-}" = "openwrt" ] || return 0
	OWRT_KL_SHA0=$(owrt_sha "$BIN_PATH")
	[ -f "$CONF_DIR/meridian-mode.state" ] && OWRT_REZHIM_BYL=1
	OWRT_WEB_SHA0=$(owrt_sha "$INSTALL_DIR/qwdtt-web")
	if [ -n "$OWRT_KL_SHA0" ] && owrt_tunnel; then OWRT_TUN0=1; fi
	owrt_otlozhit "$BIN_PATH"
	owrt_otlozhit "$INSTALL_DIR/qwdtt-web"
}

owrt_pol() { nft list table inet meridian 2>/dev/null | grep -c meridian_pol || true; }

# ustanovit_antidpi_openwrt — анти-DPI Кота 1. Не валит установку: нет модулей
# ядра — не ставим и говорим; не поднялся — откатываем только его.
ustanovit_antidpi_openwrt() {
	say "=== Анти-DPI ==="
	lsmod 2>/dev/null | grep -q '^nfnetlink_queue' || modprobe nfnetlink_queue 2>/dev/null || true
	lsmod 2>/dev/null | grep -q '^nft_queue' || modprobe nft_queue 2>/dev/null || true
	if ! lsmod 2>/dev/null | grep -q '^nft_queue'; then
		say "  модуля ядра nft_queue нет — ставлю пакет kmod-nft-queue"
		install_pkg_openwrt kmod-nft-queue || true
		modprobe nfnetlink_queue 2>/dev/null || true; modprobe nft_queue 2>/dev/null || true
	fi
	if ! lsmod 2>/dev/null | grep -q '^nft_queue' || ! lsmod 2>/dev/null | grep -q '^nfnetlink_queue'; then
		say "  анти-DPI НЕ ставлю: нет модулей ядра nfnetlink_queue/nft_queue (пакет kmod-nft-queue не встал). Остальное работает"
		return 0
	fi
	_a_undo0="$OWRT_UNDO"
	mkdir -p "$ANTIDPI_DIR" || die "не создать $ANTIDPI_DIR"
	install_openwrt_part "$(dist_name "meridian-antidpi-$ARCH")" "$INSTALL_DIR/meridian-antidpi" 755 elf
	install_openwrt_part "meridian-antidpi.nft" "$ANTIDPI_DIR/antidpi.nft" 644 script
	install_openwrt_part "meridian-antidpi-init-openwrt" "$INITD_OPENWRT_DIR/meridian-antidpi" 755 script
	install_openwrt_part "meridian-antidpi-ctl" "$INSTALL_DIR/meridian-antidpi-ctl" 755 script
	# nfqws2 делит с нами трафик — выключаем, НЕ удаляем (Кот 1).
	_a_nfq=""; _a_nfq_en=0; _a_nfq_run=0
	for _a_f in "$INITD_OPENWRT_DIR"/*nfqws*; do [ -x "$_a_f" ] && { _a_nfq="$_a_f"; break; }; done
	if [ -n "$_a_nfq" ]; then
		if "$_a_nfq" enabled 2>/dev/null; then _a_nfq_en=1; "$_a_nfq" disable >/dev/null 2>&1 || true; fi
		if pidof nfqws2 >/dev/null 2>&1; then _a_nfq_run=1; "$_a_nfq" stop >/dev/null 2>&1 || true; fi
		say "  nfqws2: остановлен и выключен из автозапуска (не удалён; вернуть: $_a_nfq enable; $_a_nfq start)"
	fi
	enable_openwrt_service meridian-antidpi || true
	"$INITD_OPENWRT_DIR/meridian-antidpi" restart >/dev/null 2>&1 || true
	_a_ok=0; _a_i=0
	while [ "$_a_i" -lt 10 ]; do
		[ -s "$ANTIDPI_STATUS" ] && { _a_ok=1; break; }
		_a_i=$((_a_i + 1)); sleep 1
	done
	_a_why=""
	[ "$_a_ok" = 1 ] || _a_why="движок не написал файл состояния за 10 с"
	[ -z "$_a_why" ] && ! pidof meridian-antidpi >/dev/null 2>&1 && _a_why="процесса meridian-antidpi нет"
	[ -z "$_a_why" ] && ! nft list chain inet meridian_antidpi post 2>/dev/null | grep -q 'queue.*301' && _a_why="в таблице нет правил очереди 301"
	[ -z "$_a_why" ] && ! grep -q '^queue=301$' "$ANTIDPI_STATUS" && _a_why="движок слушает не очередь 301"
	if [ -z "$_a_why" ]; then
		say "  анти-DPI работает (очередь 301, bypass)"
		return 0
	fi
	# ОТКАТ ТОЛЬКО АНТИ-DPI: остальное уже проверено и работает.
	say "  !!! анти-DPI не поднялся: $_a_why — возвращаю как было (logread -e antidpi)"
	"$INITD_OPENWRT_DIR/meridian-antidpi" stop >/dev/null 2>&1 || true
	"$INITD_OPENWRT_DIR/meridian-antidpi" disable >/dev/null 2>&1 || true
	nft delete table inet meridian_antidpi 2>/dev/null || true
	for _o_p in $OWRT_UNDO; do
		case " $_a_undo0 " in *" $_o_p "*) continue ;; esac
		mv -f "${_o_p#*|}" "${_o_p%%|*}" 2>/dev/null || true
	done
	OWRT_UNDO="$_a_undo0"
	for _a_f in "$INSTALL_DIR/meridian-antidpi" "$INSTALL_DIR/meridian-antidpi-ctl" "$INITD_OPENWRT_DIR/meridian-antidpi" "$ANTIDPI_DIR/antidpi.nft"; do
		case " $CREATED_LIST " in *" $_a_f "*) rm -f "$_a_f" ;; esac
	done
	if [ "$_a_nfq_en" = 1 ]; then "$_a_nfq" enable >/dev/null 2>&1 || true; fi
	if [ "$_a_nfq_run" = 1 ]; then "$_a_nfq" start >/dev/null 2>&1 || true; fi
	return 0
}

# ---------- Список «Свои маршруты» по умолчанию ----------
# Владелец 30.09.2026: «залей домены и адреса с hero по умолчанию в список». Авария
# Xiaomi AX3000T: свежий роутер в чёрном режиме с ПУСТЫМ списком — туннель жив, а
# через него не идёт ничего, и это выглядит как «VPN не работает».
# ЗАЛИВАЕМ ОДИН РАЗ и ТОЛЬКО В ПУСТУЮ группу: метка .spisok-po-umolchaniyu рядом с
# моделью доменов. Есть домены — только ставим метку и ничего не трогаем; удалённое
# человеком обновление назад не вернёт. Список — тот же, что шлёт бот (держать в синхроне).
SPISOK_PO_UMOLCHANIYU="claude.ai binance.com console.anthropic.com aistudio.google.com suno-data-uploads.s3.amazonaws.com googleusercontent.com auth0.openai.com payoneer.com telegram.me sonarworks.com featuregates.org auth.openai.com makersuite.google.com deepmind.google livekit.cloud tutamail.com anthropic.com patreon.com platform.claude.com gemini.google.com openai.com oaistatic.com cdn.oaistatic.com web.whatsapp.com canva.com generativelanguage.googleapis.com docs.anthropic.com support.claude.com tuta.com bard.google.com chatgpt.com statsigapi.net claudeusercontent.com claude.com deepmind.com t.me oaiusercontent.com"
# ВАЖНО: в установщике set -e, а `grep -c` на ПУСТОЙ группе печатает 0 и возвращает код 1 — без `|| true`
# скрипт обрывался на чистом роутере (01.10.2026, второй Xiaomi): список не заливался, итог «Готово»
# не печатался, m.sh выходил с кодом 1. Проверять надо именно пустую группу.
# belyj_po_umolchaniyu — белый режим (через туннель всё, кроме RU) сразу после установки. 06.10.2026.
# ТОЛЬКО на роутере, где маршрутизацию ещё никто не выбирал: Keenetic — движок выключен (mode не black/white),
# OpenWrt — файла режима до установки не было. Кто сам выбрал чёрный — не трогаем. Один раз: метка
# .belyj-po-umolchaniyu, повторная установка решение человека не перебивает.
# БЕЗ ОКНА ОТКАТА (07.10.2026, владелец). Оставляем только когда режим назван движком и туннель отвечает;
# иначе — снимаем сами и говорим, как включить в панели.
belyj_tunnel_zhiv() {
	_bt_i=0
	while [ "$_bt_i" -lt 12 ]; do
		ping -c 1 -W 3 10.77.77.1 >/dev/null 2>&1 && return 0
		sleep 2; _bt_i=$((_bt_i + 1))
	done
	return 1
}
belyj_po_umolchaniyu() {
	[ "${QWDTT_BELYJ:-1}" = 1 ] || return 0
	_bp_metka="$CONF_DIR/.belyj-po-umolchaniyu"
	[ -f "$_bp_metka" ] && return 0
	_bp_sovet="включить можно в панели: «Свои маршруты» → Белый"
	if [ "${PLATFORM:-}" = "openwrt" ]; then
		_bp_m="$INSTALL_DIR/meridian-mode"
		[ -x "$_bp_m" ] || return 0
		if [ "${OWRT_REZHIM_BYL:-0}" = 1 ]; then : > "$_bp_metka" 2>/dev/null; return 0; fi
		_bp_tek=$(run_limited 20 "$_bp_m" status --machine 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^mode=/){sub(/^mode=/,"",$i); print $i; exit}}')
		[ "$_bp_tek" = "white" ] && { : > "$_bp_metka" 2>/dev/null; return 0; }
		etap "Включаю белый режим: через туннель всё, кроме российских сайтов"
		if ! belyj_tunnel_zhiv; then
			say "ВНИМАНИЕ: белый режим не включён — туннель ещё не поднялся; $_bp_sovet"
			return 0
		fi
		if ! run_limited 60 "$_bp_m" white >> "$QWDTT_INSTALL_LOG" 2>&1; then
			say "ВНИМАНИЕ: белый режим не включился (подробности в журнале установки); $_bp_sovet"
			run_limited 30 "$_bp_m" black >> "$QWDTT_INSTALL_LOG" 2>&1
			return 0
		fi
		sleep 3
		_bp_tek=$(run_limited 20 "$_bp_m" status --machine 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^mode=/){sub(/^mode=/,"",$i); print $i; exit}}')
		if [ "$_bp_tek" = "white" ] && belyj_tunnel_zhiv; then
			: > "$_bp_metka" 2>/dev/null
			etap "Белый режим включён: зарубежное — через туннель, российское — напрямую"
		else
			run_limited 30 "$_bp_m" black >> "$QWDTT_INSTALL_LOG" 2>&1
			say "ВНИМАНИЕ: белый режим снят — после включения туннель не ответил; $_bp_sovet"
		fi
		return 0
	fi
	_bp_r="$INSTALL_DIR/meridian-route"
	[ -x "$_bp_r" ] || return 0
	_bp_tek=$(run_limited 30 "$_bp_r" status 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^mode=/){sub(/^mode=/,"",$i); print $i; exit}}')
	case "$_bp_tek" in
		white) : > "$_bp_metka" 2>/dev/null; return 0 ;;
		black) : > "$_bp_metka" 2>/dev/null; return 0 ;;
	esac
	etap "Включаю маршрутизацию и белый режим: через туннель всё, кроме российских сайтов"
	if ! belyj_tunnel_zhiv; then
		say "ВНИМАНИЕ: маршрутизация не включена — туннель ещё не поднялся; $_bp_sovet"
		return 0
	fi
	# Белый строится поверх подтверждённого чёрного (white_home_vorota).
	if ! run_limited 120 "$_bp_r" on --confirm 0 >> "$QWDTT_INSTALL_LOG" 2>&1 || ! belyj_tunnel_zhiv \
		|| ! run_limited 60 "$_bp_r" confirm >> "$QWDTT_INSTALL_LOG" 2>&1; then
		run_limited 60 "$_bp_r" off >> "$QWDTT_INSTALL_LOG" 2>&1
		say "ВНИМАНИЕ: маршрутизация не включилась (подробности в журнале установки); $_bp_sovet"
		return 0
	fi
	run_limited 60 "$_bp_r" ru-direct on >> "$QWDTT_INSTALL_LOG" 2>&1 || say "ВНИМАНИЕ: «RU напрямую» не включилось — подробности в журнале установки"
	if ! run_limited 180 "$_bp_r" white on --confirm 0 >> "$QWDTT_INSTALL_LOG" 2>&1; then
		say "ВНИМАНИЕ: белый режим не включился (подробности в журнале установки), маршрутизация работает по списку; $_bp_sovet"
		: > "$_bp_metka" 2>/dev/null
		return 0
	fi
	sleep 3
	_bp_tek=$(run_limited 30 "$_bp_r" status 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^mode=/){sub(/^mode=/,"",$i); print $i; exit}}')
	if [ "$_bp_tek" = "white" ] && belyj_tunnel_zhiv && run_limited 60 "$_bp_r" white confirm >> "$QWDTT_INSTALL_LOG" 2>&1; then
		: > "$_bp_metka" 2>/dev/null
		etap "Белый режим включён: зарубежное — через туннель, российское — напрямую"
	else
		run_limited 60 "$_bp_r" white off >> "$QWDTT_INSTALL_LOG" 2>&1
		: > "$_bp_metka" 2>/dev/null
		say "ВНИМАНИЕ: белый режим снят — после включения туннель не ответил; маршрутизация работает по списку; $_bp_sovet"
	fi
	return 0
}

zalit_spisok_po_umolchaniyu() {
	if [ "${PLATFORM:-}" = "openwrt" ]; then
		_z_bin="$INSTALL_DIR/meridian-dns"; _z_conf="$CONF_DIR/meridian-dns.yaml"
	else
		_z_bin="/opt/bin/meridian-dns"; _z_conf="/opt/etc/qwdtt/meridian-dns.yaml"
	fi
	[ -x "$_z_bin" ] && [ -f "$_z_conf" ] || return 0
	_z_metka="$(dirname "$_z_conf")/.spisok-po-umolchaniyu"
	[ -f "$_z_metka" ] && return 0
	_z_est=$("$_z_bin" -config "$_z_conf" domains show --group "Свои маршруты" < /dev/null 2>/dev/null | grep -c 'id=' || true)
	if [ "${_z_est:-0}" -gt 0 ]; then
		: > "$_z_metka" 2>/dev/null || true
		return 0
	fi
	_z_ok=0; _z_vsego=0
	for _z_d in $SPISOK_PO_UMOLCHANIYU; do
		_z_vsego=$((_z_vsego + 1))
		"$_z_bin" -config "$_z_conf" domains add "$_z_d" --group "Свои маршруты" --create < /dev/null > /dev/null 2>&1
		case $? in 0|3) _z_ok=$((_z_ok + 1)) ;; esac
	done
	say "список «Свои маршруты» по умолчанию: залито $_z_ok из $_z_vsego"
	[ "$_z_ok" -gt 0 ] && { : > "$_z_metka" 2>/dev/null || true; }
	return 0
}

# owrt_luci_stranica — пункт «Меридиан» в LuCI (Службы → Меридиан), 01.10.2026.
# Владелец: «в службах openwrt панели нашего меридиан все еще нет, работа не доделана».
# Раньше страница ставилась только пакетом luci-app-meridian из opkg-фида, а opkg на
# 24.10 проверяет подпись, и у фида её нет — страница не появлялась НИКОГДА. Теперь три
# маленьких файла (меню, права, страница с рамкой на панель :8090, ~2 КБ) лежат прямо
# в установщике: ни фида, ни подписи, ни сети не нужно. Идемпотентно: что уже стоит
# теми же байтами — не трогаем. Каждый файл — через .new + mv; сбой на любом шаге
# убирает поставленное этим вызовом. LuCI не стоит — молча без страницы (панель :8090
# работает сама).
owrt_luci_stranica() {
	[ "${PLATFORM:-}" = "openwrt" ] || return 0
	_l_menu="${QWDTT_LUCI_MENU_DIR:-/usr/share/luci/menu.d}"
	_l_acl="${QWDTT_LUCI_ACL_DIR:-/usr/share/rpcd/acl.d}"
	_l_view="${QWDTT_LUCI_VIEW_DIR:-/www/luci-static/resources/view/meridian}"
	_l_tmp="${QWDTT_LUCI_TMP:-/tmp}"
	_l_rpcd="${QWDTT_RPCD_INIT:-/etc/init.d/rpcd}"
	if [ ! -d "$_l_menu" ] || [ ! -d "$_l_acl" ]; then
		say "LuCI на роутере не найден — страницы «Меридиан» в разделе «Службы» не будет (панель работает отдельно: http://адрес-роутера:8090)"
		return 0
	fi
	_l_est=$(df -Pk "$(dirname "$_l_view")" 2>/dev/null | awk 'NR==2{print $4}')
	case "$_l_est" in
		''|*[!0-9]*) say "ВНИМАНИЕ: место под страницу LuCI не прочиталось — страницу не ставлю"; return 0 ;;
	esac
	if [ "$_l_est" -lt 1024 ]; then
		say "ВНИМАНИЕ: под страницу LuCI свободно меньше 1 МБ (${_l_est} КБ) — не ставлю"
		return 0
	fi
	mkdir -p "$_l_view" 2>/dev/null || { say "ВНИМАНИЕ: не создать $_l_view — страницу LuCI не ставлю"; return 0; }
	_l_put=""; _l_new=0; _l_bad=0
	for _l_f in menu acl view; do
		case "$_l_f" in
			menu) _l_dst="$_l_menu/luci-app-meridian.json" ;;
			acl)  _l_dst="$_l_acl/luci-app-meridian.json" ;;
			view) _l_dst="$_l_view/panel.js" ;;
		esac
		owrt_luci_soderzhimoe "$_l_f" > "$_l_dst.new" 2>/dev/null || { rm -f "$_l_dst.new"; _l_bad=1; break; }
		if [ -f "$_l_dst" ] && cmp -s "$_l_dst" "$_l_dst.new"; then
			rm -f "$_l_dst.new"
			continue
		fi
		chmod 644 "$_l_dst.new" 2>/dev/null
		if mv -f "$_l_dst.new" "$_l_dst" 2>/dev/null; then
			_l_put="$_l_put $_l_dst"; _l_new=1
		else
			rm -f "$_l_dst.new"; _l_bad=1; break
		fi
	done
	if [ "$_l_bad" = 1 ]; then
		for _l_d in $_l_put; do rm -f "$_l_d"; done
		say "ВНИМАНИЕ: страница LuCI не поставилась (запись не удалась) — поставленное убрано, панель :8090 работает отдельно"
		return 0
	fi
	if [ "$_l_new" = 0 ]; then
		say "страница «Меридиан» в LuCI уже стоит"
		return 0
	fi
	rm -f "$_l_tmp"/luci-indexcache* 2>/dev/null
	rm -rf "$_l_tmp"/luci-modulecache 2>/dev/null
	[ -x "$_l_rpcd" ] && "$_l_rpcd" reload >/dev/null 2>&1
	# Автовыход (владелец 01.10.2026: «пункт должен явно отображаться у всех
	# установивших, тогда делай автовыход и автовход после установки»). Открытая
	# вкладка LuCI держит меню, загруженное ДО установки; сброс входов возвращает её
	# на экран входа, и меню читается заново. Автовход с роутера сделать нельзя: вход
	# делает браузер (у root без пароля это одно нажатие). Нулевую сессию не трогаем.
	_l_ubus="${QWDTT_UBUS:-ubus}"
	if command -v "$_l_ubus" >/dev/null 2>&1; then
		_l_n=0
		for _l_sid in $("$_l_ubus" call session list 2>/dev/null | grep -oE 'ubus_rpc_session": *"[0-9a-f]{32}' | grep -oE '[0-9a-f]{32}'); do
			case "$_l_sid" in 00000000000000000000000000000000) continue ;; esac
			"$_l_ubus" call session destroy '{"ubus_rpc_session":"'"$_l_sid"'"}' >/dev/null 2>&1 && _l_n=$((_l_n + 1))
		done
		[ "$_l_n" -gt 0 ] && say "открытые входы в LuCI сброшены ($_l_n): обнови страницу и войди снова — пункт Службы → Меридиан появится в меню"
	fi
	say "страница «Меридиан» поставлена в LuCI: Службы → Меридиан"
	return 0
}

owrt_luci_soderzhimoe() {
	case "$1" in
		menu) cat <<'MERIDIAN_LUCI_EOF'
{
	"admin/services/meridian": {
		"title": "Меридиан",
		"order": 60,
		"action": {
			"type": "view",
			"path": "meridian/panel"
		},
		"depends": {
			"acl": [ "luci-app-meridian" ]
		}
	}
}
MERIDIAN_LUCI_EOF
		;;
		acl) cat <<'MERIDIAN_LUCI_EOF'
{
	"luci-app-meridian": {
		"description": "Доступ к пункту меню Меридиан",
		"read": {
			"file": {
				"/www/luci-static/resources/view/meridian/panel.js": [ "read" ]
			}
		},
		"write": {}
	}
}
MERIDIAN_LUCI_EOF
		;;
		view) cat <<'MERIDIAN_LUCI_EOF'
'use strict';
'require view';

// ПОДГОНКА ВЫСОТЫ ПОД ОКНО: раньше высота рамки была фиксированной (min-height:
// 600px) и не менялась при изменении окна — если панель внутри была выше, LuCI
// добавляла СВОЮ прокрутку страницы поверх прокрутки самой панели, то есть две
// полосы сразу. Высота теперь считается от фактического положения рамки на
// экране (getBoundingClientRect().top) до низа окна, и пересчитывается при
// каждом изменении размера окна — так у страницы своей прокрутки не остаётся,
// и прокручивается только сама панель внутри рамки, если ей не хватило места.
return view.extend({
	render: function () {
		var frame = E('iframe', {
			src: 'http://' + window.location.hostname + ':8090/',
			style: 'width: 100%; display: block; border: none;'
		});

		function fit() {
			var top = frame.getBoundingClientRect().top;
			var h = window.innerHeight - top - 16;
			frame.style.height = Math.max(h, 300) + 'px';
		}

		window.addEventListener('resize', fit);
		// высота окна известна сразу, а положение рамки — только после того как
		// она встанет в разметку; requestAnimationFrame ждёт этого кадра.
		requestAnimationFrame(fit);

		return frame;
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
MERIDIAN_LUCI_EOF
		;;
		*) return 1 ;;
	esac
}

# owrt_dhcp_bystro — Кот 1, 01.10.2026 (замер на Xiaomi AX3000T): каждая правка
# доменов перезапускает dnsmasq, а его старт 3,2 с, из них 2,4 с — dhcp_check
# (udhcpc ищет в LAN другой DHCP-сервер). С dhcp.lan.force=1 проверки нет:
# restart 0,45 с, domains add/del ~1,2 с вместо 4–7 с, провал DNS ~0,5 с вместо ~3 с.
# СТАВИМ ТОЛЬКО если роутер сам раздаёт DHCP в LAN (ignore не 1, dhcpv4 не disabled):
# на роутере-точке доступа force включил бы второй DHCP-сервер в чужой сети.
# Уже задано человеком (0 или 1) — не трогаем. Откат: uci delete dhcp.lan.force; uci commit dhcp
owrt_dhcp_bystro() {
	[ "${PLATFORM:-}" = "openwrt" ] || return 0
	command -v uci >/dev/null 2>&1 || return 0
	[ "$(uci -q get dhcp.lan 2>/dev/null)" = "dhcp" ] || return 0
	if [ "$(uci -q get dhcp.lan.ignore 2>/dev/null)" = "1" ] || [ "$(uci -q get dhcp.lan.dhcpv4 2>/dev/null)" = "disabled" ]; then
		say "DHCP в LAN раздаёт не этот роутер — проверку чужого DHCP не отключаю"
		return 0
	fi
	[ -n "$(uci -q get dhcp.lan.force 2>/dev/null)" ] && return 0
	if uci set dhcp.lan.force=1 2>/dev/null && uci commit dhcp 2>/dev/null; then
		: > "$CONF_DIR/.dhcp-force-postavil" 2>/dev/null || true
		say "dnsmasq: проверка чужого DHCP снята (dhcp.lan.force=1) — правки доменов быстрее в 4–5 раз"
		say "  откат: uci delete dhcp.lan.force; uci commit dhcp; /etc/init.d/dnsmasq restart"
	else
		say "ВНИМАНИЕ: dhcp.lan.force не записался — правки доменов останутся медленными (4–7 с)"
	fi
	return 0
}

# owrt_perezapusk — порядок Кота 1 (27.09.2026). Экран и запрет утечки —
# обязательны: без них откатываем всё. Клиент — последним, с окном 180 с.
owrt_perezapusk() {
	[ "${PLATFORM:-}" = "openwrt" ] || return 0
	say "=== Перезапуск служб OpenWrt и проверка ==="
	"$INITD_OPENWRT_DIR/meridian-nft" restart >/dev/null 2>&1 || true
	"$INITD_OPENWRT_DIR/meridian-route-min" restart >/dev/null 2>&1 || true
	sleep 1
	if command -v nft >/dev/null 2>&1; then
		_r_pol=$(owrt_pol)
		[ "$_r_pol" = "2" ] || die "запрет утечки после перезапуска $_r_pol из 2 — возвращаю прежнее, чтобы трафик не ушёл мимо туннеля"
		say "  запрет утечки на месте (2 из 2)"
	else
		say "  ВНИМАНИЕ: nft нет — запрет утечки НЕ проверен"
	fi
	_r_mode=$("$INSTALL_DIR/meridian-mode" status --machine 2>/dev/null | sed -n 's/^mode=//p' | head -1)
	case "$_r_mode" in
		black|white) say "  режим: $_r_mode" ;;
		*) die "meridian-mode не назвал режим («${_r_mode:-пусто}») — возвращаю прежнее" ;;
	esac
	_r_ru=$("$INSTALL_DIR/meridian-mode" status --machine 2>/dev/null | sed -n 's/^ru_direct_active=//p' | head -1)
	if [ "$_r_ru" = "yes" ]; then
		say "  RU напрямую: действует"
	elif [ -n "$_r_ru" ]; then
		say "  ВНИМАНИЕ: RU напрямую не действует — $("$INSTALL_DIR/meridian-mode" status --machine 2>/dev/null | sed -n 's/^ru_direct_pochemu=//p' | head -1)"
	fi
	if [ -x "$INITD_OPENWRT_DIR/meridian-dns" ]; then "$INITD_OPENWRT_DIR/meridian-dns" restart >/dev/null 2>&1 || true; fi
	ustanovit_antidpi_openwrt
	if [ -n "${WEB_INITD:-}" ] && [ "$(owrt_sha "$INSTALL_DIR/qwdtt-web")" != "$OWRT_WEB_SHA0" ]; then
		"$WEB_INITD" restart >/dev/null 2>&1 || true
		say "  панель перезапущена — работает новая версия"
	fi
	# КЛИЕНТ — ПОСЛЕДНИМ. Трогает живой туннель: без ответа за 180 с
	# возвращаем прежний бинарь и даём ему подняться самому (Кот 1: по кругу
	# не перезапускать — «global lockout» у шлюза от частых попыток).
	_r_kl=$(owrt_sha "$BIN_PATH")
	if [ -n "$OWRT_KL_SHA0" ] && [ "$_r_kl" != "$OWRT_KL_SHA0" ]; then
		"$INITD_OPENWRT_DIR/qwdtt" restart >/dev/null 2>&1 || true
		if [ "$OWRT_TUN0" = 1 ]; then
			say "  клиент перезапущен — жду туннель до 180 с"
			_r_i=0
			while [ "$_r_i" -lt 36 ]; do
				owrt_tunnel && break
				_r_i=$((_r_i + 1)); sleep 5
			done
			if owrt_tunnel; then
				say "  туннель поднялся с новым клиентом"
			else
				_r_bak="$OWRT_PREV_DIR/$(echo "$BIN_PATH" | tr '/' '_').prev"
				say "  !!! за 180 с туннель не поднялся — возвращаю прежний клиент"
				if [ -f "$_r_bak" ] && mv -f "$_r_bak" "$BIN_PATH"; then
					"$INITD_OPENWRT_DIR/qwdtt" restart >/dev/null 2>&1 || true
					OWRT_UNDO=$(echo "$OWRT_UNDO" | tr ' ' '\n' | grep -v "^$BIN_PATH|" | tr '\n' ' ')
					say "  прежний клиент на месте; он поднимет туннель сам, по кругу не перезапускаю"
				else
					say "  !!! копии прежнего клиента нет — проверь: logread -e qwdtt"
				fi
			fi
		else
			say "  клиент перезапущен (туннеля до обновления не было — ждать нечего)"
		fi
	fi
	# КЛИЕНТ НЕ ЗАПУЩЕН — ЗАПУСКАЕМ (авария 30.09.2026, Xiaomi AX3000T): перезапуск
	# выше делается только при ЗАМЕНЕ бинаря; на свежей установке (прежнего нет) и
	# при повторе с тем же бинарём клиент оставался не запущенным.
	if ! "$INITD_OPENWRT_DIR/qwdtt" status 2>/dev/null | grep -q running; then
		if [ -c /dev/net/tun ]; then
			"$INITD_OPENWRT_DIR/qwdtt" start >/dev/null 2>&1 || true
			say "  клиент не был запущен — запускаю, жду туннель до 120 с"
			_r_i=0
			while [ "$_r_i" -lt 24 ]; do
				owrt_tunnel && break
				_r_i=$((_r_i + 1)); sleep 5
			done
			if owrt_tunnel; then
				say "  туннель поднялся"
			else
				say "  !!! за 120 с туннель не поднялся — клиент запущен; смотреть: logread -e qwdtt"
			fi
		else
			say "  !!! клиент не запущен: нет /dev/net/tun (kmod-tun не встал). Поставьте: opkg install kmod-tun, затем /etc/init.d/qwdtt start"
		fi
	fi
	owrt_snyat_kopii
	return 0
}

# ---------- Половинного состояния быть не должно ----------
#
# 18.08.2026 установка сорвалась на скачивании init-скрипта — уже ПОСЛЕ того, как
# был записан конфиг и сгенерирован DEVICE_ID. Роутер остался в состоянии «конфиг
# есть, программы нет», и это хуже честного отказа в начале: человек считает, что
# установка прошла, а после перезагрузки у него не поднимается ничего.
#
# Теперь так: всё, что установщик СОЗДАЁТ в этом запуске, он записывает в список,
# и при любом фатальном отказе снимает созданное и говорит человеку прямым
# текстом — что сделано, что нет и что делать дальше. Уже стоявшее до нас не
# трогается никогда: в список попадает только то, чего не было.
CREATED_LIST=""
note_created() { [ -e "$1" ] || CREATED_LIST="$CREATED_LIST $1"; }

rollback_partial() {
	[ -n "$CREATED_LIST" ] || return 0
	say "Снимаю то, что успел создать в этот запуск (чужое и прежнее не трогаю):"
	for _f in $CREATED_LIST; do
		[ -e "$_f" ] || continue
		rm -rf "$_f" 2>/dev/null || true
		say "  снято: $_f"
	done
	CREATED_LIST=""
}

# ПРЕРЫВАНИЕ (правило владельца 25.09.2026, после аварии HERO): Ctrl+C, TERM
# или обрыв сессии посреди установки обязаны чистить за собой ровно так же,
# как честный отказ через die() — тем же rollback_partial(), тем же списком.
# Второй сигнал во время самого отката не прерывает его на середине.
na_signal_install() {
	trap '' INT TERM HUP
	echo "" >&2
	echo "[meridian][ПРЕРВАНО] Ctrl+C, TERM или обрыв сессии посреди установки." >&2
	owrt_vernut_vse
	rollback_partial
	echo "[meridian] снято то, что успела создать эта попытка. Уже стоявшее не тронуто." >&2
	exit 130
}
trap na_signal_install INT TERM HUP

# INSTALL_RUNNING — идёт ли НАСТОЯЩАЯ установка. При подключении режимом
# SOURCE_ONLY (прогоны, qwdtt-ctl repair) она не идёт, и отчёт «установка не
# завершена, роутер возвращён как был» был бы неправдой о состоянии роутера.
INSTALL_RUNNING=0

die() {
	echo "[meridian][ОШИБКА] $1" >&2
	owrt_vernut_vse
	rollback_partial
	if [ "${INSTALL_RUNNING:-0}" != 1 ]; then
		exit 1
	fi
	echo "" >&2
	echo "[meridian] === УСТАНОВКА НЕ ЗАВЕРШЕНА ===" >&2
	echo "[meridian] причина: $1" >&2
	echo "[meridian] состояние роутера: вернул как было — половинной установки не осталось." >&2
	echo "[meridian] что делать:" >&2
	echo "[meridian]   1. проверь связь с раздачей прямо с этого роутера:" >&2
	echo "[meridian]      wget -q -O /tmp/проба $PUBLIC_BASE_URL/VERSION_CLIENT; echo код=\$?; ls -l /tmp/проба" >&2
	echo "[meridian]   2. если файл скачался, а установка нет — пришли нам весь вывод целиком;" >&2
	echo "[meridian]   3. если на роутере уже стоял Meridian, он остался в прежнем виде." >&2
	exit 1
}

# elf_endian — порядок байт по САМОМУ ФАЙЛУ, а не по названию системы.
#
# Пятый байт ELF-заголовка (EI_DATA): 1 — little-endian, 2 — big-endian. Это
# свойство формата, оно не зависит ни от прошивки, ни от менеджера пакетов, ни от
# того, что печатает uname. Берём любой заведомо системный бинарь.
# Список файлов-образцов и пути к описаниям системы переопределяются переменными
# ТОЛЬКО для проверок: определение архитектуры нельзя проверить установкой на живой
# роутер, а не проверять его — это как раз то, чем обернулся OpenWrt 25.
ELF_PROBES="${QWDTT_ELF_PROBES:-/bin/busybox /bin/sh /bin/ls /usr/bin/env}"

# df: ключ -P есть не в каждой сборке BusyBox, и без него команда не «печатает
# иначе», а не выполняется вовсе — проверка места молча превращается в ничто.
DF_OPT="-Pk"
df $DF_OPT / >/dev/null 2>&1 || DF_OPT="-k"
OPENWRT_RELEASE_FILE="${QWDTT_OPENWRT_RELEASE:-/etc/openwrt_release}"
OS_RELEASE_FILE="${QWDTT_OS_RELEASE:-/usr/lib/os-release}"

# Байт читается БЕЗ od: в BusyBox на Keenetic у od нет ключа -A (проверено на
# железе 18.08.2026 — «od: invalid option -- 'A'»), и вся команда падает целиком.
# Здесь это было бы особенно скверно: пустой ответ — это «unknown», то есть на
# каждом Кинетике установка отказывалась бы определять архитектуру.
# `dd` и `tr` есть в любой сборке. Значение переводится в печатный символ ещё
# внутри конвейера: подстановка команд теряет управляющие байты, и сравнивать
# «\001» в shell нечем.
#
# Если tr в какой-то сборке не поймёт восьмеричные escape-последовательности,
# результат будет не «1» и не «2» — то есть unknown и честный отказ с подсказкой,
# а не молчаливая догадка. Отказ здесь безопаснее любой эвристики.
elf_endian() {
	for probe in $ELF_PROBES; do
		[ -f "$probe" ] || continue
		b=$(dd if="$probe" bs=1 skip=5 count=1 2>/dev/null | tr '\001\002' '12')
		case "$b" in
			1) echo little; return 0 ;;
			2) echo big;    return 0 ;;
		esac
	done
	echo unknown
}

# detect_arch — ДЕФЕКТ 0: на OpenWrt 25 определение ломалось молча.
#
# В OpenWrt 25.12 менеджер пакетов сменился с opkg на apk, и `opkg
# print-architecture` перестал существовать. Единственным источником оставался
# `uname -m`, а он на MIPS печатает просто "mips" — БЕЗ порядка байт. Дальше
# ветка `*mips*` без подсказки от opkg выбирала big-endian, хотя подавляющее
# большинство домашних роутеров (MT7620, MT7621, MT7628 и родня) — mipsel.
# То есть на OpenWrt 25 роутер получал бинарь противоположной архитектуры и
# сообщение вида "Exec format error" уже ПОСЛЕ установки.
#
# Порядок источников теперь такой (первый сработавший выигрывает):
#   1. ARCH_OVERRIDE — ручное слово человека;
#   2. /etc/openwrt_release (DISTRIB_ARCH) и /usr/lib/os-release (OPENWRT_ARCH) —
#      есть на OpenWrt при ЛЮБОМ менеджере пакетов, там сразу "mipsel_24kc";
#   3. apk --print-arch (OpenWrt 25+), затем opkg print-architecture (24.10 и старше);
#   4. uname -m плюс порядок байт из ELF-заголовка системного бинаря.
# Если после всего этого для mips не удалось узнать порядок байт — ОТКАЗ с
# понятной командой, а не догадка. Догадка здесь стоит нерабочего роутера.
detect_arch() {
	PKG_ARCH=""
	SRC=""
	if [ -r "$OPENWRT_RELEASE_FILE" ]; then
		PKG_ARCH=$(sed -n "s/^DISTRIB_ARCH='\\(.*\\)'/\\1/p" "$OPENWRT_RELEASE_FILE" 2>/dev/null | head -1)
		[ -n "$PKG_ARCH" ] && SRC="$OPENWRT_RELEASE_FILE"
	fi
	if [ -z "$PKG_ARCH" ] && [ -r "$OS_RELEASE_FILE" ]; then
		PKG_ARCH=$(sed -n 's/^OPENWRT_ARCH="\(.*\)"/\1/p' "$OS_RELEASE_FILE" 2>/dev/null | head -1)
		[ -n "$PKG_ARCH" ] && SRC="$OS_RELEASE_FILE"
	fi
	if [ -z "$PKG_ARCH" ] && command -v apk >/dev/null 2>&1; then
		PKG_ARCH=$(apk --print-arch 2>/dev/null | head -1)
		[ -n "$PKG_ARCH" ] && SRC="apk"
	fi
	if [ -z "$PKG_ARCH" ] && command -v opkg >/dev/null 2>&1; then
		PKG_ARCH=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
		[ -n "$PKG_ARCH" ] && SRC="opkg"
	fi
	# QWDTT_UNAME_M — тот же тестовый крючок, что и пути выше: сценарий «mips без
	# менеджера пакетов» на этой машине иначе не воспроизвести, а именно он и
	# ломался на OpenWrt 25.
	MACHINE="${QWDTT_UNAME_M:-$(uname -m 2>/dev/null || echo unknown)}"
	ENDIAN=$(elf_endian)
	[ -n "$SRC" ] || SRC="uname+ELF"

	case "$PKG_ARCH $MACHINE" in
		*aarch64*|*arm64*)            ARCH="arm64" ;;
		*armv7*|*armhf*|*arm_cortex*) ARCH="armv7" ;;
		# 01.10.2026: x86 и mips64 — раньше не распознавались вовсе. Порядок важен:
		# x86_64 раньше x86, mips64 раньше общего *mips* (иначе 64-битный MIPS
		# получил бы 32-битный бинарь по порядку байт).
		*x86_64*|*amd64*)             ARCH="x86_64" ;;
		*i386*|*i486*|*i586*|*i686*|*x86*) ARCH="x86" ;;
		*mips64el*|*mips64le*)        ARCH="mips64" ;;
		*mips64*)
			# Сборка у нас только little-endian (mips64le). Большой порядок байт
			# (Octeon и подобные) не поддержан — отказ, а не бинарь не того порядка.
			case "$ENDIAN" in
				little) ARCH="mips64" ;;
				big)    die "MIPS64 с большим порядком байт (big-endian, например Octeon) не поддержан: готовая сборка только для mips64 little-endian. Железо: $PKG_ARCH $MACHINE" ;;
				*)      ARCH="" ;;
			esac ;;
		*mipsel*|*mipsle*)            ARCH="mipsle" ;;
		*mips*)
			# Порядок байт решает ФАЙЛ, а не отсутствие opkg.
			case "$ENDIAN" in
				little) ARCH="mipsle" ;;
				big)    ARCH="mips" ;;
				*)      ARCH="" ;;
			esac ;;
		*arm*)                        ARCH="armv7" ;;
		*)                            ARCH="" ;;
	esac
	[ -n "${ARCH_OVERRIDE:-}" ] && { ARCH="$ARCH_OVERRIDE"; SRC="ARCH_OVERRIDE"; }
	[ -n "$ARCH" ] || die "Не определить архитектуру: uname=$MACHINE, пакеты=«$PKG_ARCH», порядок байт=$ENDIAN. Запусти с явным указанием: ARCH_OVERRIDE=mipsle sh install.sh"
	say "Архитектура: $ARCH (источник: $SRC, uname=$MACHINE, порядок байт=$ENDIAN)"
}

# binary_runs — установленный файл ДЕЙСТВИТЕЛЬНО исполняется на этом железе?
#
# Проверка нужна ровно от того, что случилось выше: при неверно угаданной
# архитектуре файл скачивается, ложится, получает +x — и падает с "Exec format
# error" только когда его запустит init-скрипт, то есть после перезагрузки и без
# всяких объяснений человеку. Здесь мы узнаём это сразу.
binary_runs() {
	B="$1"
	# `set -e` включён, поэтому код возврата снимаем явно: неудача подстановки
	# иначе оборвала бы установку прямо здесь.
	OUT=$("$B" -такого-флага-нет 2>&1) && RC=0 || RC=$?
	case "$OUT" in
		*"Exec format error"*|*"not executable"*|*"cannot execute"*) return 1 ;;
	esac
	if [ "$RC" = 126 ] || [ "$RC" = 127 ]; then
		return 1
	fi
	return 0
}

# fetch_to_target — принести файл НА РАЗДЕЛ ЦЕЛИ и подменить атомарно.
#
# Правило 19 в CLAUDE.md, оплаченное аварией 17.08.2026: скачивать в /tmp нельзя
# (на Keenetic это оперативная память — запись падает по ENOSPC), а `mv` между
# разделами — это копирование, то есть подмена перестаёт быть атомарной.
# Прежний install.sh делал ровно это: качал в /tmp и переносил в /opt/bin, а
# панель — вообще ПРЯМО ПОВЕРХ боевого файла, так что оборванное скачивание
# оставляло роутер без панели.
#
# Аргументы: имя-в-раздаче путь-назначения минимальный-размер [elf|script]
fetch_to_target() {
	SRCNAME="$1"; DEST="$2"; MINSIZE="$3"; KIND="${4:-elf}"
	# FETCH_VERIFIED — БЫЛА ли сумма сверена с манифестом раздачи. Нужна тем, кто
	# после установки записывает эталон: эталон, записанный от файла, который
	# просто лёг, — это не эталон, а отпечаток, и сверка с ним не может покраснеть.
	FETCH_VERIFIED=0
	DDIR=$(dirname "$DEST")
	TMPF="$DDIR/.$(basename "$DEST").incoming"
	mkdir -p "$DDIR" 2>/dev/null || true
	rm -f "$TMPF" 2>/dev/null || true

	AVAILKB=$(df $DF_OPT "$DDIR" 2>/dev/null | awk 'NR==2{print $4}')
	# СКОЛЬКО НУЖНО — по НАСТОЯЩЕМУ размеру файла, а не по минимально допустимому.
	#
	# До 01.09.2026 здесь стояло MINSIZE — порог «меньше этого файл битый». Для
	# ядра это 1000000 байт при настоящих 3,9 МБ: проверка пропускала роутер с
	# двумя мегабайтами свободного, и он падал на середине записи. Порог годности
	# и требуемое место — разные величины, и подставлять одну вместо другой
	# значит иметь проверку, которая не может сработать там, где нужна.
	#
	# Настоящий размер спрашиваем у раздачи заголовком Content-Length. Не вышло
	# (сборка загрузчика без HEAD, источник не ответил) — откатываемся к MINSIZE и
	# ГОВОРИМ об этом: молча занизить требование хуже, чем занизить вслух.
	# Запас 1 МБ, не 512 КБ (правило владельца 25.09.2026, после аварии HERO).
	REMKB=$(remote_size_kb "$1")
	if [ -n "$REMKB" ] && [ "$REMKB" -gt 0 ] 2>/dev/null; then
		NEEDKB=$(( REMKB + 1024 ))
	else
		NEEDKB=$(( MINSIZE / 1024 + 1024 ))
		say "  размер $1 у раздачи не спросить — место проверяю по нижнему порогу ($NEEDKB КБ)"
	fi
	[ -n "$AVAILKB" ] || say "ВНИМАНИЕ: df на этом роутере не отвечает — свободное место НЕ проверено"
	if [ -n "$AVAILKB" ] && [ "$AVAILKB" -lt "$NEEDKB" ]; then
		say "Мало места в $DDIR: нужно ${NEEDKB} КБ, свободно ${AVAILKB} КБ — не хватает $((NEEDKB - AVAILKB)) КБ"
		say "Освободить: qwdtt-ctl cleanup"
		return 1
	fi

	GOT=0
	USEDBASE=""
	ERRF="$TMPF.err"
	for base in $BASE_URLS; do
		# stderr загрузчика НЕ выбрасываем: молчание при неудаче — это и есть то,
		# из-за чего 18.08.2026 полдня искали беду в сети и в раздаче, пока
		# падал сам wget. Причина печатается той же строкой, что и отказ.
		if dl "$TMPF" "$base/$SRCNAME" 2>"$ERRF"; then
			# Группировка: если файла нет, «can't open …» напечатала бы сама
			# оболочка, мимо 2>/dev/null (дефект апдейтера 18.08.2026).
			SZ=$( { wc -c < "$TMPF"; } 2>/dev/null | tr -d ' ')
			[ -n "$SZ" ] || SZ=0
			if [ "$SZ" -ge "$MINSIZE" ]; then GOT=1; USEDBASE="$base"; break; fi
			say "  с $base пришло $SZ Б (меньше $MINSIZE) — обрывок, беру следующий источник"
		else
			_rc=$?
			_why=$(head -1 "$ERRF" 2>/dev/null)
			[ -n "$_why" ] || _why="код $_rc и ни слова в stderr (так выглядит падение по сигналу)"
			say "  с $base не вышло: $_why"
		fi
		rm -f "$TMPF" 2>/dev/null || true
	done
	rm -f "$ERRF" 2>/dev/null || true
	if [ "$GOT" != 1 ]; then
		rm -f "$TMPF" 2>/dev/null || true
		say "Не скачать $SRCNAME целиком ни с одного источника"
		return 1
	fi

	if [ "$KIND" = elf ]; then
		if ! head -c 4 "$TMPF" | grep -q "ELF"; then
			rm -f "$TMPF"
			say "$SRCNAME не ELF — источник отдал не то (страницу ошибки?)"
			return 1
		fi
	elif [ "$KIND" = yaml ]; then
		# ФАЙЛ ПОЛИТИКИ meridian-dns (meridian-dns-napryamuyu.yaml): начинается с
		# "version:", не ELF и не HTML-страница ошибки.
		if ! head -1 "$TMPF" | grep -q '^version:' || grep -qi '<html' "$TMPF"; then
			rm -f "$TMPF"
			say "$SRCNAME не похож на yaml-политику (нет заголовка version: или внутри разметка) — источник отдал не то"
			return 1
		fi
	elif [ "$KIND" = list ]; then
		# СПИСОК (снимки RU-адресов и доменов): первая строка — комментарий «# »,
		# разметки нет. Страница ошибки nginx начинается с «<html» и сюда не пройдёт.
		if ! head -1 "$TMPF" | grep -q '^# ' || grep -qi '<html' "$TMPF"; then
			rm -f "$TMPF"
			say "$SRCNAME не похож на список (нет заголовка «# » или внутри разметка) — источник отдал не то"
			return 1
		fi
	else
		if ! head -1 "$TMPF" | grep -q '^#!'; then
			rm -f "$TMPF"
			say "$SRCNAME не похож на скрипт (нет шебанга) — источник отдал не то"
			return 1
		fi
	fi

	# Сумма — если и опубликована, и есть чем считать. Не отказ при отсутствии
	# sha256sum на прошивке, но заметная строка.
	if command -v sha256sum >/dev/null 2>&1; then
		SUMS="$DDIR/.SHA256SUMS.$$"
		if dl "$SUMS" "$USEDBASE/SHA256SUMS" 2>/dev/null; then
			WANT=$(awk -v n="$SRCNAME" '$2 == n {print $1}' "$SUMS" 2>/dev/null | head -1)
			rm -f "$SUMS"
			if [ -n "$WANT" ]; then
				HAVE=$(sha256sum "$TMPF" | awk '{print $1}')
				if [ "$WANT" != "$HAVE" ]; then
					rm -f "$TMPF"
					say "Сумма $SRCNAME не совпала с опубликованной — файл не ставлю"
					return 1
				fi
				say "  сумма совпала ($(echo "$HAVE" | cut -c1-16))"
				FETCH_VERIFIED=1
			fi
		else
			rm -f "$SUMS" 2>/dev/null || true
		fi
	fi

	mv -f "$TMPF" "$DEST" || { rm -f "$TMPF"; say "Не подменить $DEST"; return 1; }
	chmod +x "$DEST"
	return 0
}

# ---------- ЗАГРУЗЧИК: возможность ПРОВЕРЯЕТСЯ, а не предполагается ----------
#
# 18.08.2026 установка у нового клиента сорвалась дважды подряд, и оба раза из-за
# одной строки: DL="wget -q -T 5 -O". Ключ -T есть не во всякой сборке BusyBox
# (FEATURE_WGET_TIMEOUT), и там, где его нет, wget не ругается на незнакомый ключ,
# а ПАДАЕТ ПО СИГНАЛУ: «Segmentation fault», код 139. Воспроизведено на BusyBox
# 1.35: `wget -q -T 5 -O /dev/null <url>` — segfault, тот же вызов без -T работает.
# По логам nginx видно, что с того роутера в момент установки не пришло НИ ОДНОГО
# запроса, — то есть скачивание не начиналось вовсе, а человек читал «не скачать
# ни с одного источника» и искал беду в сети и в раздаче.
#
# Отсюда правило, которое здесь и исполняется: форма загрузчика не выбирается по
# вере, она ПРОБУЕТСЯ на маленьком файле, и в лог пишется, какая победила и чем
# не годились остальные. Молчаливого «не смог» больше нет.
DL=""
DL_ERR=""

# run_limited <секунд> <команда...> — ЖЁСТКИЙ предел по времени для загрузчика, у которого своего таймаута нет.
# 02.10.2026, живой случай у клиента (Keenetic arm64): «wget -T» падает, остаются формы без таймаута, и первый же
# источник, до которого клиент не достаёт (Париж), вешает BusyBox wget на минуты — и на пробе, и на каждом файле.
# Сторож проверяет раз в секунду и выходит сразу, как команда закончилась (долгих sleep-сирот не остаётся).
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

# dl — загрузка выбранной формой. Формы с собственным таймаутом (curl --max-time, wget -T) идут как есть; формы без
# него получают предел 600 с (DL_LIMIT) — раньше мёртвое соединение держало их без срока.
dl() {
	case "$DL" in
		"wget -q -O"|"timeout 600 wget -q -O") run_limited "${DL_LIMIT:-600}" $DL "$@" ;;
		*) $DL "$@" ;;
	esac
}

probe_form() { # probe_form "форма" "база" — скачать пробный файл
	_out="$RUN_DIR/.dlprobe.$$"
	rm -f "$_out" "$_out.err" 2>/dev/null || true
	# Проба — короткая (15 с), а не как сама загрузка: недоступный источник отсеивается за секунды.
	_pform="$1"; _plim=""
	case "$1" in
		"wget -q -O") _plim="run_limited 15" ;;
		"timeout 600 wget -q -O") _pform="timeout 15 wget -q -O" ;;
	esac
	if $_plim $_pform "$_out" "$2/VERSION_CLIENT" >/dev/null 2>"$_out.err"; then
		if [ -s "$_out" ]; then
			rm -f "$_out" "$_out.err" 2>/dev/null || true
			return 0
		fi
		DL_ERR="ответ пустой"
	else
		_rc=$?
		DL_ERR=$(head -1 "$_out.err" 2>/dev/null)
		# Пустой stderr при ненулевом коде — это и есть падение по сигналу:
		# оболочка печатает «Segmentation fault» от своего имени, а сама
		# программа не успевает сказать ничего. 124/137/143 — снят сторожем за таймаут.
		case "$_rc" in
			124|137|143) [ -n "$DL_ERR" ] || DL_ERR="источник не ответил за 15 с" ;;
		esac
		[ -n "$DL_ERR" ] || DL_ERR="код $_rc и ни слова в stderr (так выглядит падение по сигналу)"
	fi
	rm -f "$_out" "$_out.err" 2>/dev/null || true
	return 1
}

try_form() { # try_form "форма" — годится ли она хоть с одним источником
	# Проверяются ВСЕ источники, а не до первого живого: недоступные (у клиента из РФ это обычно Париж) отсеиваются
	# здесь один раз, и дальше установщик ходит только к живым — иначе каждый файл заново ждал бы мёртвый адрес.
	_tf_good=""; _tf_first=""; _tf_mertv=""
	for _b in $BASE_URLS; do
		if probe_form "$1" "$_b"; then
			_tf_good="${_tf_good:+$_tf_good }$_b"
			[ -n "$_tf_first" ] || _tf_first="$_b"
		else
			_tf_mertv="${_tf_mertv:+$_tf_mertv
}  источник $_b не отвечает ($DL_ERR) — дальше его не использую"
			_tf_err="$DL_ERR"
		fi
	done
	if [ -n "$_tf_good" ]; then
		DL="$1"
		BASE_URLS="$_tf_good"
		# Про недоступные источники говорим, только когда форма сама рабочая: иначе (форма падает) это не про источники.
		[ -z "$_tf_mertv" ] || say "$_tf_mertv"
		say "Загрузчик: $1 (проверен на $_tf_first)"
		return 0
	fi
	DL_ERR="${_tf_err:-$DL_ERR}"
	say "  форма «$1» не годится: $DL_ERR"
	return 1
}

# remote_size_kb — сколько весит файл в раздаче, в КБ. Пусто, если не узнать.
#
# Спрашиваем ЗАГОЛОВКОМ, не скачивая: смысл в том, чтобы отказать ДО записи на
# флеш, а не после. Ходим по тем же источникам и в том же порядке, что и сама
# загрузка, — первый ответивший и отвечает.
remote_size_kb() {
	_rname="$1"
	for _b in $BASE_URLS; do
		_len=""
		if command -v curl >/dev/null 2>&1; then
			_len=$(curl -fsSI --connect-timeout 5 --max-time 20 "$_b/$_rname" 2>/dev/null |
				awk 'tolower($1) == "content-length:" { print $2 }' | tr -d '\r' | tail -1)
		fi
		if [ -z "$_len" ] && command -v wget >/dev/null 2>&1; then
			# У BusyBox wget нет --spider с заголовками в каждой сборке, поэтому
			# берём -S и читаем заголовки из stderr, ничего не сохраняя.
			_len=$(wget -S -O /dev/null "$_b/$_rname" 2>&1 |
				awk 'tolower($1) == "content-length:" { print $2 }' | tr -d '\r' | tail -1)
		fi
		case "$_len" in
			""|*[!0-9]*) continue ;;
		esac
		echo $(( (_len + 1023) / 1024 ))
		return 0
	done
	return 1
}

pick_downloader() {
	mkdir -p "$RUN_DIR" 2>/dev/null || true
	if command -v curl >/dev/null 2>&1; then
		try_form "curl -fsSL --connect-timeout 5 --max-time 600 -o" && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		# Порядок: сначала с таймаутом (он лучше — мёртвый источник не съест
		# минуту), но только если проба покажет, что эта сборка его умеет.
		try_form "wget -q -T 15 -O" && return 0  # bb-ok: ключ не предполагается, а ПРОБУЕТСЯ; не сработал — берём форму ниже
		if command -v timeout >/dev/null 2>&1; then
			try_form "timeout 600 wget -q -O" && return 0
		fi
		try_form "wget -q -O" && return 0
	fi
	# САМОЛЕЧЕНИЕ ЧЕРЕЗ opkg — 15.09.2026, живой случай: у клиента на Entware
	# оказался ГОЛЫЙ BusyBox wget (из самой прошивки, без SSL) — тот же класс
	# отказа, что и здесь («ни одна форма не сработала»), только раньше:
	# BusyBox wget не умеет схему https вовсе и отвечает «not an http or ftp
	# url», приняв её за незнакомый протокол, а не за проблему сети.
	#
	# Пробуем ОДИН раз, только если opkg есть (то есть Entware уже стоит) —
	# на OpenWrt (apk/opkg с полноценными пакетами) до этой ветки в принципе
	# не должны были дойти: uclient-fetch там c TLS уже штатно.
	#
	# ОБА ПАКЕТА СРАЗУ, ОДНОЙ КОМАНДОЙ — wget-ssl И ca-certificates. Живой
	# случай 15.09.2026, ВТОРАЯ дверь того же класса дефекта (правило 51):
	# после установки одного wget-ssl проба честно провалилась заново, но уже
	# по ДРУГОЙ причине — «cannot verify dl.meridianvpn.org's certificate...
	# Unable to locally verify the issuer's authority» (на Entware без пакета
	# ca-certificates у wget-ssl попросту нет корневых сертификатов, которым
	# можно доверять). Ставить оба пакета вместе безопасно и тогда, когда один
	# из них уже стоит — opkg install на уже установленном пакете не ломает
	# ничего, просто не делает ничего лишнего.
	if command -v opkg >/dev/null 2>&1; then
		say "Загрузчик без HTTPS (или без доверенных сертификатов) — пробую поставить wget-ssl и ca-certificates через opkg (одна попытка)…"
		if opkg update >/dev/null 2>&1 && opkg install wget-ssl ca-certificates >/dev/null 2>&1; then
			DL=""; DL_ERR=""
			if command -v curl >/dev/null 2>&1; then
				try_form "curl -fsSL --connect-timeout 5 --max-time 600 -o" && { say "Починилось: wget-ssl/ca-certificates поставлены через opkg."; return 0; }
			fi
			try_form "wget -q -T 15 -O" && { say "Починилось: wget-ssl/ca-certificates поставлены через opkg."; return 0; }
			try_form "wget -q -O" && { say "Починилось: wget-ssl/ca-certificates поставлены через opkg."; return 0; }
		fi
		say "  opkg install wget-ssl ca-certificates не помог (или сети для него самого не было)"
	fi
	say "Ни одна форма загрузчика не сработала ни с одним источником."
	say "Проверь руками с этого же роутера:"
	say "  wget -q -O /tmp/пробa $PUBLIC_BASE_URL/VERSION_CLIENT; echo код=\$?; ls -l /tmp/пробa"
	die "Скачивать нечем: ни curl, ни wget здесь не работают (последняя причина: $DL_ERR). Если это Entware — поставьте вручную: opkg update && opkg install wget-ssl ca-certificates"
}

# install_pkg_openwrt <имя> — поставить системный пакет через то, что есть:
# apk (OpenWrt 25+) или opkg (24.10 и старше). Тот же порядок менеджеров, что
# в detect_arch, не завязан на его переменные — вызывается независимо и может
# понадобиться раньше architecture-детекции.
install_pkg_openwrt() {
	# ТРИ ПОПЫТКИ С ПАУЗОЙ (авария 30.09.2026, Xiaomi AX3000T): на чистом роутере
	# списка пакетов нет, а загрузка с downloads.openwrt.org рвалась (wget код 4) —
	# единственная попытка оставляла роутер без kmod-tun, и клиент не стартовал.
	_ipo_pkg="$1"; _ipo_i=0
	while [ "$_ipo_i" -lt 3 ]; do
		_ipo_i=$((_ipo_i + 1))
		if command -v apk >/dev/null 2>&1; then
			apk add "$_ipo_pkg" >/dev/null 2>&1 && return 0
			apk update >/dev/null 2>&1 || true
		elif command -v opkg >/dev/null 2>&1; then
			opkg install "$_ipo_pkg" >/dev/null 2>&1 && return 0
			opkg update >/dev/null 2>&1 || true
		else
			return 1
		fi
		[ "$_ipo_i" -lt 3 ] && sleep 5
	done
	# последняя попытка — после последнего update
	if command -v apk >/dev/null 2>&1; then apk add "$_ipo_pkg" >/dev/null 2>&1 && return 0; fi
	if command -v opkg >/dev/null 2>&1; then opkg install "$_ipo_pkg" >/dev/null 2>&1 && return 0; fi
	return 1
}

# setup_openwrt_firewall — зона meridian + переход lan→meridian в fw4.
#
# 15.09.2026, отмашка владельца: «kmod-tun, ip-full и правка фаервола — это
# всё должен делать установщик на автомате». Разбор КОТА 1: интерфейс
# meridian (TUN, клиент создаёт его напрямую, не через UCI network) не входит
# ни в одну зону fw4, а forward там DROP по умолчанию — транзит в туннель
# отбрасывался ДАЖЕ когда DNS, набор, метка и таблица маршрутизации работали
# верно. Без этой правки сайты отвечают ERR_CONNECTION_REFUSED независимо от
# всего остального. Конфигурация проверена им живьём на роутере владельца
# (счётчик accept_to_meridian растёт).
#
# ИДЕМПОТЕНТНО. install.sh зовётся и повторно — на уже настроенном роутере.
# Проверка ПЕРЕД записью, а не после: чужую правку зоны meridian (если
# человек сам подправил что-то внутри) переписывать нельзя, поэтому при уже
# существующей секции — молчим и выходим, как и у dnsmasq confdir.
setup_openwrt_firewall() {
	# ПРОВЕРКА UCI НУЖНА РАДИ ТОЧНОЙ ПРИЧИНЫ, А НЕ РАДИ ЗАЩИТЫ ОТ ПАДЕНИЯ —
	# и это стоит сказать честно, иначе следующий читатель решит, что тут два
	# предохранителя от одного и того же (правило 36).
	#
	# От падения защищает цепочка `&&` ниже: под `set -e` безусловный
	# `uci set` на прошивке без uci падал бы с кодом 127 и ронял ВЕСЬ
	# установщик посреди работы (поймано прогоном 15.09.2026 — 17 красных в
	# разделе полной установки OpenWrt при эталоне без них; проверено
	# мутацией: со снятой этой проверкой, но с цепочкой, установка
	# продолжается). Разница только в словах для человека: здесь он слышит
	# «нет uci», а не общее «не удалось записать», и сразу знает, что чинить.
	if ! command -v uci >/dev/null 2>&1; then
		say "ВНИМАНИЕ: нет uci — зону межсетевого экрана не настроить. Без неё транзит в туннель будет отброшен (forward у fw4 по умолчанию DROP)."
		return 0
	fi
	if uci -q get firewall.meridian >/dev/null 2>&1; then
		say "межсетевой экран: зона meridian уже настроена — не трогаю"
		return 0
	fi
	# ЦЕПОЧКА ЧЕРЕЗ &&, А НЕ СТРОКИ ПОДРЯД, И ТОЖЕ ИЗ-ЗА set -e: одиночный
	# `uci set`, упавший на середине (конфиг только для чтения, битая секция),
	# оборвал бы установку вместо того, чтобы сказать человеку. В цепочке
	# первая же неудача останавливает остальные и уходит в внятный отказ, а
	# сама установка продолжается — без зоны обход не заработает, но
	# половинной установки не останется.
	if uci set firewall.meridian=zone \
		&& uci set firewall.meridian.name='meridian' \
		&& uci set firewall.meridian.input='REJECT' \
		&& uci set firewall.meridian.output='ACCEPT' \
		&& uci set firewall.meridian.forward='REJECT' \
		&& uci set firewall.meridian.masq='1' \
		&& uci set firewall.meridian.mtu_fix='1' \
		&& uci add_list firewall.meridian.device='meridian' \
		&& uci set firewall.meridian_fwd=forwarding \
		&& uci set firewall.meridian_fwd.src='lan' \
		&& uci set firewall.meridian_fwd.dest='meridian' \
		&& uci commit firewall
	then
		# Перезапуск экрана — отдельно от записи настройки: он может не
		# сработать (служба не поднята в этот момент), и это НЕ повод считать
		# настройку неудавшейся — она уже в конфиге и применится при
		# следующем старте firewall.
		/etc/init.d/firewall restart >/dev/null 2>&1 || \
			say "настройка записана, но перезапуск экрана не прошёл — применится при следующем старте firewall"
		say "межсетевой экран настроен: зона meridian + переход lan→meridian"
	else
		say "ВНИМАНИЕ: не удалось записать зону meridian в настройку экрана — транзит в туннель будет отброшен (forward у fw4 по умолчанию DROP). Проверьте: uci show firewall"
	fi
}

check_env() {
	# ПЛАТФОРМА ОБЯЗАНА БЫТЬ ОПОЗНАНА. Пустая означает «ни Entware, ни procd» —
	# раскладывать файлы наугад здесь нельзя, и отказ до первой записи дешевле
	# половинной установки, которую потом никто не найдёт.
	# ЗНАЧЕНИЙ РОВНО ДВА, И ПРОВЕРЯЕМ ИМЕННО ИХ, а не «непустоту».
	#
	# Стенд поймал это сразу: QWDTT_PLATFORM=" " (пробел) — непустая строка, и
	# проверка `-z` её пропускала. Дальше установщик шёл с платформой-пробелом,
	# все ветки `= "openwrt"` давали ложь, и он молча ставил как на Entware —
	# то есть раскладывал файлы в /opt на прошивке, где /opt не бывает.
	# Словарь из двух литералов вместо признака «что-то задано» (тот же приём,
	# которым кот 1 закрыл rezhim в своём статусе).
	case "${PLATFORM:-}" in
		entware|openwrt) : ;;
		*) die "Не опознать систему: нет ни Entware (/opt/etc/init.d), ни procd (/etc/init.d + /etc/rc.common). Если это OpenWrt — поставьте пакет procd; если Keenetic — сначала Entware." ;;
	esac
	say "Система: $PLATFORM (файлы в $INSTALL_DIR, настройки в $CONF_DIR)"
	if [ "$PLATFORM" = "openwrt" ]; then
		# nft — не «желательно», а условие работы: экран и наборы здесь только
		# на нём. Без него установка дойдёт до конца и не заработает вовсе.
		command -v nft >/dev/null 2>&1 || die "Нет nft — на этой прошивке наборы и пометку ставить нечем. Поставьте: opkg update ; opkg install nftables (или apk add nftables)"
		# dnsmasq держит :53 и получает от нас строки nftset=. Без него обход по
		# доменам не заработает, и это надо сказать ДО установки, а не после.
		command -v dnsmasq >/dev/null 2>&1 || say "ВНИМАНИЕ: dnsmasq не найден — обход по доменам работать не будет, пока его нет."

		# ТРИ НЕЗАВИСИМЫЕ ПРИЧИНЫ ОДНОГО СИМПТОМА «ОБХОД НЕ РАБОТАЕТ» —
		# 15.09.2026, отмашка владельца после разбора КОТА 1: «kmod-tun,
		# ip-full и правка фаервола — это всё должен делать установщик на
		# автомате». Без любой из трёх остальные две ничего не решают.
		if [ ! -c /dev/net/tun ]; then
			say "нет /dev/net/tun — ставлю kmod-tun"
			if install_pkg_openwrt kmod-tun && [ -c /dev/net/tun ]; then
				say "kmod-tun поставлен, /dev/net/tun появился"
			else
				say "ВНИМАНИЕ: kmod-tun не поставился (или /dev/net/tun всё ещё нет) — поставьте руками: apk add kmod-tun (или opkg install kmod-tun)"
			fi
		fi
		# ip-full — БЕЗ него /sbin/ip это BusyBox-апплет без `ip rule add
		# fwmark`. meridian-route-hold это обнаруживает сам и держит nft-пол
		# (безопасно, но молча — видно только в logread, не в панели). Ставим
		# заранее, чтобы до этой заглушки дело не доходило вовсе. `apk add
		# ip-full` сам прописывает alternative /sbin/ip -> /usr/libexec/ip-full,
		# meridian-route-hold подхватывает это при следующем старте без
		# переустановки.
		install_pkg_openwrt ip-full || say "ВНИМАНИЕ: ip-full не поставился — meridian-route-hold сам обнаружит нехватку правил по метке и переключится на безопасный nft-пол, но лучше поставить: apk add ip-full (или opkg install ip-full)"

		# ПРАВКА FIREWALL — САМАЯ ВАЖНАЯ ИЗ ТРЁХ. Интерфейс meridian не входит
		# ни в одну зону fw4, а forward там DROP по умолчанию: транзит в туннель
		# отбрасывался ДАЖЕ когда DNS, набор, метка и таблица маршрутизации —
		# всё работало верно (ERR_CONNECTION_REFUSED при полностью исправном
		# остальном). Разбор и рабочая конфигурация — КОТ 1, проверено им живьём.
		setup_openwrt_firewall
	fi
	[ -c /dev/net/tun ] || say "ВНИМАНИЕ: нет /dev/net/tun. OpenWRT: opkg install kmod-tun; Keenetic: включи компонент VPN."
	# Каталоги по карте размещения (см. РАЗМЕЩЕНИЕ-НА-РОУТЕРЕ.md): у каждого
	# назначения ровно одно место, чтобы уборка была одной командой, а не поиском
	# по памяти.
	# /opt/var/run — парковое место для маркеров клиента. На OpenWrt его нет и
	# создавать не надо: там рабочий каталог задаётся qwdtt-run (QWDTT_RUN=/var/run),
	# а лишний /opt на чистой прошивке — это мусор, который потом ищут глазами.
	if [ "$PLATFORM" = "openwrt" ]; then
		mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$BACKUP_DIR" "$RUN_DIR" 2>/dev/null || true
	else
		mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$(dirname "$LOG_FILE")" \
		         "$BACKUP_DIR" /opt/var/run "$RUN_DIR" 2>/dev/null || true
	fi
	say "Источники обновлений: $BASE_URLS"
	if ! _bad=$(base_urls_sane); then
		die "Список источников негоден: $_bad"
	fi
	pick_downloader
	# ПОСЛЕ pick_downloader, НЕ РАНЬШЕ: фиду нужен $DL (форма загрузчика), а
	# она становится известна только здесь.
	#
	# `true` ПОСЛЕДНЕЙ СТРОКОЙ ОБЯЗАТЕЛЕН — и это снова про set -e (третий раз
	# за 15.09.2026, см. соседние уроки про say_panel_started и
	# setup_openwrt_firewall). Эта строка была ПОСЛЕДНЕЙ в check_env: на
	# Entware условие ложно, весь оператор `[ ... ] && ...` возвращает 1 БЕЗ
	# вызова функции — а это и есть код возврата check_env как последней
	# выполненной команды, и под set -e установщик падал сразу после
	# check_env НА ЛЮБОЙ ПЛАТФОРМЕ, кроме OpenWrt. Поймано прогоном: 38
	# красных из 130 вместо эталонных 2 из 137, причём ломались сценарии, не
	# имеющие отношения к apk (Entware-установка, повторный запуск, qwdtt-ctl
	# repair) — именно потому, что падало ДО них, в самом конце check_env.
	[ "$PLATFORM" = "openwrt" ] && setup_openwrt_apk_feed
	[ "$PLATFORM" = "openwrt" ] && setup_openwrt_opkg_feed
	true
}

# setup_openwrt_apk_feed -- добавить свой фид apk (feed.meridianvpn.org), чтобы
# meridian-web (и что появится следом) можно было ставить/обновлять штатной
# командой apk, а не только через install.sh заново.
#
# 15.09.2026, владелец: "можно ли запушить наш установщик или отдельные модули
# в стандартные репозитории openwrt" -- свой фид вместо официального дерева
# (там чужой ревью и чужой buildroot, а по содержанию клиента для обхода
# блокировок могут завернуть ещё на этапе рассмотрения).
#
# ТОЛЬКО ДЛЯ apk. Пакеты собраны в формате apk-tools v3 (бинарный индекс adb) --
# то, чем сама OpenWrt 24.10+ пользуется. Под opkg (ipk, старый текстовый
# Packages) фида пока нет -- отдельная задача, не молчаливое расширение этой.
# APK_ETC -- ПЕРЕОПРЕДЕЛЯЕМЫЙ ПУТЬ, тем же приёмом, что INSTALL_DIR/CONF_DIR
# выше (QWDTT_*_DIR). Без этого проверка на своей машине писала бы прямо в
# РЕАЛЬНЫЙ /etc/apk хоста, на котором гоняется прогон, а не в песочницу теста
# (найдено 15.09.2026: ручная проверка проводки оставила /etc/apk/keys и
# /etc/apk/repositories.d на сервере сборки -- убраны, но урок в том, что
# именно ЭТОТ путь во всей функции был жёстко зашит, пока остальной install.sh
# уже давно так не делает нигде).
APK_ETC="${QWDTT_APK_ETC:-/etc/apk}"

setup_openwrt_apk_feed() {
	command -v apk >/dev/null 2>&1 || return 0
	[ -n "$ARCH" ] || return 0
	FEED_URL="https://feed.meridianvpn.org/$ARCH/packages.adb"
	mkdir -p "$APK_ETC/keys" "$APK_ETC/repositories.d"
	if [ "$(cat "$APK_ETC/repositories.d/meridian.list" 2>/dev/null)" != "$FEED_URL" ]; then
		echo "$FEED_URL" > "$APK_ETC/repositories.d/meridian.list"
	fi
	# КЛЮЧ -- ПОЛНОСТЬЮ НАШ ФАЙЛ, ПЕРЕЗАПИСЫВАЕМ БЕЗ ПРОВЕРКИ СУЩЕСТВОВАНИЯ.
	# В отличие от firewall.meridian (там мог быть чужой ручной довесок), этот
	# файл никто, кроме нас, не пишет -- идемпотентность здесь не "не трогать
	# чужое", а "привести к текущему верному значению".
	if dl "$APK_ETC/keys/meridian-apk.pub.new" "https://feed.meridianvpn.org/keys/meridian-apk.pub" \
		&& [ -s "$APK_ETC/keys/meridian-apk.pub.new" ]; then
		mv -f "$APK_ETC/keys/meridian-apk.pub.new" "$APK_ETC/keys/meridian-apk.pub"
		say "фид «Меридиан» добавлен: apk update && apk add meridian-web"
		install_openwrt_luci_app
	else
		rm -f "$APK_ETC/keys/meridian-apk.pub.new"
		say "ВНИМАНИЕ: не удалось скачать ключ доверия фида -- apk update будет отказывать на непроверенной подписи, пока файл $APK_ETC/keys/meridian-apk.pub не появится"
	fi
}

# install_openwrt_luci_app -- пункт меню «Меридиан» в самой LuCI (Службы ->
# Меридиан, рамка с панелью внутри), пакет luci-app-meridian из нашего же
# фида. Владелец 15.09.2026: "мне нужна в панели openwrt чтобы было видно
# Меридиан" -- сделано и обкатано живьём на его роутере, здесь то же самое
# автоматом при установке, без ручного apk add.
#
# ТОЛЬКО ЕСЛИ LUCI УЖЕ СТОИТ. Пакет тянет luci-base как зависимость -- apk
# поставил бы её и на headless-роутере без веб-морды вовсе, а владельцу там
# нужен только сам клиент, не веб-интерфейс OpenWrt. Проверяем по каталогу
# меню, а не по имени пакета в списке: он один и тот же для luci-base и
# luci-light, а каталог -- то, во что реально пишет apk и что реально читает
# LuCI при сборке меню.
#
# ЛОВУШКА С КЕШЕМ МЕНЮ, обе найдены живьём в тот же день: (1) LuCI держит
# посчитанное дерево меню в /tmp/luci-indexcache.*.json и не видит новый
# пункт, пока файл не пересобран; (2) список прав (ACL) для уже открытой
# сессии браузера посчитан ПРИ ВХОДЕ и не подхватывает новые acl.d/*.json на
# лету. Поэтому мало положить файлы -- нужно снести кеш меню и перезапустить
# rpcd, а владельцу отдельно сказать про перезаход в LuCI (это уже не может
# сделать скрипт -- решает сессия в чужом браузере).
install_openwrt_luci_app() {
	[ -d /usr/share/luci/menu.d ] || return 0
	command -v apk >/dev/null 2>&1 || return 0
	if apk update >/dev/null 2>&1 && apk add luci-app-meridian >/dev/null 2>&1; then
		rm -f /tmp/luci-indexcache* /tmp/luci-modulecache-* 2>/dev/null
		command -v /etc/init.d/rpcd >/dev/null 2>&1 && /etc/init.d/rpcd restart >/dev/null 2>&1
		say "пункт «Меридиан» добавлен в LuCI (Службы -> Меридиан) -- выйдите из веб-панели OpenWrt и зайдите заново, чтобы он появился"
	else
		say "ВНИМАНИЕ: не удалось поставить luci-app-meridian -- панель работает и без пункта меню, доступна на порту 8090 напрямую"
	fi
}

# setup_openwrt_opkg_feed -- ВТОРОЙ фид, для СТАРОГО OpenWrt: там, где apk ещё
# нет, стоит opkg (текстовый индекс Packages, формат .ipk). Владелец
# 15.09.2026, дословно: "под более старые openwrt например 24 нужно ещё opkg
# собрать под openwrt роутеры обязательно".
#
# ТОЛЬКО КОГДА apk ОТСУТСТВУЕТ. Роутер владельца (SNAPSHOT r36216) уже на apk
# -- ему хватает setup_openwrt_apk_feed выше, этот фид ему не нужен и не
# писался бы поверх. На более старых прошивках (24.10 и раньше) apk ещё нет
# вовсе, opkg -- единственный менеджер, и именно туда идёт эта функция.
#
# ФОРМАТ .ipk И ПОВЕДЕНИЕ opkg ИЗМЕРЕНЫ, А НЕ ВЗЯТЫ ПО ПАМЯТИ (15.09.2026):
# настоящий пакет с downloads.openwrt.org распакован и сверен байт в байт
# (это НЕ ar-архив, как классический ipkg, — простой tar.gz с debian-binary/
# control.tar.gz/data.tar.gz внутри), а установка целиком (update, install,
# list-installed, remove) прогнана живым opkg 0.1.8, собранным из исходников,
# через настоящий HTTP-адрес фида -- не файловый путь, не гадание.
#
# НЕ ПРОВЕРЕНО (честно, а не "наверное сработает"): включена ли проверка
# подписи (check_signature) в /etc/opkg.conf на реальной прошивке 24.x --
# узнать это из исходников не вышло (GitHub-раздачи с исходным деревом
# OpenWrt из этой среды недоступны без отдельного токена). Если ОНА включена
# глобально, у нашего фида нет подписи, и `opkg update` для него откажет
# читаемой ошибкой про подпись -- это ЛЕЧИТСЯ (нужен свой usign-ключ и
# Packages.sig, отдельная задача), но не выглядит как "фид сломан": сама
# строка добавится и заработает у всех, кому подпись не проверяется, а
# отказавшим будет понятно, что чинить.
setup_openwrt_opkg_feed() {
	command -v opkg >/dev/null 2>&1 || return 0
	command -v apk >/dev/null 2>&1 && return 0
	[ -n "$ARCH" ] || return 0
	OPKG_ETC="${QWDTT_OPKG_ETC:-/etc/opkg}"
	FEED_URL="https://feed.meridianvpn.org/opkg/$ARCH"
	mkdir -p "$OPKG_ETC"
	LINE="src/gz meridian $FEED_URL"
	# customfeeds.conf может уже содержать чужие строки (правило "не трогать
	# чужое") -- заменяем ТОЛЬКО строку с нашим именем "meridian", остальное
	# не пишем и не переставляем.
	if [ -f "$OPKG_ETC/customfeeds.conf" ] && grep -q '^src/gz meridian ' "$OPKG_ETC/customfeeds.conf" 2>/dev/null; then
		if ! grep -qxF "$LINE" "$OPKG_ETC/customfeeds.conf" 2>/dev/null; then
			grep -v '^src/gz meridian ' "$OPKG_ETC/customfeeds.conf" > "$OPKG_ETC/customfeeds.conf.new" 2>/dev/null
			echo "$LINE" >> "$OPKG_ETC/customfeeds.conf.new"
			mv -f "$OPKG_ETC/customfeeds.conf.new" "$OPKG_ETC/customfeeds.conf"
		fi
	else
		echo "$LINE" >> "$OPKG_ETC/customfeeds.conf"
	fi
	say "фид «Меридиан» (opkg) добавлен: opkg update && opkg install meridian-web -- если update откажет ошибкой про подпись, это отдельная известная задача (подпись фида), не поломка установки"
}

# dist_name — БОЕВОЕ имя файла для ЭТОЙ платформы.
#
# ИМЯ ЛАТИНИЦЕЙ, И ЭТО НЕ ВКУСОВЩИНА: dash и ash (busybox) не принимают
# кириллицу в имени функции — `Syntax error: Bad function name`, весь скрипт
# не разбирается целиком. Та же грабля, что с кириллицей в именах переменных,
# на которой мы горели трижды; здесь она ломает не вывод, а разбор.
#
# Клиент для нативного OpenWrt — ОТДЕЛЬНЫЙ файл, а не тот же самый: замер
# 12.09.2026 показал разные суммы и размеры (cce4e1e8/4128476 против
# 11ed28c5/4139328). Скачать парковое имя на OpenWrt значит принести чужую
# сборку МОЛЧА И С ВЕРНОЙ СУММОЙ: она сойдётся с SHA256SUMS, ELF пройдёт, и
# роутер начнёт работать не тем ядром.
dist_name() { # dist_name <база> -> база или база-openwrt
	if [ "${PLATFORM:-}" = "openwrt" ]; then
		echo "$1-openwrt"
	else
		echo "$1"
	fi
}

download_bin() {
	FILE=$(dist_name "qwdtt-$ARCH")
	SCRIPT_DIR=$(dirname "$0")
	# ЛОКАЛЬНЫЙ ФАЙЛ БЕРЁТСЯ ТОЛЬКО ПО СУММЕ ИЗ РАЗДАЧИ.
	#
	# До 13.09.2026 эта ветка проверяла ELF по четырём байтам и ничего больше:
	# обрывок длиннее четырёх байт с шапкой ELF проходил, подменённый файл с той
	# же шапкой проходил тоже. Ветка скачивания рядом требует размер, ELF и сумму
	# (правило 19) — сторож стоял у одной двери из двух (правило 43).
	#
	# И срабатывала она ПО СОВПАДЕНИЮ ИМЕНИ, молча. `qwdtt-ctl repair` кладёт
	# install.sh в /tmp/qwdtt-run — каталог, где по карте размещения живут
	# тестовые кандидаты; оставшийся там qwdtt-<арх> от прошлого прогона
	# ставился вместо свежего. Ни ошибки, ни строки в журнале — это и есть
	# «поставил заново, а версия старая» (правило 33).
	#
	# СВЕРЯЕМСЯ С РАЗДАЧЕЙ, А НЕ С МАНИФЕСТОМ РЯДОМ. Первая редакция этой
	# починки брала SHA256SUMS из того же каталога — и прогон сразу нашёл дыру:
	# обрывок вместе с посчитанным по нему же манифестом самосогласован, сумма
	# сходится, файл уезжает в /opt/bin. Это сверка вещи с самой собой
	# (правило 36), и ровно про это уже написано ниже, в месте про эталон движка:
	# «SHA256SUMS раздачи. Никогда — от файла, который просто лежит».
	#
	# Ветку не убираю: установка из каталога с заранее принесёнными файлами — это
	# рабочий случай, и она экономит скачивание многомегабайтного ядра. Платим за
	# это скачиванием крошечного SHA256SUMS. Нет сети или нет строки в манифесте
	# раздачи — локальный файл НЕ берём и идём обычным путём, где сверка есть.
	LOKALNO=""
	if [ -f "$SCRIPT_DIR/$FILE" ]; then
		say "Рядом со скриптом лежит $FILE — проверяю по сумме из раздачи, можно ли его взять"
		LOKALNO=1
		if ! command -v sha256sum >/dev/null 2>&1; then
			say "  нечем посчитать сумму (нет sha256sum) — локальный файл НЕ БЕРУ, качаю из раздачи"
			LOKALNO=""
		else
			L_SUMS="$INSTALL_DIR/.SHA256SUMS.lok.$$"
			L_WANT=""
			for base in $BASE_URLS; do
				if dl "$L_SUMS" "$base/SHA256SUMS" 2>/dev/null; then
					L_WANT=$(awk -v n="$FILE" '$2 == n {print $1}' "$L_SUMS" 2>/dev/null | head -1)
					[ -n "$L_WANT" ] && { say "  манифест раздачи взят с $base"; break; }
				fi
				rm -f "$L_SUMS" 2>/dev/null || true
			done
			rm -f "$L_SUMS" 2>/dev/null || true
			if [ -z "$L_WANT" ]; then
				say "  сумму $FILE у раздачи не спросить (нет сети или нет строки в SHA256SUMS)"
				say "  локальный файл НЕ БЕРУ: сверять его с манифестом рядом — это сверка вещи с самой собой"
				LOKALNO=""
			else
				L_HAVE=$(sha256sum "$SCRIPT_DIR/$FILE" | awk '{print $1}')
				if [ "$L_WANT" != "$L_HAVE" ]; then
					say "  сумма локального $FILE НЕ совпала с раздачей — НЕ БЕРУ его, качаю"
					say "    лежит рядом: $(echo "$L_HAVE" | cut -c1-16)"
					say "    в раздаче:   $(echo "$L_WANT" | cut -c1-16)"
					LOKALNO=""
				else
					say "  сумма совпала с раздачей ($(echo "$L_HAVE" | cut -c1-16))"
					# Сумма подтверждена манифестом раздачи — значит эталон движка
					# и прочие отпечатки записывать можно (см. FETCH_VERIFIED).
					FETCH_VERIFIED=1
				fi
			fi
		fi
	fi
	if [ -n "$LOKALNO" ]; then
		say "Беру бинарь локально: $SCRIPT_DIR/$FILE"
		TMPF="$INSTALL_DIR/.qwdtt.incoming"
		cp "$SCRIPT_DIR/$FILE" "$TMPF" || die "Не скопировать локальный бинарь в $INSTALL_DIR (место?)"
		head -c 4 "$TMPF" | grep -q "ELF" || { rm -f "$TMPF"; die "Локальный файл не ELF"; }
		mv -f "$TMPF" "$BIN_PATH" || { rm -f "$TMPF"; die "Не подменить $BIN_PATH"; }
		chmod +x "$BIN_PATH"
	else
		say "Скачиваю $FILE (проверю размер, ELF и сумму)..."
		note_created "$BIN_PATH"
		fetch_to_target "$FILE" "$BIN_PATH" 1000000 || die "Не установить $FILE"
	fi
	# Архитектуру проверяем ЗАПУСКОМ, а не доверием к определению: неверная догадка
	# иначе всплыла бы только при старте службы, уже без человека рядом.
	if ! binary_runs "$BIN_PATH"; then
		die "Скачанный бинарь не запускается на этом железе — определение архитектуры ($ARCH) неверно. Поставь явно: ARCH_OVERRIDE=<mipsle|mips|armv7|arm64|x86|x86_64|mips64> sh install.sh"
	fi
	say "Бинарь установлен и запускается: $BIN_PATH"
	# ВЕРСИЯ ПИШЕТСЯ ПО ФАКТУ УСТАНОВЛЕННОГО ФАЙЛА, а не по факту скачивания.
	# Зовём ЗДЕСЬ — после проверки запуском, — и только для уже существующего
	# конфига; свежую установку напишет setup_config ниже.
	note_client_ver_after_install
}

# set_conf_val — заменить или добавить ключ в конфиге. Схема взята из qwdtt-ctl,
# где она уже пережила BusyBox: без `sed -i` (ключ есть не в каждой сборке, а
# неудача правки выглядит как «команда прошла»), через временный файл и mv.
set_conf_val() { # ключ значение
	[ -f "$CONF_FILE" ] || return 1
	if grep -q "^$1=" "$CONF_FILE" 2>/dev/null; then
		_scv_tmp="$CONF_FILE.tmp.$$"
		: > "$_scv_tmp" 2>/dev/null
		chmod 600 "$_scv_tmp" 2>/dev/null
		if sed "s|^$1=.*|$1=\"$2\"|" "$CONF_FILE" > "$_scv_tmp" 2>/dev/null && [ -s "$_scv_tmp" ]; then
			# `mv` заменяет ФАЙЛ, а не содержимое: права конфига становятся
			# правами временного. Без chmod конфиг с паролем туннеля уезжал в
			# 0644 — так это и случилось у владельца (05.09.2026). Ставим 0600
			# и на временный (до пароля в нём), и на конфиг после подмены.
			mv -f "$_scv_tmp" "$CONF_FILE" || { rm -f "$_scv_tmp"; return 1; }
			chmod 600 "$CONF_FILE" 2>/dev/null
		else
			rm -f "$_scv_tmp"; return 1
		fi
	else
		echo "$1=\"$2\"" >> "$CONF_FILE" || return 1
		chmod 600 "$CONF_FILE" 2>/dev/null
	fi
}

# note_client_ver_after_install — записать CLIENT_VER в УЖЕ СУЩЕСТВУЮЩИЙ конфиг.
#
# Зачем отдельно от setup_config. При повторном запуске установщика на роутере,
# где конфиг уже есть, setup_config выходит первой же строкой («конфиг уже
# есть»), а download_bin бинарь МЕНЯЕТ. Получалось: файл новый, запись старая —
# роутер сообщал версию, которой на нём давно нет.
#
# Нашёл КОТ 1 29.08.2026, замерив сумму ядра на живом роутере. Место он указал
# другое (строки 518–531 в setup_config), но симптом описал точно, и второй
# перекос — этот — нашёлся при проверке его отчёта.
#
# ЗАПИСЬ ПРОВЕРЯЕТСЯ ЧТЕНИЕМ, а не кодом возврата (правило 19: смотреть
# результат записи, а не то, что команда «прошла»). Не сумели узнать версию —
# НЕ ПИШЕМ НИЧЕГО: неверный номер хуже отсутствующего, потому что выглядит
# ответом.
note_client_ver_after_install() {
	[ -f "$CONF_FILE" ] || return 0
	_ncv=""
	for _ncvbase in $BASE_URLS; do
		_ncv=$(dl - "$_ncvbase/VERSION_CLIENT" 2>/dev/null | head -c 30 | tr -d '\n\r')
		[ -n "$_ncv" ] && break
	done
	if [ -z "$_ncv" ]; then
		say "ВНИМАНИЕ: версию клиента узнать не удалось — CLIENT_VER оставлен прежним (лучше старый номер, чем выдуманный)"
		return 0
	fi
	if ! set_conf_val CLIENT_VER "$_ncv"; then
		say "ВНИМАНИЕ: не удалось записать CLIENT_VER=$_ncv в $CONF_FILE"
		return 0
	fi
	# СВЕРКА ЗАПИСАННОГО. Мутацией не покрыта, и это записано честно: она
	# выполняется только когда set_conf_val вернул успех, а тогда значение
	# всегда на месте — входа, на котором она отличала бы исправное от
	# сломанного, придумать не удалось (30.08.2026). Оставлена как защита по
	# правилу 19: смотреть результат записи, а не код возврата. Если такой вход
	# найдётся — здесь появится проверка.
	_ncv_got=$(grep "^CLIENT_VER=" "$CONF_FILE" 2>/dev/null | head -1 | cut -d\" -f2)
	if [ "$_ncv_got" != "$_ncv" ]; then
		say "ВНИМАНИЕ: CLIENT_VER записан неверно (в файле «$_ncv_got», ожидалось «$_ncv»)"
		return 0
	fi
	say "CLIENT_VER обновлён по факту установленного ядра: $_ncv"
}

setup_config() {
	if [ -f "$CONF_FILE" ] && [ -z "${RECONFIG:-}" ]; then
		say "Конфиг уже есть (перезаписать: RECONFIG=1 sh install.sh)"; return
	fi
	# Источник каждого значения запоминаем ДО подстановки: после неё «пришло из
	# окружения» и «пришло из шапки» неразличимы, а именно это и надо сказать
	# человеку, когда он потом спросит «почему не тот пароль».
	if [ -n "${PEER:-}" ];      then _ist_peer=окружение
	elif [ -n "${VSHITO_PEER:-}" ]; then _ist_peer="вписан в install.sh"
	else _ist_peer="умолчание установщика"; fi
	if [ -n "${PASSWORD:-}" ];  then _ist_pass=окружение
	elif [ -n "${VSHITO_PASSWORD:-}" ]; then _ist_pass="вписан в install.sh"
	else _ist_pass="спрошен у человека"; fi
	if [ -n "${VK_HASHES:-}" ]; then _ist_vk=окружение
	elif [ -n "${VSHITO_VK_HASHES:-}" ]; then _ist_vk="вписаны в install.sh"
	else _ist_vk="спрошены у человека"; fi

	# Приоритет: окружение -> вписанное в шапку -> умолчание/вопрос.
	# Через `:-`, а не `-`: пустая строка в шапке означает «не задано», а не
	# «задано пустым». Разница видна на PEER: с `-` пустой VSHITO_PEER затёр бы
	# боевое умолчание, и клиент получил бы конфиг без адреса сервера —
	# установка «успешна», туннель не поднимается никогда.
	PEER="${PEER:-${VSHITO_PEER:-62.76.231.231:56000}}"
	PASSWORD="${PASSWORD:-${VSHITO_PASSWORD:-}}"
	VK_HASHES="${VK_HASHES:-${VSHITO_VK_HASHES:-}}"
	N="${N:-24}"; ANON_PATH="${ANON_PATH:-vkcalls}"
	DELAY_MIN="${DELAY_MIN:-1}"
	DEVICE_ID=""
	# Пытаемся переиспользовать уже известный DEVICE_ID, а не генерировать новый —
	# иначе сервер продолжит считать это подключение старым устройством и будет
	# отказывать в авторизации (FATAL_AUTH: пароль привязан к другому устройству)
	# до тех пор, пока пароль не отвяжут вручную. Источники по приоритету:
	# (1) отдельный маркер-файл DEVICE_ID_FILE — переживает даже полную
	#     перезапись qwdtt.conf (RECONFIG=1) или его случайную/внешнюю потерю;
	# (2) DEVICE_ID из старого qwdtt.conf, если сам файл конфига ещё цел.
	if [ -f "$DEVICE_ID_FILE" ]; then
		DEVICE_ID=$(cat "$DEVICE_ID_FILE" 2>/dev/null | tr -d '\n')
	fi
	if [ -z "$DEVICE_ID" ] && [ -f "$CONF_FILE" ]; then
		DEVICE_ID=$(grep '^DEVICE_ID=' "$CONF_FILE" 2>/dev/null | sed 's/^DEVICE_ID="\(.*\)"$/\1/')
	fi
	if [ -n "$DEVICE_ID" ]; then
		say "Найден существующий DEVICE_ID — переиспользую, привязка на сервере сохранится: $DEVICE_ID"
	else
		DEVICE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '\n')
		[ -z "$DEVICE_ID" ] && DEVICE_ID="dev$(date +%s)$$"
		say "Существующий DEVICE_ID не найден — сгенерирован новый: $DEVICE_ID"
	fi
	mkdir -p "$CONF_DIR" 2>/dev/null
	note_created "$DEVICE_ID_FILE"
	note_created "$CONF_FILE"
	echo "$DEVICE_ID" > "$DEVICE_ID_FILE" 2>/dev/null
	chmod 600 "$DEVICE_ID_FILE" 2>/dev/null
	# СПРАШИВАТЬ МОЖНО ТОЛЬКО ЖИВОГО ЧЕЛОВЕКА.
	#
	# `read` без терминала не ждёт — он читает конец файла и возвращает пустоту
	# мгновенно. Дальше установка падала бы на «Не заданы обязательные
	# параметры», и причина выглядела бы как «параметры не заданы», хотя на
	# самом деле их НЕ У КОГО СПРОСИТЬ. Это правило 47: подпись, называющая
	# причину вместо факта, отправляет разбор не туда. Разница важна: в первом
	# случае человек вписывает значение, во втором — меняет способ запуска.
	# ХЕШИ VK НЕ СПРАШИВАЕМ (04.10.2026, владелец): человек входит в панель без них и добавляет их там сам.
	# Спрашиваем только пароль туннеля.
	if [ -z "$PASSWORD" ]; then
		if [ ! -t 0 ]; then
			say "Нечего спросить: у установщика нет терминала (его запустили через конвейер или из другого скрипта)."
			say "Задай значения одним из двух способов:"
			say "  1) вписать в шапку install.sh строку VSHITO_PASSWORD;"
			say "  2) передать окружением:  PASSWORD='...' sh install.sh"
			die "Пароль не задан, а спросить некого"
		fi
	fi
	if [ -z "$PASSWORD" ]; then printf "Пароль туннеля: "; read PASSWORD; fi
	# Пир отдельной строкой: он приходит из умолчания, и «пусто» здесь значит,
	# что кто-то стёр умолчание правкой, а не что человек забыл ответить.
	[ -n "$PEER" ] || die "Не задан адрес сервера (PEER). В раздаваемом установщике он стоит умолчанием — значит правка стёрла его"
	[ -n "$PASSWORD" ] || die "Не задан пароль туннеля"
	CLIENT_VER=""
	for cvbase in $BASE_URLS; do
		CLIENT_VER=$(dl - "$cvbase/VERSION_CLIENT" 2>/dev/null | head -c 30 | tr -d '\n\r')
		[ -n "$CLIENT_VER" ] && break
	done
	[ -z "$CLIENT_VER" ] && CLIENT_VER="1.0"
	# SCRIPTS_VER (05.10.2026): без него свежая панель считает версию скриптов «неизвестной» и вечно предлагает
	# «Обновить скрипты». Пишем версию раздачи, с которой ставили.
	SCRIPTS_VER=""
	for svbase in $BASE_URLS; do
		SCRIPTS_VER=$(dl - "$svbase/VERSION_SCRIPTS" 2>/dev/null | head -c 30 | tr -d '\n\r')
		[ -n "$SCRIPTS_VER" ] && break
	done
	cat > "$CONF_FILE" <<EOF
PEER="$PEER"
PASSWORD="$PASSWORD"
VK_HASHES="$VK_HASHES"
N="$N"
ANON_PATH="$ANON_PATH"
ARCH="$ARCH"
CLIENT_VER="$CLIENT_VER"
SCRIPTS_VER="$SCRIPTS_VER"
DELAY_MIN="$DELAY_MIN"
DEVICE_ID="$DEVICE_ID"
EOF
	chmod 600 "$CONF_FILE"
	say "Конфиг сохранён: $CONF_FILE"
	# ОТКУДА взялось каждое значение. Пароль и хеши не печатаем — только источник.
	say "  адрес сервера: $PEER ($_ist_peer)"
	say "  пароль:        задан ($_ist_pass)"
	if [ -n "$VK_HASHES" ]; then
		say "  хеши VK:       $(echo "$VK_HASHES" | tr ',' '\n' | grep -c . ) шт. ($_ist_vk)"
	else
		etap "Хеши VK не заданы — добавьте ссылки на звонки VK в веб-панели, после этого туннель поднимется."
	fi
}

# is_openwrt_procd — procd-система (OpenWRT/LEDE)?
#
# ПРОВЕРЯЕТСЯ НАЛИЧИЕ /etc/rc.common, а не `command -v procd`. Именно на этом
# 17.08.2026 GL-MT3000 с OpenWrt 25.12.5 остался БЕЗ АВТОЗАПУСКА ВООБЩЕ: procd
# лежит в /sbin и в PATH установщика не попал, условие не выполнилось, и
# установщик ушёл в ветку «init.d не найден — запускаю руками». Клиент и панель
# работали, пока не перезагрузили роутер.
is_openwrt_procd() {
	[ -d /etc/init.d ] || return 1
	[ -f /etc/rc.common ] || [ -x /sbin/procd ] || [ -x /usr/sbin/procd ] || return 1
	return 0
}

# autostart_ok — автозапуск РЕАЛЬНО настроен? Проверяется факт, а не намерение:
# файл на месте, исполняемый, а для procd — ещё и симлинк в /etc/rc.d (его
# создаёт `enable`; без него служба не поднимется после перезагрузки).
autostart_ok() {
	INIT="$1"
	[ -f "$INIT" ] && [ -x "$INIT" ] || return 1
	case "$INIT" in
		/etc/init.d/*)
			ls /etc/rc.d/*"$(basename "$INIT")" >/dev/null 2>&1 || return 1
			;;
	esac
	return 0
}

# stage_init_script — принести init-скрипт ДО того, как что-либо записано.
#
# Это и есть лекарство от половинного состояния: если init-скрипта нет, отказ
# случится здесь, когда ни конфига, ни DEVICE_ID ещё не существует. Раньше он
# качался в setup_initd, то есть уже после setup_config, и роутер оставался с
# конфигом без программы.
INIT_STAGED=""
INIT_TARGET=""
stage_init_script() {
	mkdir -p "$RUN_DIR" 2>/dev/null || true
	if [ -d "$INITD_ENTWARE_DIR" ]; then
		INIT_TARGET="$INITD_ENTWARE_DIR/S99qwdtt"
		INIT_SRCNAME="qwdtt-init-entware.sh"
	elif is_openwrt_procd; then
		INIT_TARGET="/etc/init.d/qwdtt"
		INIT_SRCNAME="qwdtt-init-openwrt.sh"
	else
		say "ВНИМАНИЕ: ни $INITD_ENTWARE_DIR (Entware), ни procd не найдены — автозапуска не будет"
		INIT_TARGET=""
		return 0
	fi
	INIT_STAGED="$RUN_DIR/$INIT_SRCNAME"
	say "Беру init-скрипт заранее: $INIT_SRCNAME (до записи конфига)"
	fetch_to_target "$INIT_SRCNAME" "$INIT_STAGED" 500 script ||
		die "Не скачать $INIT_SRCNAME. Без него автозапуск не настроить, а ставить наполовину нельзя"
}

setup_initd() {
	if [ -n "$INIT_TARGET" ] && [ -n "$INIT_STAGED" ] && [ -s "$INIT_STAGED" ]; then
		INITD="$INIT_TARGET"
		note_created "$INITD"
		cp "$INIT_STAGED" "$INITD.incoming" || die "Не положить init-скрипт в $(dirname "$INITD")"
		mv -f "$INITD.incoming" "$INITD" || die "Не подменить $INITD"
		chmod +x "$INITD"
		case "$INITD" in
			/etc/init.d/*) "$INITD" enable 2>/dev/null || true; "$INITD" start 2>/dev/null || true
			               say "Автозапуск (OpenWRT): $INITD" ;;
			*)             say "Автозапуск (Entware): $INITD"; "$INITD" start || true ;;
		esac
		return 0
	fi
	# Сюда попадаем, только если init.d на роутере нет ВООБЩЕ (ни Entware, ни
	# procd). Тогда автозапуска не будет — и это говорится вслух, а не молча.
	say "init.d не найден — автозапуска нет, запускаю клиента вручную на этот сеанс"
	"$BIN_PATH" -peer "$PEER" -password "$PASSWORD" -vk "$VK_HASHES" -vk-anon-path "$ANON_PATH" -n "$N" -device-id "$DEVICE_ID" -listen 127.0.0.1:9000 < /dev/null > "$LOG_FILE" 2>&1 &
}

# write_web_init <куда> <имя в раздаче> — скачать init-скрипт панели.
#
# Без автозапуска панель живёт до первой перезагрузки, поэтому неудача здесь —
# это предупреждение, а не тихий пропуск: человек должен знать, что после
# перезагрузки панели не будет.
write_web_init() {
	note_created "$1"
	if fetch_to_target "$2" "$1" 300 script; then
		return 0
	fi
	say "ВНИМАНИЕ: не удалось скачать $2 — автозапуск панели НЕ настроен"
	return 1
}



install_helper() {
	HELP="$INSTALL_DIR/qwdtt-ctl"
	note_created "$HELP"
	# Через тот же путь, что и бинари: не поверх боевого файла, с проверкой
	# шебанга и размера. Иначе оборванное скачивание оставляет вместо хелпера
	# огрызок, а хелпером человек чинит всё остальное.
	if fetch_to_target "qwdtt-ctl" "$HELP" 500 script; then
		say "Хелпер управления установлен: qwdtt-ctl (набери 'qwdtt-ctl' для справки)"
		return
	fi
	say "Хелпер qwdtt-ctl не скачался (не критично)"
}


# ---------- движок маршрутизации ----------
#
# ROUTE_MIN — пол, ловящий ГРУБЫЙ обрыв скачивания, и только его. Числа рядом,
# чтобы следующий человек видел отношение: сегодняшний движок 1.7 весит 66 448 Б,
# самая маленькая версия, которую мы когда-либо выкладывали (v1test) — 36 324 Б.
# Порог 20 000 лежит ниже обеих с запасом.
#
# Что будет, если движок ЗАКОННО похудеет ниже порога: скачивание откажет со
# словами «обрывок», и это надо будет чинить правкой порога. Но ПРИГОВОР уже
# установленному файлу выносится по СУММЕ, а не по размеру, — значит исправный,
# но похудевший движок на роутере битым не объявят никогда.
ROUTE_MIN=20000

# install_engine — принести движок и записать эталон суммы, если он подтверждён.
#
# Эталон (.meridian-route.sha) пишется ТОЛЬКО после успешной сверки скачанного с
# SHA256SUMS раздачи. Никогда — от файла, который просто лежит: сверка вещи с
# копией самой себя не может покраснеть, и подмена ПАРЫ «файл + .sha» прошла бы
# незамеченной (правило владельца от 24.08.2026).
install_engine() {
	ENGINE="$INSTALL_DIR/meridian-route"
	# ЭТАЛОН — ОДИН ПУТЬ НА ВСЕХ, и он там, где эталон ЧИТАЮТ (init-скрипт).
	# Разбор 25.08.2026: здесь эталон писался рядом с бинарём ($INSTALL_DIR), а
	# init читает его из /opt/etc/qwdtt/. Пишущий и читающий смотрели в разные
	# файлы, и «эталон переписан» не значило ничего.
	# Строка ниже обязана СОВПАДАТЬ со строкой в qwdtt-init-entware.sh и
	# qwdtt-ctl — это проверяет сканер в test-scripts.sh.
	ENGSHA="${QWDTT_ROUTE_SHA:-${QWDTT_CONF_DIR:-/opt/etc/qwdtt}/.meridian-route.sha}"
	# Прежнее место: снимаем, чтобы не осталось файла, который никто не читает.
	rm -f "${QWDTT_ROUTE_SHA_OLD:-/opt/bin/.meridian-route.sha}" 2>/dev/null || true
	note_created "$ENGINE"
	if ! fetch_to_target "meridian-route" "$ENGINE" "$ROUTE_MIN" script; then
		say "Движок маршрутизации не скачался — установка продолжается без него."
		say "  Клиент без движка работает; маршрутизации по списку адресов не будет."
		say "  Доустановить потом: qwdtt-ctl repair"
		rm -f "$ENGSHA" 2>/dev/null || true
		return 0
	fi
	if [ "$FETCH_VERIFIED" = 1 ] && command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$ENGINE" | awk '{print $1}' > "$ENGSHA" 2>/dev/null
		note_created "$ENGSHA"
		say "Движок маршрутизации установлен, эталон суммы записан"
	else
		# Сумма не подтверждена манифестом — эталона быть НЕ ДОЛЖНО, иначе он
		# закрепит непроверенное и все дальнейшие сверки будут зелёными зря.
		rm -f "$ENGSHA" 2>/dev/null || true
		say "Движок маршрутизации установлен, но сумма манифестом НЕ подтверждена —"
		say "  эталон не записываю. Проверить позже: qwdtt-ctl repair"
	fi
	return 0
}

# install_dns_entware — докачать и запустить ustanovka-dns.sh как ПОСЛЕДНИЙ
# шаг основной установки на Entware. Владелец 15.09.2026: «почему он отдельный
# от основного установщика? вшей в основной».
#
# НЕ ПЕРЕПИСАНО ВНУТРЬ install.sh, А ВЫЗЫВАЕТСЯ — ustanovka-dns.sh остаётся
# ОДНИМ файлом на троих вызывающих (сам он же: переезд парка, /api/update
# панели), это сделано намеренно и объяснено в его собственной шапке: три
# копии одной логики разъезжались молча, и это стоило реальных аварий
# (правило 51). Переписывание его тела прямо сюда вернуло бы ровно ту
# опасность, а не убрало её. Здесь — просто автоматический вызов, чтобы для
# КЛИЕНТА это выглядело как один установщик, ставящий всё сразу.
#
# НЕФАТАЛЬНО. DNS — дополнительный компонент (свой список доменов), а не
# базовый: клиент и панель работают и без него. Отказ здесь не должен валить
# установку клиента/панели — та же логика, что у install_engine выше.
#
# ТОЛЬКО ENTWARE. На OpenWrt meridian-dns уже ставится раньше, отдельной
# веткой (install_openwrt_part, см. выше) — второй раз его звать здесь
# означало бы два разных пути установки одного и того же компонента.
#
# QWDTT_SKIP_DNS=1 — ТОЛЬКО для прогонов: ustanovka-dns.sh тянет ipset и
# реальные системные пакеты (opkg install), гонять это в каждом стенде было
# бы медленно и не про то, что стенд проверяет.
# dochernij — запуск дочернего скрипта (DNS, анти-DPI). Кратко: его вывод — в журнал, на экран строка итога, при сбое
# последние строки журнала (диагностика). QWDTT_VERBOSE=1 — прямой вывод, как раньше.
dochernij() {
	if [ "${QWDTT_VERBOSE:-0}" = 1 ]; then sh "$1"; return $?; fi
	_dc_n=$(wc -l < "$QWDTT_INSTALL_LOG" 2>/dev/null || echo 0)
	sh "$1" >> "$QWDTT_INSTALL_LOG" 2>&1 && { echo "[meridian]   готово"; return 0; }
	_dc_rc=$?
	echo "[meridian]   не встал (код $_dc_rc), последние строки:"
	tail -n +"$((_dc_n + 1))" "$QWDTT_INSTALL_LOG" 2>/dev/null | tail -n 12 | sed 's/^/    /'
	return "$_dc_rc"
}

install_dns_entware() {
	[ "$PLATFORM" = "openwrt" ] && return 0
	[ "${QWDTT_SKIP_DNS:-0}" = "1" ] && { say "сервер DNS: пропущен (QWDTT_SKIP_DNS=1)"; return 0; }
	DNS_INSTALLER="$RUN_DIR/.ustanovka-dns.sh"
	say ""
	etap "Ставлю сервер DNS"
	if ! fetch_to_target "ustanovka-dns.sh" "$DNS_INSTALLER" 5000 script; then
		say "Сервер DNS не скачался — установка клиента и панели прошла успешно,"
		say "  список доменов пока недоступен. Доустановить: sh $DNS_INSTALLER"
		say "  (или заново: wget -O /tmp/ustanovka-dns.sh $PUBLIC_BASE_URL/ustanovka-dns.sh && sh /tmp/ustanovka-dns.sh)"
		return 0
	fi
	# КОД ВОЗВРАТА ustanovka-dns.sh — ЕГО ДОГОВОР (см. его же шапку): 0 —
	# встало и пережило перезапуск, 1 — отказ с полным откатом, 2 — не узнали.
	# Ни один из трёх не должен уронить install.sh целиком: DNS необязателен.
	if dochernij "$DNS_INSTALLER"; then
		say "Сервер DNS установлен."
	else
		say "Сервер DNS не встал (причина — в выводе выше). Установка клиента и"
		say "  панели при этом прошла успешно. Доустановить позже: sh $DNS_INSTALLER"
	fi
	return 0
}

# install_antidpi_entware — анти-DPI Кота 1 (движок, ctl с группами, свой
# автозапуск, независимое правило NFQUEUE 500) ПОСЛЕДНИМ шагом, после DNS:
# правило опирается на метку туннеля движка маршрутизации.
#
# ВЫЗЫВАЕТСЯ, а не переписано внутрь — ustanovka-antidpi.sh один на двоих
# (кнопка «Обновить веб-панель» через KOMPONENTY и этот установщик), причины те
# же, что у install_dns_entware выше. Исполнитель сам проверяет память (≥20 МБ),
# модули ядра NFQUEUE, место; если стоит nfqws2 — останавливает и отводит его
# (не удаляет); при любой неудаче возвращает всё как было.
#
# НЕФАТАЛЬНО: анти-DPI — дополнение, клиент и панель работают без него.
# ТОЛЬКО ENTWARE: на OpenWrt анти-DPI ставит ustanovit_antidpi_openwrt.
# QWDTT_SKIP_ANTIDPI=1 — только для прогонов.
install_antidpi_entware() {
	[ "$PLATFORM" = "openwrt" ] && return 0
	[ "${QWDTT_SKIP_ANTIDPI:-0}" = "1" ] && { say "анти-DPI: пропущен (QWDTT_SKIP_ANTIDPI=1)"; return 0; }
	ADPI_INSTALLER="$RUN_DIR/.ustanovka-antidpi.sh"
	say ""
	etap "Ставлю анти-DPI"
	if ! fetch_to_target "ustanovka-antidpi.sh" "$ADPI_INSTALLER" 5000 script; then
		say "Анти-DPI не скачался — клиент и панель установлены, анти-DPI можно"
		say "  поставить позже кнопкой «Обновить веб-панель» в панели."
		return 0
	fi
	if dochernij "$ADPI_INSTALLER"; then
		say "Анти-DPI установлен."
	else
		say "Анти-DPI не встал (причина — в выводе выше). Клиент и панель при этом"
		say "  установлены. Повторить: кнопка «Обновить веб-панель» в панели."
	fi
	return 0
}

install_probe() {
	PROBE="$INSTALL_DIR/qwdtt-probe.sh"
	# Через тот же путь, что бинари и хелпер: сырой $DL писал ПОВЕРХ боевого
	# файла и не проверял ни шебанга, ни суммы — оборвалось скачивание, и на
	# роутере вместо пробника огрызок.
	note_created "$PROBE"
	if ! fetch_to_target "qwdtt-probe.sh" "$PROBE" 500 script; then
		say "Диагностический пробник не скачался (не критично)"
		return 0
	fi
	# Entware хранит расписание в /opt/etc/crontabs, OpenWRT — в /etc/crontabs.
	# Сам пробник по умолчанию пишет в /opt/etc/crontabs/root, здесь только
	# подсказываем ему правильный файл на OpenWRT-роутерах.
	if [ -d "$INITD_ENTWARE_DIR" ]; then
		PROBE_CRONFILE="/opt/etc/crontabs/root" "$PROBE" install >/dev/null 2>&1 || true
	else
		PROBE_CRONFILE="/etc/crontabs/root" "$PROBE" install >/dev/null 2>&1 || true
	fi
	say "Диагностика канала: $PROBE (раз в минуту, лог /opt/var/log/qwdtt-probe.log)"
}


WEB_INITD=""

# panel_port_listening — порт панели (8090) реально слушается? Без внешних
# зависимостей: /proc/net/tcp есть всегда, а wget/curl на роутере может не
# быть. Тот же приём, что в qwdtt-web-updater.sh (проверен там прогонами) —
# ОБА файла, tcp и tcp6, потому что панель на Go слушает двойным стеком, и
# сокет виден ТОЛЬКО в tcp6. Заведён здесь отдельно, а не общим вызовом: этот
# файл раздаётся и исполняется самостоятельно, без соседних скриптов рядом.
panel_port_listening() {
	for f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "$f" ] || continue
		if awk -v p=":1F9A" '$2 ~ p"$" && $4 == "0A" {found=1} END{exit !found}' "$f" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

# say_panel_started — сказать про панель ПРАВДУ, а не факт запуска команды.
#
# До 14.09.2026 здесь стояло безусловное «Веб-панель установлена и запущена»
# сразу после вызова start — код возврата инициализационного скрипта не
# смотрели вовсе (у OpenWrt строка ещё и глушила stderr в /dev/null). Человек
# получал «запущена» даже когда панель не поднялась, и узнавал правду только
# когда открывал браузер (правило 52 — тихий код 0 это не «сделано»). Панель
# на слабом железе поднимается не мгновенно, поэтому — несколько попыток с
# паузой, а не один мгновенный опрос.
#
# ЗОВЁТСЯ ЧЕРЕЗ `|| true`, И ЭТО НЕ КОСМЕТИКА (найдено прогоном 15.09.2026).
# В файле стоит `set -e`: функция, вернувшая 1 простым оператором, роняет ВЕСЬ
# установщик на месте. То есть медленная панель (>10 с на слабом железе) не
# просто печатала бы предупреждение, а обрывала установку сразу после неё —
# без отчёта про автозапуски и без финальных строк. Предупреждение о том, что
# порт молчит, — это повод сказать человеку, а не повод бросить установку
# половинной. Прогон поймал это на 17 красных проверках, эталон (боевой
# install.sh без этой функции) их не давал.
say_panel_started() {
	i=0
	while [ "$i" -lt 10 ]; do
		if panel_port_listening; then
			say "Веб-панель установлена и запущена"
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	say "!!! панель установлена, но порт 8090 за 10 секунд не ответил — проверь: $WEB_INITD status"
	return 1
}

install_web() {
	WEBBIN="$INSTALL_DIR/qwdtt-web"
	note_created "$WEBBIN"
	# ИМЯ ПАНЕЛИ — СВОЁ ДЛЯ КАЖДОЙ ПЛАТФОРМЫ. Сборка под нативный OpenWrt
	# отличается не только путями внутри: она знает про procd, про /etc/qwdtt и
	# про то, что здесь нет qwdtt-ctl. Парковая панель на OpenWrt поднимется и
	# будет показывать «остановлен» при живом туннеле — мы это уже видели.
	WEBFILE=$(dist_name "qwdtt-web-$ARCH")
	# Качаем НЕ поверх боевого файла. Прежняя строка писала прямо в $WEBBIN, и
	# оборванное скачивание оставляло роутер без панели — ровно это и случилось
	# 17.08.2026, только через другой путь.
	if ! fetch_to_target "$WEBFILE" "$WEBBIN" 1000000; then
		say "Веб-панель не скачалась (не критично) — прежняя панель, если была, не тронута"
		return
	fi

	# по умолчанию БЕЗ пароля (защита — только LAN). Включить пароль:
	#   echo "логин:пароль" > /opt/etc/qwdtt/web.auth
	# Путь к файлу пароля — ИЗ ПЕРЕМЕННОЙ, а не зашитый /opt: на нативном
	# OpenWrt он живёт в /etc/qwdtt (там же, где конфиг клиента), и зашитая
	# парковая строка здесь не удаляла ничего — то есть пароль от прошлой
	# установки мог остаться незамеченным.
	rm -f "$CONF_DIR/web.auth"

	# init-скрипты панели скачиваются из раздачи, а не пишутся здесь heredoc-ом.
	# Причина: пока они жили только внутри install.sh, у уже установленных
	# роутеров автозапуск не обновлялся ничем — правка доезжала переустановкой,
	# то есть никогда.
	# ВЕТВИМСЯ ПО PLATFORM, А НЕ ПО ВТОРОМУ СПОСОБУ ОПОЗНАНИЯ.
	#
	# Здесь стояло `if -d $INITD_ENTWARE_DIR … elif is_openwrt_procd`, то есть
	# платформа определялась ВТОРОЙ РАЗ и по другим признакам. Два независимых
	# определения одного и того же неизбежно расходятся (правило 51), и стенд
	# поймал это сразу: панель поставилась, а автозапуска у неё не появилось —
	# первая ветка не подошла, вторая не сработала, и ни одна не сказала ни слова.
	if [ "$PLATFORM" = "openwrt" ]; then
		WEB_INITD="$INITD_OPENWRT_DIR/qwdtt-web"
		write_web_init "$WEB_INITD" qwdtt-web-init-openwrt.sh
		chmod +x "$WEB_INITD"
		# Автозапуск — через общую функцию, которая проверяет ФАКТ (симлинк в
		# rc.d), а не код возврата enable: он у rc.common равен нулю и тогда,
		# когда ссылка не создалась.
		enable_openwrt_service qwdtt-web || OPENWRT_AUTOSTART_INCOMPLETE=1
		"$WEB_INITD" start 2>/dev/null
		say_panel_started || true
	elif [ -d "$INITD_ENTWARE_DIR" ]; then
		WEB_INITD="$INITD_ENTWARE_DIR/S98qwdtt-web"
		write_web_init "$WEB_INITD" qwdtt-web-init-entware.sh
		chmod +x "$WEB_INITD"
		"$WEB_INITD" start
		say_panel_started || true
	else
		# НИ ТА, НИ ДРУГАЯ — И ОБ ЭТОМ НАДО СКАЗАТЬ. Молчание здесь означало бы
		# «панель есть, автозапуска нет», и человек узнал бы об этом только после
		# перезагрузки, когда панель не открылась.
		say "!!! автозапуск панели не настроен: не найден ни $INITD_ENTWARE_DIR, ни procd"
	fi

	vecho ""
	vecho "=================================================================="
	vecho " ВЕБ-ПАНЕЛЬ:"
	# Без `grep -o`: этот ключ в BusyBox собирается отдельной опцией, а awk есть
	# везде и делает то же самое одним проходом (ревизия 18.08.2026 — после того,
	# как `od -A` оказался отсутствующим ключом, все такие места пересмотрены).
	LANIPS=$(ip -4 addr show 2>/dev/null | awk '$1=="inet"{split($2,a,"/"); ip=a[1];
		if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) print ip}')
	# приоритет: типовой домашний адрес роутера (обычно .1 в подсети /24), иначе первый найденный
	SHOWIP=$(printf '%s\n' "$LANIPS" | grep -E '^192\.168\.[0-9]+\.1$' | head -1)
	[ -z "$SHOWIP" ] && SHOWIP=$(printf '%s\n' "$LANIPS" | grep -E '\.1$' | head -1)
	[ -z "$SHOWIP" ] && SHOWIP=$(printf '%s\n' "$LANIPS" | head -1)
	[ -z "$SHOWIP" ] && SHOWIP="<IP роутера в локальной сети>"
	vecho "   http://$SHOWIP:8090"
	vecho "=================================================================="
}

# --- MAIN ---
#
# Установку можно ПОДКЛЮЧИТЬ без запуска: `QWDTT_INSTALL_SOURCE_ONLY=1 . install.sh`
# отдаёт функции и не трогает роутер. Нужно для проверок (test-scripts.sh):
# определение архитектуры и безопасное скачивание — как раз то, что нельзя
# проверять установкой на живом роутере.
if [ -n "${QWDTT_INSTALL_SOURCE_ONLY:-}" ]; then
	return 0 2>/dev/null || exit 0
fi

INSTALL_RUNNING=1
say "=== Установка meridian ==="
detect_arch
check_env
etap "Установка Meridian: $PLATFORM, $ARCH"
etap "Ставлю клиент"
# Порядок не случайный: сначала приносим ВСЁ, без чего установка не имеет
# смысла (бинарь и init-скрипт), и только потом трогаем конфиг. Отказ на
# скачивании обязан случаться там, где на роутере ещё ничего не создано.
stage_init_script
owrt_zapomnit
download_bin
setup_config
setup_initd
install_openwrt_stack
if [ "$PLATFORM" = "openwrt" ]; then
	# qwdtt-ctl СЮДА НЕ СТАВИТСЯ. Он написан под Entware: зовёт /opt/bin,
	# читает /opt/var/log, управляет S99-автозапуском. На procd-прошивке он
	# не работает ни одной командой, но его НАЛИЧИЕ обманывает: панель искала
	# его как признак живого клиента и показывала «остановлен» при работающем
	# туннеле (замер на роутере владельца 12.09.2026). Лучше не ставить вовсе,
	# чем поставить нерабочим.
	say "хелпер qwdtt-ctl: на этой прошивке не ставится (он написан под Entware)"
else
	install_helper
fi
if [ "$PLATFORM" = "openwrt" ]; then
	# ПРОБНИК ЗДЕСЬ НЕ СТАВИТСЯ. Он ходит через qwdtt-ctl и пишет в
	# /opt/var/log; ни того, ни другого на этой платформе нет. Поставить его
	# «как есть» значит положить файл, который каждую минуту падает в cron и
	# растит журнал — тихо и без единой ошибки на экране.
	say "пробник канала: на этой прошивке не ставится (нужен qwdtt-ctl, которого здесь нет)"
else
	install_probe
fi
# Движок — ПОСЛЕ клиента и до панели. Отказ движка установку не валит: клиент без
# него работает, просто нет маршрутизации по списку адресов.
if [ "$PLATFORM" = "openwrt" ]; then
	# ПАРКОВЫЙ ДВИЖОК СЮДА НЕ СТАВИТСЯ. На этой платформе маршрут по метке
	# держит meridian-route-min (поставлен выше, в составе), а парковый
	# meridian-route рассчитан на ipset и Entware-пути. Два движка рядом — это
	# два хозяина у одного маршрута, и спорить они будут молча.
	say "движок маршрутизации: здесь работает meridian-route-min (поставлен выше)"
else
	etap "Ставлю движок маршрутизации"
	install_engine
fi
etap "Ставлю веб-панель"
install_web
owrt_perezapusk
owrt_dhcp_bystro
owrt_luci_stranica
# Сервер DNS — ПОСЛЕДНИЙ шаг, после клиента, движка и панели. Владелец
# 15.09.2026: «почему он отдельный от основного установщика? вшей в основной».
install_dns_entware
zalit_spisok_po_umolchaniyu
# Анти-DPI — после DNS: правило очереди опирается на метку туннеля движка.
install_antidpi_entware
belyj_po_umolchaniyu
say ""

# ---------- Утверждение про автозапуск, а не намёк ----------
#
# До 17.08.2026 установщик заканчивался строкой «Готово» и подразумевал, что
# автозапуск настроен. На GL-MT3000 (OpenWrt 25.12.5) его не было ВООБЩЕ: клиент
# и панель работали только потому, что их запустил сам установщик, и первая же
# перезагрузка роутера оставила бы человека ни с чем. Теперь установщик
# ПРОВЕРЯЕТ факт и говорит его вслух — либо честно признаётся, что не настроил.
ASOK=1
if [ -n "${INITD:-}" ] && autostart_ok "$INITD"; then
	say "автозапуск настроен: $INITD (клиент)"
else
	ASOK=0
	say "!!! АВТОЗАПУСК КЛИЕНТА НЕ НАСТРОЕН — после перезагрузки роутера туннель не поднимется"
	if [ -n "${INITD:-}" ]; then
		say "    проверь: ls -l $INITD; ls -l /etc/rc.d/ | grep qwdtt"
	else
		say "    ни /opt/etc/init.d (Entware), ни /etc/init.d с procd не найдены"
	fi
fi
if [ -n "${WEB_INITD:-}" ] && autostart_ok "$WEB_INITD"; then
	say "автозапуск настроен: $WEB_INITD (панель)"
else
	ASOK=0
	say "!!! АВТОЗАПУСК ПАНЕЛИ НЕ НАСТРОЕН — после перезагрузки роутера панель не поднимется"
fi
if [ "$ASOK" = 1 ]; then
	say "перезагрузка роутера переживается: оба автозапуска на месте"
else
	say "НАПИШИ ОБ ЭТОМ В ПОДДЕРЖКУ: установка прошла, но автозапуск неполный"
fi

# Временная подпорка S00meridian-fastnat: сказать о ней, если она есть.
#
# Она выключает АППАРАТНУЮ РАЗГРУЗКУ, то есть роутер начинает гонять трафик
# программно — это плата за работу маршрутизации до движка 1.16. После 1.16 она
# не нужна. Молча оставленная, она выглядит как штатная часть установки, и
# человек будет годами платить за неё скоростью, не зная об этом.
#
# Установщик её НЕ СНИМАЕТ: снимает владелец сам. Удаление чужого файла без
# спроса — не наша работа, а сказать о нём — наша.
if [ -e /opt/etc/init.d/S00meridian-fastnat ]; then
	say "ВНИМАНИЕ: найдена временная подпорка /opt/etc/init.d/S00meridian-fastnat"
	say "    она выключает аппаратную разгрузку роутера (трафик идёт программно)"
	say "    после движка 1.16 она НЕ НУЖНА; снять её нужно вручную, установщик её не трогает"
fi

say "Готово. Управление: ${INITD:-<init не настроен>} {start|stop|restart|status}"
etap "Готово."
say "Логи: $LOG_FILE"

# ПОВТОР АДРЕСА ПАНЕЛИ — САМЫМ ПОСЛЕДНИМ. install_web() печатает его же рамкой
# выше по выводу, но install_dns_entware() идёт ПОСЛЕ install_web НАРОЧНО
# (владелец 15.09.2026: «вшей в основной», см. комментарий у вызова) и сам
# даёт полсотни строк, а при недостающем ipset — вдвое больше (установка
# пакетов через opkg). Рамка с адресом панели гарантированно уезжает за экран
# раньше, чем человек успевает её увидеть, и финальная строка «Готово» адрес
# не называла вовсе — 20.09.2026 клиент установил всё успешно и не нашёл
# панель, пришлось отправлять адрес отдельно текстом. $SHOWIP не local (в
# install_web() обычное присваивание) — доступен здесь без пересчёта.
if [ -n "${SHOWIP:-}" ]; then
	echo ""
	echo "=================================================================="
	echo " ВЕБ-ПАНЕЛЬ: http://$SHOWIP:8090"
	echo "=================================================================="
fi
etap "Журнал установки (пришлите его, если что-то не заработало): $QWDTT_INSTALL_LOG"
