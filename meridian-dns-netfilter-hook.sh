#!/bin/sh
# 50-meridian-dns.sh — крючок ndm: вернуть заворот и пометку СРАЗУ после того,
# как прошивка пересобрала netfilter.
#
# Ставится в /opt/etc/ndm/netfilter.d/50-meridian-dns.sh.
#
# ЗАЧЕМ. 04.09.2026 заворот пропадал у владельца ДВАЖДЫ за вечер, второй раз
# вместе с цепочкой в mangle: ndm пересобирает netfilter целиком и сносит все
# чужие цепочки. Периодика чинит это не позже чем через минуту, и минуту дом
# резолвит мимо нас. Крючок сокращает окно до секунд.
#
# ОТСТУПЫ — ПРОБЕЛЫ. Файл исполняется, но держим единообразно с блоками.

# ndm зовёт крючок на КАЖДУЮ таблицу и на оба семейства. Нас касаются только
# iptables/nat и iptables/mangle: на ip6tables у нас нет ни одного правила, а
# лишний запуск — это лишний probe на 2 секунды в самый занятый момент загрузки.
if [ "$type" = "ip6tables" ]; then
    exit 0
fi
case "$table" in
    nat|mangle) ;;
    *) exit 0 ;;
esac

BIN=/opt/bin/meridian-dns
# Крючок обязан пережить удаление пакета: файл в netfilter.d остаётся, а
# программы уже нет. Без этой проверки ndm получал бы ошибку на каждой
# пересборке.
if [ ! -x "$BIN" ]; then
    exit 0
fi

CONF=/opt/etc/qwdtt/meridian-dns.yaml
RUN=/opt/var/run
LOG=/opt/var/log/meridian-dns.log
LOCK=$RUN/meridian-dns-hook.lock
# .env ПОДКЛЮЧАЕТСЯ ДО ВЫЧИСЛЕНИЯ ПЕРЕМЕННЫХ, а не после.
#
# 07.09.2026, поймано стендом задержки: здесь было наоборот, и значения из
# .env не применялись НИКОГДА — `${MERIDIAN_DNS_LISTEN:-…}` уже подставил
# умолчание к моменту, когда файл читался. Крючок опрашивал 192.168.1.1:5453
# вместо настоящего адреса роутера, получал «сервер молчит» и шёл снимать
# заворот у живого сервера.
#
# Ровно эта же ошибка была в init-скрипте и починена там 06.09; вторая копия
# рядом с первой разъехалась молча (правило 51: чинить надо ВСЕ двери).
if [ -f /opt/etc/qwdtt/meridian-dns.env ]; then
    . /opt/etc/qwdtt/meridian-dns.env 2>/dev/null
fi

# Умолчание — auto:5453, как в init-скрипте, а не зашитый 192.168.1.1.
# Зашитый адрес был адресом роутера ВЛАДЕЛЬЦА и ничьим больше.
LISTEN="${MERIDIAN_DNS_LISTEN:-auto:5453}"

# IFACES — ТА ЖЕ ЛОГИКА, ЧТО В meridian-dns-init.sh, СКОПИРОВАНА СЮДА
# НАМЕРЕННО (правило 51 в этот раз уже сработало один раз именно тут — см.
# коммент про LISTEN выше). Правя эту логику — правь оба файла синхронно.
# Список мостов от движка (meridian-route home-ifaces, 1.69+), явный
# MERIDIAN_DNS_IFACES сильнее. Код 2 у home-ifaces — отказ, не повод молча
# взять br0 (владелец, 21.09.2026). Отсутствие самого movidian-route — другой
# случай, br0 остаётся честным умолчанием (зависимости раньше не было).
#
# Бюджет крючка: /sys-проверки внутри home-ifaces не ходят в сеть, стоят
# доли миллисекунды — не тот вызов, который тянет крючок к его потолку в 2,5 с
# (тот расходуется на probe сервера DNS в самом ensure, не здесь).
if [ -n "${MERIDIAN_DNS_IFACES:-}" ]; then
    IFACES="$MERIDIAN_DNS_IFACES"
elif [ -x /opt/bin/meridian-route ]; then
    _HI_ERR="$RUN/.meridian-dns-home-ifaces-err.$$"
    _HI_OUT=$(/opt/bin/meridian-route home-ifaces 2>"$_HI_ERR")
    _HI_RC=$?
    if [ "$_HI_RC" = 0 ] && [ -n "$_HI_OUT" ]; then
        IFACES=$(echo "$_HI_OUT" | tr '\n' ',' | sed 's/,$//')
    elif [ "$_HI_RC" = 2 ]; then
        echo "$(date): ОТКАЗ — meridian-route home-ifaces: $(cat "$_HI_ERR" 2>/dev/null)" >> "$LOG"
        rm -f "$_HI_ERR"
        exit 0
    else
        IFACES="br0"
    fi
    rm -f "$_HI_ERR"
else
    IFACES="br0"
fi
NATCHAIN="${MERIDIAN_DNS_CHAIN:-MERIDIAN_DNS}"
MARKCHAIN="${MERIDIAN_DNS_MARKCHAIN:-MERIDIAN_DNS_MARK}"
IPT_BIN="${MERIDIAN_DNS_IPTABLES:-iptables}"

# ЗАМОК. Пересборка бьёт по nat и mangle подряд, а на загрузке — много раз за
# секунды. Без замка мы завели бы десяток ensure разом, каждый со своим probe:
# на 248 МБ ОЗУ это ровно то, чем мы уже платили (правило 8).
#
# mkdir атомарен и есть в BusyBox; flock есть не везде.
#
# Брошенный замок узнаём по ЖИВОСТИ ПРОЦЕССА, а не по времени файла: держатель
# мог быть убит OOM-killer'ом прямо здесь, и тогда крючок молчал бы навсегда.
# Проверка по /proc точна и не требует ни `find -mmin`, ни арифметики над
# датами — обоих на этом BusyBox может не быть (правило 25).
if ! mkdir "$LOCK" 2>/dev/null; then
    OLD=$(cat "$LOCK/pid" 2>/dev/null)
    ALIVE=0
    case "$OLD" in
        ''|*[!0-9]*) ;;
        *) if [ -d "/proc/$OLD" ]; then ALIVE=1; fi ;;
    esac
    if [ "$ALIVE" = 1 ]; then
        exit 0
    fi
    rm -rf "$LOCK" 2>/dev/null
    if ! mkdir "$LOCK" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP

# Работаем СИНХРОННО, а не в фоне. В фоне замок пришлось бы снимать не тому,
# кто его взял, и «жив ли держатель» стало бы неответимым вопросом. Цена
# синхронности названа: обычный проход — десятки миллисекунд (сервер отвечает
# сразу, цепочки на месте, ни одной записи), худший — около 2,5 секунды
# (молчащий сервер: probe ждёт 2 с). Держать ndm дольше мы не имеем права, и
# больше и не держим.
#
# Восстанавливает ensure, а не свои команды iptables: у правила один владелец,
# а второй набор команд рано или поздно разойдётся с первым. Он же уважает
# отметку сторожа — снятый намеренно заворот крючок не вернёт.
# -caller: ПОДПИСЬ В ЖУРНАЛЕ. Добавлена 07.09.2026. До неё крючок и минутная
# периодика писали одну и ту же строку «периодика:», и починку через секунды
# нельзя было отличить от починки через минуту — а для белого режима это разная
# цена (правило 49: два случая, одна подпись).
$BIN -caller "крючок ndm" -iptables "$IPT_BIN" -chain "$NATCHAIN" -mark-chain "$MARKCHAIN" \
     -listen "$LISTEN" -ifaces "$IFACES" -config "$CONF" \
     -guard-pid "$RUN/meridian-dns-guard.pid" \
     -blocked-mark "$RUN/meridian-dns.blocked" \
     -log "$LOG" ensure >/dev/null 2>&1

exit 0
