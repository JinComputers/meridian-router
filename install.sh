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
#  Первыми идут ВНУТРЕННИЕ адреса шлюза — раздача по самому туннелю. Это
#  нужно там, где мобильный интернет режется по белому списку: туннель живёт
#  (он идёт через VK-релей), а скачивание с публичного адреса VPS уходит мимо
#  туннеля, туда, где закрыто. Добавить публичный адрес в список обхода нельзя:
#  как появится прямой TCP-путь клиент↔VPS, это станет петлёй.
#
#  Внутренних адресов два: 10.77.77.1 — шлюз RAW-режима, 10.66.66.1 — WG.
#  Берём только те, чья подсеть реально есть на интерфейсах: иначе при
#  установке с нуля, когда туннеля ещё нет, каждая попытка висела бы до
#  таймаута. Публичный адрес всегда последний — он же и единственный при
#  установке на чистый роутер.
# QWDTT_PUBLIC_BASE_URL — ТОЛЬКО для прогонов. Без этой возможности проверка
# установщика ходила бы в БОЕВУЮ раздачу и проверяла бы её, а не себя
# (правило 20 в CLAUDE.md — на этом уже сгорели тесты панели).
# Через `-`, а не `:-`: ЯВНО заданное пустое значение означает «публичного
# источника нет», а не «возьми боевой по умолчанию». Разница не теоретическая:
# с `:-` прогон с пустым адресом молча уходил в БОЕВУЮ раздачу и «успешно»
# ставил боевые файлы — то есть проверял не установщик, а её.
PUBLIC_BASE_URL="${QWDTT_PUBLIC_BASE_URL-http://138.124.78.252:8080/bin}"

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
# ПУСТОЕ ЗНАЧЕНИЕ = ОТКЛЮЧЕНО, тем же приёмом через `-`, что и выше: прогон
# теста способен явно обнулить оба публичных источника и не уйти в боевые.
PUBLIC_BASE_URL_RU="${QWDTT_PUBLIC_BASE_URL_RU-http://45.10.247.23/bin}"

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
	for _ip in ${QWDTT_INTERNAL_BASES-10.77.77.1 10.66.66.1}; do
		if same_net16 "$_ip"; then
			_urls="${_urls:+$_urls }http://$_ip:8080/bin"
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
PUBLIC_BASE_URL_GH="${QWDTT_PUBLIC_BASE_URL_GH-https://raw.githubusercontent.com/JinComputers/meridian-router/$GH_BRANCH}"
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

say() { echo "[meridian] $1"; }


# ---------- СОСТАВ НАТИВНОГО OpenWrt ----------
#
# ЧТО СТАВИТСЯ И КУДА (пути замерены по shag2/shag3, которыми мы ставили
# вручную весь сентябрь, а не выведены по аналогии с Entware):
#
#   /usr/sbin/qwdtt-run            запускатель клиента (procd не умеет stdin)
#   /etc/init.d/qwdtt              автозапуск клиента
#   /etc/qwdtt/meridian.nft        таблица inet meridian: набор и пометка
#   /etc/init.d/meridian-nft       загрузчик этой таблицы
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
	"$INITD_OPENWRT_DIR/$_e_name" enable >/dev/null 2>&1 || true
	if ls "$RCD_OPENWRT_DIR"/*"$_e_name" >/dev/null 2>&1; then
		say "  автозапуск включён: $_e_name"
		return 0
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
	install_openwrt_part "meridian.nft" "$CONF_DIR/meridian.nft" 644 script
	install_openwrt_part "meridian-nft" "$INITD_OPENWRT_DIR/meridian-nft" 755 script
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

# INSTALL_RUNNING — идёт ли НАСТОЯЩАЯ установка. При подключении режимом
# SOURCE_ONLY (прогоны, qwdtt-ctl repair) она не идёт, и отчёт «установка не
# завершена, роутер возвращён как был» был бы неправдой о состоянии роутера.
INSTALL_RUNNING=0

die() {
	echo "[meridian][ОШИБКА] $1" >&2
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
	REMKB=$(remote_size_kb "$1")
	if [ -n "$REMKB" ] && [ "$REMKB" -gt 0 ] 2>/dev/null; then
		NEEDKB=$(( REMKB + 512 ))
	else
		NEEDKB=$(( MINSIZE / 1024 + 512 ))
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
		if $DL "$TMPF" "$base/$SRCNAME" 2>"$ERRF"; then
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
		if $DL "$SUMS" "$USEDBASE/SHA256SUMS" 2>/dev/null; then
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

probe_form() { # probe_form "форма" "база" — скачать пробный файл
	_out="$RUN_DIR/.dlprobe.$$"
	rm -f "$_out" "$_out.err" 2>/dev/null || true
	if $1 "$_out" "$2/VERSION_CLIENT" >/dev/null 2>"$_out.err"; then
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
		# программа не успевает сказать ничего.
		[ -n "$DL_ERR" ] || DL_ERR="код $_rc и ни слова в stderr (так выглядит падение по сигналу)"
	fi
	rm -f "$_out" "$_out.err" 2>/dev/null || true
	return 1
}

try_form() { # try_form "форма" — годится ли она хоть с одним источником
	for _b in $BASE_URLS; do
		if probe_form "$1" "$_b"; then
			DL="$1"
			say "Загрузчик: $1 (проверен на $_b)"
			return 0
		fi
	done
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
	_ipo_pkg="$1"
	if command -v apk >/dev/null 2>&1; then
		apk add "$_ipo_pkg" >/dev/null 2>&1 && return 0
	fi
	if command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1
		opkg install "$_ipo_pkg" >/dev/null 2>&1 && return 0
	fi
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
	if $DL "$APK_ETC/keys/meridian-apk.pub.new" "https://feed.meridianvpn.org/keys/meridian-apk.pub" \
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
		say "пункт «Меридиан» добавлен в LuCI (Службы -> Меридиан) -- выйдите из веб-морды OpenWrt и зайдите заново, чтобы он появился"
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
				if $DL "$L_SUMS" "$base/SHA256SUMS" 2>/dev/null; then
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
		die "Скачанный бинарь не запускается на этом железе — определение архитектуры ($ARCH) неверно. Поставь явно: ARCH_OVERRIDE=<mipsle|mips|armv7|arm64> sh install.sh"
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
		_ncv=$($DL - "$_ncvbase/VERSION_CLIENT" 2>/dev/null | head -c 30 | tr -d '\n\r')
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
	if [ -z "$PASSWORD" ] || [ -z "$VK_HASHES" ]; then
		if [ ! -t 0 ]; then
			say "Нечего спросить: у установщика нет терминала (его запустили через конвейер или из другого скрипта)."
			say "Задай значения одним из двух способов:"
			say "  1) вписать в шапку install.sh строки VSHITO_PASSWORD и VSHITO_VK_HASHES;"
			say "  2) передать окружением:  PASSWORD='...' VK_HASHES='...' sh install.sh"
			die "Пароль и хеши не заданы, а спросить некого"
		fi
	fi
	if [ -z "$PASSWORD" ]; then printf "Пароль туннеля: "; read PASSWORD; fi
	if [ -z "$VK_HASHES" ]; then printf "Хэши VK (через запятую): "; read VK_HASHES; fi
	# Пир отдельной строкой: он приходит из умолчания, и «пусто» здесь значит,
	# что кто-то стёр умолчание правкой, а не что человек забыл ответить.
	[ -n "$PEER" ] || die "Не задан адрес сервера (PEER). В раздаваемом установщике он стоит умолчанием — значит правка стёрла его"
	[ -n "$PASSWORD" ] || die "Не задан пароль туннеля"
	[ -n "$VK_HASHES" ] || die "Не заданы хеши VK"
	CLIENT_VER=""
	for cvbase in $BASE_URLS; do
		CLIENT_VER=$($DL - "$cvbase/VERSION_CLIENT" 2>/dev/null | head -c 30 | tr -d '\n\r')
		[ -n "$CLIENT_VER" ] && break
	done
	[ -z "$CLIENT_VER" ] && CLIENT_VER="1.0"
	cat > "$CONF_FILE" <<EOF
PEER="$PEER"
PASSWORD="$PASSWORD"
VK_HASHES="$VK_HASHES"
N="$N"
ANON_PATH="$ANON_PATH"
ARCH="$ARCH"
CLIENT_VER="$CLIENT_VER"
DELAY_MIN="$DELAY_MIN"
DEVICE_ID="$DEVICE_ID"
EOF
	chmod 600 "$CONF_FILE"
	say "Конфиг сохранён: $CONF_FILE"
	# ОТКУДА взялось каждое значение. Пароль и хеши не печатаем — только источник.
	say "  адрес сервера: $PEER ($_ist_peer)"
	say "  пароль:        задан ($_ist_pass)"
	say "  хеши VK:       $(echo "$VK_HASHES" | tr ',' '\n' | grep -c . ) шт. ($_ist_vk)"
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
install_dns_entware() {
	[ "$PLATFORM" = "openwrt" ] && return 0
	[ "${QWDTT_SKIP_DNS:-0}" = "1" ] && { say "сервер DNS: пропущен (QWDTT_SKIP_DNS=1)"; return 0; }
	DNS_INSTALLER="$RUN_DIR/.ustanovka-dns.sh"
	say ""
	say "Ставлю сервер DNS (список доменов в «Своих маршрутах») — последний шаг."
	if ! fetch_to_target "ustanovka-dns.sh" "$DNS_INSTALLER" 5000 script; then
		say "Сервер DNS не скачался — установка клиента и панели прошла успешно,"
		say "  список доменов пока недоступен. Доустановить: sh $DNS_INSTALLER"
		say "  (или заново: wget -O /tmp/ustanovka-dns.sh $PUBLIC_BASE_URL/ustanovka-dns.sh && sh /tmp/ustanovka-dns.sh)"
		return 0
	fi
	# КОД ВОЗВРАТА ustanovka-dns.sh — ЕГО ДОГОВОР (см. его же шапку): 0 —
	# встало и пережило перезапуск, 1 — отказ с полным откатом, 2 — не узнали.
	# Ни один из трёх не должен уронить install.sh целиком: DNS необязателен.
	if sh "$DNS_INSTALLER"; then
		say "Сервер DNS установлен."
	else
		say "Сервер DNS не встал (причина — в выводе выше). Установка клиента и"
		say "  панели при этом прошла успешно. Доустановить позже: sh $DNS_INSTALLER"
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
# До 14.09.2026 здесь стояло безусловное «Веб-морда установлена и запущена»
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
			say "Веб-морда установлена и запущена"
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
		say "Веб-морда не скачалась (не критично) — прежняя панель, если была, не тронута"
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

	echo ""
	echo "=================================================================="
	echo " ВЕБ-МОРДА УПРАВЛЕНИЯ:"
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
	echo "   http://$SHOWIP:8090"
	echo "=================================================================="
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
# Порядок не случайный: сначала приносим ВСЁ, без чего установка не имеет
# смысла (бинарь и init-скрипт), и только потом трогаем конфиг. Отказ на
# скачивании обязан случаться там, где на роутере ещё ничего не создано.
stage_init_script
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
	install_engine
fi
install_web
# Сервер DNS — ПОСЛЕДНИЙ шаг, после клиента, движка и панели. Владелец
# 15.09.2026: «почему он отдельный от основного установщика? вшей в основной».
install_dns_entware
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
	echo " ПАНЕЛЬ УПРАВЛЕНИЯ (то же самое, что было выше — повторяю, чтобы не"
	echo " потерялось за установкой DNS):"
	echo "   http://$SHOWIP:8090"
	echo "=================================================================="
fi
