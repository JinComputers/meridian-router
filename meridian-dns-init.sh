#!/bin/sh
# meridian-dns-init.sh — запуск сервера DNS и его сторожа на роутере.
#
# Ставится в /opt/etc/init.d/S81meridian-dns (после сети, до панели).
#
# ГЛАВНОЕ ПРО ЭТОТ ФАЙЛ. Сервер стоит в разрыве DNS всего дома. Поэтому:
#
#   * заворот ставит и снимает САМА программа, а не этот скрипт. Скрипт,
#     который ставит правило, а потом падает, оставляет дом без DNS, и снять
#     это будет некому;
#   * сторож — ОТДЕЛЬНЫЙ процесс. OOM на роутере с 254 МБ убивает сервер, и
#     сторож внутри сервера умер бы вместе с ним;
#   * периодика раз в минуту (`ensure`) чинит дом, даже если умерли ОБА, и она
#     же поднимает сторожа обратно;
#   * лог с потолком: программа берёт путь из /proc/self/fd/1, поэтому здесь
#     stdout перенаправляется в файл, а не в /dev/null (правило 21).
#
# Отступы — ПРОБЕЛЫ. Файл исполняется, а не вставляется в приглашение, но
# держим единообразно с блоками (правило 38).

BIN=/opt/bin/meridian-dns
IPT_BIN="${MERIDIAN_DNS_IPTABLES:-iptables}"
CONF=/opt/etc/qwdtt/meridian-dns.yaml
LOG=/opt/var/log/meridian-dns.log
RUN=/opt/var/run
PIDFILE="$RUN/meridian-dns.pid"
GUARDPID="$RUN/meridian-dns-guard.pid"
BLOCKED="$RUN/meridian-dns.blocked"
# Пути периодики — переменными: стенду нужно подставить свои, а вписанный
# намертво путь означал бы «проверено на живом роутере или никак».
CRONFILE="${MERIDIAN_DNS_CRONFILE:-/opt/etc/crontabs/root}"
CROND="${MERIDIAN_DNS_CROND:-crond}"
CRONINIT="${MERIDIAN_DNS_CRONINIT:-/opt/etc/init.d/S10cron}"
CRONMARK="meridian-dns ensure"
ROLLBACKMARK=/opt/etc/qwdtt/meridian-dns.rollback
# Имена цепочек — переменными, а не вписанные в строку проверки: иначе
# показатель начнёт врать в тот день, когда имя поменяют флагом.
NATCHAIN="${MERIDIAN_DNS_CHAIN:-MERIDIAN_DNS}"
MARKCHAIN="${MERIDIAN_DNS_MARKCHAIN:-MERIDIAN_DNS_MARK}"
# PROC_ROOT — переменная, а не /proc напрямую: стенду нужно подложить своё
# дерево, той же причиной, что и procRoot в guardpid.go (правило 25/38).
PROC_ROOT="${MERIDIAN_DNS_PROC_ROOT:-/proc}"

# --- настройки, которые человек может переопределить ------------------------
# В qwdtt.conf их НЕ пишем и install.sh их туда не добавляет: явное значение в
# конфиге приколачивает роутер к сегодняшнему умолчанию навсегда (правило 17).
# Порт НИЖЕ эфемерного диапазона ядра (32768-60999 на Keenetic). 53535 был
# внутри него, и 04.09.2026 его занял ndnproxy: bind: address already in use.
# Это лотерея на каждой загрузке, а не разовая неудача.
# ПОРЯДОК ЗДЕСЬ БЫЛ ДЕФЕКТОМ, и он молчаливый.
#
# Файл .env подключался ПОСЛЕ того, как переменные уже вычислены, — значит
# значение, записанное человеком в /opt/etc/qwdtt/meridian-dns.env, в -listen
# не попадало НИКОГДА. Работал только экспорт в окружение. Установщик при этом
# читал файл правильно (он подключает .env до применения), и получалось худшее
# из возможного: предпроверка порта шла по адресу из файла и говорила «годен»,
# а сервер поднимался на умолчании и не привязывался.
#
# Проверено поведением 06.09.2026: при .env с 192.168.88.8:5453 init давал
# 192.168.1.1:5453, установщик — 192.168.88.8:5453.
[ -f /opt/etc/qwdtt/meridian-dns.env ] && . /opt/etc/qwdtt/meridian-dns.env 2>/dev/null

# АДРЕС ПРОСЛУШИВАНИЯ — auto. Зашитое 192.168.1.1 было адресом роутера
# владельца: на сети клиента 192.168.88.0/24 bind не проходил и установщик
# откатывался. Выводит адрес САМ БИНАРЬ, из интерфейса $IFACES — одно
# вычисление на все двери, а не копия в каждом скрипте (см. lanaddr.go).
# Переопределение остаётся сильнее: MERIDIAN_DNS_LISTEN в .env или в окружении.
LISTEN="${MERIDIAN_DNS_LISTEN:-auto:5453}"
UPSTREAM="${MERIDIAN_DNS_UPSTREAM:-127.0.0.1:53}"

# IFACES — явное MERIDIAN_DNS_IFACES сильнее всего, как и раньше. Без него —
# СПИСОК МОСТОВ ДОМА ОТ ДВИЖКА (meridian-route home-ifaces, есть с 1.69/1.70),
# а не зашитый br0: гостевая br1 у владельца тоже в белом режиме, и заворот
# только по br0 оставлял бы её домены неработающими (21.09.2026, владелец).
#
# ЭТА ЖЕ ЛОГИКА ПРОДУБЛИРОВАНА в meridian-dns-netfilter-hook.sh — правило 51:
# чинится КЛАСС, не экземпляр, а разошедшаяся копия — тот же класс беды, что
# уже был с LISTEN здесь и в крючке (06.09.2026). Правя одно — правь оба.
#
# КОД 2 У home-ifaces («мостов не найдено, гадать нельзя») — это ОТКАЗ, не
# повод тихо взять br0: движок сказал прямо, что не узнал мосты, и подставлять
# умолчание значило бы гадать за него (владелец, 21.09.2026: «код 2 → стоп
# словами, не br0 по умолчанию»). Отсутствие самого meridian-route (например,
# сборка без движка маршрутизации) — ДРУГОЙ случай: тут br0 остаётся честным
# умолчанием, потому что зависимости на движок раньше не было вовсе.
if [ -n "${MERIDIAN_DNS_IFACES:-}" ]; then
	IFACES="$MERIDIAN_DNS_IFACES"
elif [ -x /opt/bin/meridian-route ]; then
	_HI_ERR="/opt/var/run/.meridian-dns-home-ifaces-err.$$"
	_HI_OUT=$(/opt/bin/meridian-route home-ifaces 2>"$_HI_ERR")
	_HI_RC=$?
	if [ "$_HI_RC" = 0 ] && [ -n "$_HI_OUT" ]; then
		IFACES=$(echo "$_HI_OUT" | tr '\n' ',' | sed 's/,$//')
	elif [ "$_HI_RC" = 2 ]; then
		echo "meridian-dns-init: ОТКАЗ — meridian-route home-ifaces: $(cat "$_HI_ERR" 2>/dev/null)" >&2
		rm -f "$_HI_ERR"
		exit 1
	else
		IFACES="br0"
	fi
	rm -f "$_HI_ERR"
else
	IFACES="br0"
fi
# SOURCES — режим обкатки: заворачивать только эти адреса. Пусто = вся сеть.
SOURCES="${MERIDIAN_DNS_SOURCES:-}"

ARGS="-iptables $IPT_BIN -chain $NATCHAIN -mark-chain $MARKCHAIN -listen $LISTEN -upstream $UPSTREAM -ifaces $IFACES -config $CONF"
ARGS="$ARGS -blocked-mark $BLOCKED -guard-pid $GUARDPID -log $LOG -listen-file $RUN/meridian-dns.listen"
[ -n "$SOURCES" ] && ARGS="$ARGS -s $SOURCES"

# IPTW — форма ключа ожидания замка xtables, выбранная ПРОБОЙ.
#
# 04.09.2026, роутер владельца: `status` звал iptables БЕЗ -w, и один вызов из
# пяти вернул код 4 («Another app is currently holding the xtables lock»). Код 4
# сворачивался в «перехода НЕТ», а сырой дамп двумя строками ниже показывал
# `-A PREROUTING -j MERIDIAN_DNS`. Показатель путал «не знаю» с «нет», и его
# показывает клиенту панель.
#
# Форма ПРОБУЕТСЯ, а не предполагается: на iptables 1.4.21 числа у -w нет вовсе
# (появилось в 1.4.22), и «-w 5» там ломает КАЖДЫЙ вызов (правило 42).
ipt_pick_wait() {
    if "$IPT_BIN" -w 5 -t nat -S >/dev/null 2>&1; then
        IPTW="-w 5"
        return 0
    fi
    if "$IPT_BIN" -w -t nat -S >/dev/null 2>&1; then
        IPTW="-w"
        return 0
    fi
    IPTW=""
}
IPTW=""
IPT_PICKED=0

# ipt — ЕДИНСТВЕННЫЙ способ звать iptables из этого скрипта. Прямые вызовы
# запрещены: ровно так и появился вызов без ожидания замка.
ipt() {
    if [ "$IPT_PICKED" = 0 ]; then
        ipt_pick_wait
        IPT_PICKED=1
    fi
    "$IPT_BIN" $IPTW "$@"
}

alive() {
    # По /proc/<pid>/cmdline с полным путём и с пропуском своего PID.
    # `ps | grep <имя> | kill` на роутере убивает и сам скрипт: в его
    # командной строке стоит то же имя (правило 25).
    _p=$(cat "$1" 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_p" = "$$" ] && return 1
    _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null) || return 1
    case "$_c" in *"$BIN"*) ;; *) return 1 ;; esac
    case "$2" in
        guard) case "$_c" in *" guard"*) return 0 ;; *) return 1 ;; esac ;;
        *)     case "$_c" in *" run"*)   return 0 ;; *) return 1 ;; esac ;;
    esac
}

start_server() {
    alive "$PIDFILE" run && { echo "сервер уже работает"; return 0; }
    [ -x "$BIN" ] || { echo "нет $BIN"; return 1; }
    # Конфиг заводит УСТАНОВЩИК (пустой, если своего нет). Здесь только отказ:
    # два места, создающих один файл, однажды создадут его по-разному.
    [ -f "$CONF" ] || { echo "нет $CONF — его создаёт установщик; список правил: $BIN import-list <файл> --group \"Обход\" --mode black"; return 1; }
    # Порт проверяем ДО запуска: причина известна за миллисекунду, а узнавать
    # её падением с bind: address already in use — значит потерять и время, и
    # внятное сообщение.
    if ! $BIN $ARGS checkport; then
        echo "не запускаю: см. строку выше"
        return 1
    fi
    mkdir -p "$RUN" "$(dirname "$LOG")" 2>/dev/null
    # stdout В ФАЙЛ, а не в /dev/null: путь к логу программа узнаёт из
    # /proc/self/fd/1, и без этого потолок лога не включится.
    $BIN $ARGS run >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    # ФАКТИЧЕСКИЙ адрес пишет САМ СЕРВЕР, а не мы.
    #
    # 07.09.2026: здесь стояло `echo "$LISTEN" > ...`, то есть в файл клалось
    # НАСТРОЕННОЕ значение. С 0.13 это «auto:5453» — просьба угадать вместо
    # ответа. Комментарий на этом месте обещал обратное, и обещание расходилось
    # с делом молча: у владельца файл достался от прежней версии с вписанным
    # адресом, и дефект прятался за старым состоянием. Проявился бы на ПЕРВОЙ
    # установке — то есть у клиента.
    #
    # Владелец у файла один: сервер знает, на чём он ДЕЙСТВИТЕЛЬНО открыл сокет,
    # а мы знаем только то, что ему велели. Два места, пишущих один файл,
    # разъезжаются молча.
    #
    # Здесь остаётся ОЖИДАНИЕ и ПРОВЕРКА ВИДА: установщик читает этот файл сразу
    # после нас, и гонка «ещё не записан» выглядела бы как «сервер не встал».
    LF="$RUN/meridian-dns.listen"
    _i=0
    _got=""
    while [ "$_i" -lt 15 ]; do
        _got=$(cat "$LF" 2>/dev/null)
        case "$_got" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*:[0-9]*) _i=15 ;;
            *) _got=""; sleep 1; _i=$((_i + 1)) ;;
        esac
    done
    if [ -n "$_got" ]; then
        echo "сервер запущен, pid $(cat "$PIDFILE"), слушает $_got"
    else
        # НЕ МОЛЧИМ. Пустой или негодный файл здесь означает, что дальше
        # установщик и приёмка будут проверять неизвестно что.
        echo "сервер запущен, pid $(cat "$PIDFILE"), НО фактический адрес в $LF не появился"
        echo "  в файле сейчас: «$(cat "$LF" 2>/dev/null)»"
        echo "  ждали 15 с; ожидался вид X.X.X.X:порт. Смотрите $LOG"
    fi
}

start_guard() {
    alive "$GUARDPID" guard && { echo "сторож уже работает"; return 0; }
    mkdir -p "$RUN" 2>/dev/null
    $BIN $ARGS guard >> "$LOG" 2>&1 &
    # pid-файл пишет сама программа: наш $! может отличаться, если оболочка
    # решит форкнуться, и тогда «сторож жив» проверялось бы по чужому числу.
    sleep 1
    echo "сторож запущен, pid $(cat "$GUARDPID" 2>/dev/null)"
}

cron_install() {
    mkdir -p "$(dirname "$CRONFILE")" 2>/dev/null
    [ -f "$CRONFILE" ] || : > "$CRONFILE"
    grep -qF "$CRONMARK" "$CRONFILE" 2>/dev/null && return 0
    # Дописываем в конец, файл целиком не переписываем: в нём чужие строки.
    echo "* * * * * $BIN $ARGS ensure >/dev/null 2>&1 # $CRONMARK" >> "$CRONFILE"
    cron_ensure_daemon
    echo "периодика поставлена"
}

# crond_serving — есть ли ЖИВОЙ crond, который читает наш каталог.
#
# Смотрим в /proc, а не в `ps | grep`: в BusyBox `ps` показывает все процессы,
# включая наш собственный конвейер с этим же словом в командной строке
# (правило 25), и себя мы бы нашли всегда.
#
# Совпадением считаем ДВА случая: явный `-c <наш каталог>` и crond без -c,
# когда каталог по умолчанию и есть наш. Второй случай не теоретический:
# на Entware S10cron поднимает crond именно так.
crond_serving() {
    _dir=$1
    # stderr всего цикла в /dev/null: процесс может умереть между разворотом
    # /proc/* и чтением cmdline, и BusyBox ash печатает жалобу на неудачное
    # ПЕРЕНАПРАВЛЕНИЕ мимо `2>/dev/null`, стоящего на самой команде.
    # Замечено стендом: строки «can't open /proc/NNN/cmdline» лезли в вывод.
    { for _p in /proc/[0-9]*; do
        _pid=${_p#/proc/}
        _cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
        case "$_cmd" in
            *crond*) ;;
            *) continue ;;
        esac
        case "$_cmd" in
            *"-c $_dir "*|*"-c $_dir")
                echo "$_pid"
                return 0
                ;;
        esac
        case "$_cmd" in
            *" -c "*) continue ;;
        esac
        # crond без -c: сверяем каталог по умолчанию. Он у BusyBox вкомпилен и
        # снаружи не виден, поэтому спрашиваем сам crond его же справкой.
        if [ "$_dir" = "$(crond_default_dir)" ]; then
            echo "$_pid"
            return 0
        fi
    done; } 2>/dev/null
    return 1
}

# crond_default_dir — каталог crontab по умолчанию у ЭТОЙ сборки crond.
# Спрашиваем справкой, а не подставляем «обычно /opt/etc/crontabs»: сборок
# несколько, и догадка тут ничем не лучше отсутствия проверки.
crond_default_dir() {
    _d=$("$CROND" --help 2>&1 | sed -n 's/.*-c DIR[^/]*\(\/[^ ]*\).*/\1/p' | head -n 1)
    if [ -n "$_d" ]; then
        echo "$_d"
        return 0
    fi
    echo "/opt/etc/crontabs"
}

# cron_ensure_daemon — поднять crond, ЕСЛИ его нет.
#
# Было: `S10cron restart || crond -c ...`. Каждый `start` init-скрипта плодил
# ещё один crond, и на роутере владельца их набралось несколько. Цена не
# теоретическая: на 248 МБ ОЗУ лишние демоны сначала едят память, а потом наш
# `ensure` запускается по разу от КАЖДОГО из них — раз в минуту умножить на
# число копий (правило 8).
#
# Перезапускать живой crond НЕ НАДО вовсе: BusyBox crond сам перечитывает
# crontab, когда у файла изменилось время правки. Именно поэтому здесь нет
# ветки «нашёлся — перезапустим»: она была бы лишним риском без выигрыша.
cron_ensure_daemon() {
    _dir=$(dirname "$CRONFILE")
    _have=$(crond_serving "$_dir")
    if [ -n "$_have" ]; then
        echo "  crond уже работает (pid $_have), новый не запускаю"
        return 0
    fi
    if [ -x "$CRONINIT" ]; then
        "$CRONINIT" start >/dev/null 2>&1
        _i=0
        while [ $_i -lt 3 ]; do
            _have=$(crond_serving "$_dir")
            if [ -n "$_have" ]; then
                echo "  crond поднят через S10cron (pid $_have)"
                return 0
            fi
            sleep 1
            _i=$((_i+1))
        done
    fi
    if ! command -v "$CROND" >/dev/null 2>&1; then
        echo "  ВНИМАНИЕ: crond не найден — периодика НЕ РАБОТАЕТ"
        return 1
    fi
    "$CROND" -c "$_dir" -b >/dev/null 2>&1
    _i=0
    while [ $_i -lt 3 ]; do
        _have=$(crond_serving "$_dir")
        if [ -n "$_have" ]; then
            echo "  crond поднят (pid $_have)"
            return 0
        fi
        sleep 1
        _i=$((_i+1))
    done
    # Отказ называется вслух: молча оставленная без демона строка в crontab
    # выглядит как работающая периодика, а её нет.
    echo "  ВНИМАНИЕ: crond не поднялся — периодика НЕ РАБОТАЕТ, строка в $CRONFILE лежит впустую"
    return 1
}

cron_remove() {
    [ -f "$CRONFILE" ] || return 0
    # Без `&&`: если в файле была ТОЛЬКО наша строка, grep -v ничего не выводит
    # и возвращает 1 — при `&&` mv не выполнялся бы, строка оставалась, а
    # «снята» печаталось. Поймано собственным прогоном; это ровно правило 37:
    # успех печатался по коду возврата, а не по тому, что легло в файл.
    grep -vF "$CRONMARK" "$CRONFILE" > "$CRONFILE.tmp" 2>/dev/null
    mv -f "$CRONFILE.tmp" "$CRONFILE" 2>/dev/null
    # СВЕРКА СОДЕРЖИМЫМ, а не кодом возврата.
    if grep -qF "$CRONMARK" "$CRONFILE" 2>/dev/null; then
        echo "ОТКАЗ: строка периодики осталась в $CRONFILE — уберите вручную:"
        echo "    grep -vF '$CRONMARK' $CRONFILE > $CRONFILE.fix && mv -f $CRONFILE.fix $CRONFILE"
        return 1
    fi
    echo "периодика снята"
}

# rb_human — читаемая дата отката рядом с меткой Unix.
#
# Голая метка 1788542172 человеку не говорит ничего, а показатель существует
# ровно для человека. Метку оставляем: по ней сравнивают и сортируют.
#
# Способ перевода ВЫБИРАЕТСЯ ПРОБОЙ, а не предполагается: `date -d @N` есть в
# GNU и в части сборок BusyBox, `date -D %s -d N` — busybox-специфичный, и обе
# формы на этом роутере могут отсутствовать (правило 25). Не вышло ни одной —
# так и говорим, а не печатаем пустоту, которую примут за дату.
rb_human() {
    _t=$(sed -n 's/^at=//p' "$ROLLBACKMARK" 2>/dev/null | head -1)
    # Установщик с 0.3 кладёт дату сам — если она есть, она вернее любого
    # перевода задним числом: часовой пояс мог смениться.
    _w=$(sed -n 's/^at_human=//p' "$ROLLBACKMARK" 2>/dev/null | head -1)
    if [ -n "$_w" ]; then
        echo "$_w"
        return 0
    fi
    case "$_t" in ''|*[!0-9]*) echo "метка нечисловая"; return 0 ;; esac
    _h=$(date -d "@$_t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)   # bb-ok: результат проверяется, есть запасные пути
    if [ -n "$_h" ]; then
        echo "$_h"
        return 0
    fi
    _h=$(date -D %s -d "$_t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)   # bb-ok: то же
    if [ -n "$_h" ]; then
        echo "$_h"
        return 0
    fi
    echo "date этой сборки метку не переводит"
}

# jump_state — есть ли переход из PREROUTING. ТРИ исхода, а не два.
#
# `iptables -C` возвращает 0 — правило есть, 1 — правила нет, и ИНОЕ — спросить
# не смогли (4 при занятом замке xtables). Сворачивать третье во второе значит
# показывать клиенту «обход не работает» там, где мы просто не сумели
# посмотреть. Это тот же дефект, что был у `ForeignDivert` в программе, и та же
# цена: человек чинит несуществующее.
jump_state() {
    _tab=$1
    _ch=$2
    ipt -t "$_tab" -C PREROUTING -j "$_ch" >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" = 0 ]; then
        echo "  переход из PREROUTING: есть"
        return 0
    fi
    if [ "$_rc" = 1 ]; then
        echo "  переход из PREROUTING: НЕТ (цепочка есть, но в неё не заходят)"
        return 0
    fi
    echo "  переход из PREROUTING: НЕ СМОГ ПРОВЕРИТЬ (iptables код $_rc, обычно занят замок xtables)"
    echo "    это НЕ «перехода нет». Повторите через несколько секунд."
}

stop_one() {
    _p=$(cat "$1" 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) return 0 ;; esac
    kill "$_p" 2>/dev/null
    # ЦЕЛЫЕ секунды: BusyBox дробных не понимает. Было `sleep 0.1` — на роутере
    # это давало семь строк «sleep: invalid number '0.1'» на каждую остановку,
    # а цикл крутился вхолостую на полной скорости процессора, то есть ждать
    # он не ждал вовсе. Отказ тихий: снаружи выглядит как «остановилось сразу».
    #
    # Потолок 5 секунд: сервер при выходе снимает заворот за 4 мс и закрывает
    # сокеты за 8 мс (измерено), так что пяти хватает с большим запасом.
    _i=0
    while [ $_i -lt 5 ] && kill -0 "$_p" 2>/dev/null; do sleep 1; _i=$((_i+1)); done
    kill -0 "$_p" 2>/dev/null && kill -9 "$_p" 2>/dev/null
    rm -f "$1"
}

# stop_all_guards — гасит ВСЕХ сторожей, а не только записанного в pid-файле.
#
# 22.09.2026, живой случай HERO: у сторожа было ДВА независимых пути запуска
# (init.sh — прямым `$BIN $ARGS guard &`, periodika — своим кодом сборки
# ключей), они однажды разошлись ключами, и в pid-файле в итоге оказался ОДИН
# из двух живых сторожей — stop_one по нему убивал ТОЛЬКО его, второй
# оставался сиротой и продолжал оживлять сервер уже ПОСЛЕ намеренной
# остановки. Сборку ключей унифицировали (startGuard теперь читает записанный
# argv, а не собирает заново), но stop обязан быть НАДЁЖНЫМ и без этого
# предположения: находим по /proc — свой исполняемый файл И последнее слово
# argv `guard` — а не верим единственному числу в файле.
stop_all_guards() {
    for p in "$PROC_ROOT"/[0-9]*; do
        _pid=${p#"$PROC_ROOT"/}
        _ex=$(readlink "$p/exe" 2>/dev/null) || continue
        case "$_ex" in
            "$BIN"|"$BIN (deleted)") ;;
            *) continue ;;
        esac
        _cmd=$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | tail -1)
        [ "$_cmd" = "guard" ] || continue
        kill "$_pid" 2>/dev/null
        _i=0
        while [ $_i -lt 5 ] && kill -0 "$_pid" 2>/dev/null; do sleep 1; _i=$((_i+1)); done
        kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
    done
    rm -f "$GUARDPID"
}

# proc_meridian_dns_count — сколько НАШИХ процессов (run+guard, любых) живо
# прямо сейчас. Используется stop-ом для проверки «0 процессов», а не только
# для веры в то, что kill каждого отдельного pid прошёл успешно.
proc_meridian_dns_count() {
    _n=0
    for p in "$PROC_ROOT"/[0-9]*; do
        _ex=$(readlink "$p/exe" 2>/dev/null) || continue
        case "$_ex" in
            "$BIN"|"$BIN (deleted)") _n=$((_n+1)) ;;
        esac
    done
    echo "$_n"
}

case "${1:-}" in
    start)
        cron_install
        start_server
        start_guard
        ;;
    stop)
        # Периодика ПЕРВОЙ: иначе она поднимет то, что мы сейчас останавливаем.
        cron_remove
        # ВСЕХ сторожей, не только записанного в pid-файле — см. комментарий
        # у stop_all_guards (живой случай HERO 22.09.2026: сирота в pid-файле
        # не значился, а был жив).
        stop_all_guards
        stop_one "$PIDFILE"
        rm -f "$RUN/meridian-dns.listen"
        # ARGV СНИМАЕТСЯ ЗДЕСЬ, И ЭТО ЧАСТЬ ЗАМЫСЛА, А НЕ УБОРКА.
        #
        # С 0.12 периодика поднимает исчезнувший сервер сама — теми ключами,
        # которые он записал в этот файл при старте. Пока файл есть, «процесса
        # нет» читается как «упал». Нет файла — читается как «остановлен
        # человеком», и никто его не поднимает. Иначе крючок ndm воскресил бы
        # сервер через минуту после того, как его намеренно остановили.
        #
        # Счётчики попыток снимаем тем же движением: серия закончилась.
        rm -f "$PIDFILE.argv" "$PIDFILE.argv.warned"
        rm -f "$GUARDPID.argv"
        rm -f "$PIDFILE.tries" "$PIDFILE.tries.warned"
        rm -f "$GUARDPID.tries" "$GUARDPID.tries.warned"
        # Заворот снимает сама программа при выходе. Но если она не успела —
        # снимаем явно: оставленный заворот означает дом без DNS.
        $BIN $ARGS off >/dev/null 2>&1
        rm -f "$BLOCKED"
        # ПРОВЕРКА ДЕЛОМ, не верой в то, что каждый kill выше прошёл: живой
        # случай HERO 22.09.2026 — «остановлено» печаталось, пока сирота
        # продолжал работать. Считаем НАШИ процессы по /proc заново.
        _ostalos=$(proc_meridian_dns_count)
        if [ "$_ostalos" = 0 ]; then
            echo "остановлено, заворот снят (процессов не осталось)"
        else
            echo "ОТКАЗ: после остановки живых процессов meridian-dns: $_ostalos (ждали 0) — смотрите руками"
        fi
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    status)
        alive "$PIDFILE" run   && echo "сервер: работает (pid $(cat "$PIDFILE"))" || echo "сервер: НЕ работает"
        alive "$GUARDPID" guard && echo "сторож: работает (pid $(cat "$GUARDPID"))" || echo "сторож: НЕ работает"
        grep -qF "$CRONMARK" "$CRONFILE" 2>/dev/null && echo "периодика: стоит" || echo "периодика: НЕТ"
        [ -f "$BLOCKED" ] && echo "заворот: СНЯТ СТОРОЖЕМ ($(cat "$BLOCKED"))" || echo "заворот: сторож не вмешивался"
        # Крючок ndm — отдельной строкой: без него окно после пересборки
        # netfilter не секунды, а до минуты, и разница обязана быть видна.
        if [ -x /opt/etc/ndm/netfilter.d/50-meridian-dns.sh ]; then
            echo "крючок ndm: стоит (окно после пересборки netfilter — секунды)"
        elif [ -d /opt/etc/ndm/netfilter.d ]; then
            echo "крючок ndm: НЕТ (окно после пересборки netfilter — до минуты, чинит только периодика)"
        else
            echo "крючок ndm: каталога /opt/etc/ndm/netfilter.d нет — прошивка крючки не зовёт"
        fi
    # ТРИ явных исхода, ни один не пустой — тот же договор, что last_rollback у
    # движка. «Файл есть, но нечитаем» НЕ сворачивается в «откатов не было»:
    # это поломка, и выдавать её за благополучие значит терять ровно то
    # событие, ради которого след заведён.
    if [ ! -f "$ROLLBACKMARK" ]; then
        echo "last_rollback=none"
    elif [ -n "$(sed -n 's/^at=//p' "$ROLLBACKMARK" 2>/dev/null | head -1)" ]; then
        # ДВА КЛЮЧА, а не дата в скобках: значение ключа читает программа,
        # и приписка сломала бы разбор. Одно значение — один смысл.
        echo "last_rollback=$(sed -n 's/^at=//p' "$ROLLBACKMARK" | head -1)"
        echo "last_rollback_human=$(rb_human)"
        echo "last_rollback_reason=$(sed -n 's/^reason=//p' "$ROLLBACKMARK" | head -1)"
        echo "last_rollback_effect=$(sed -n 's/^effect=//p' "$ROLLBACKMARK" | head -1)"
        echo "last_rollback_note=$(sed -n 's/^note=//p' "$ROLLBACKMARK" | head -1)"
    else
        echo "last_rollback=unknown"
    fi
        # ЧИТАЕМ САМИ ЦЕПОЧКИ, а не спрашиваем «есть ли переход».
        #
        # 04.09.2026 здесь стояла одна строка «правило: стоит/нет», и она
        # проверяла ТОЛЬКО заворот в nat, ничего об этом не говоря. Владелец
        # сравнил её с цепочкой пометки в mangle, где прошло 1586 пакетов, и
        # по строке решил, что обход не работает. Показатель, который не
        # называет, что именно он показывает, хуже отсутствующего.
        #
        # Теперь обе цепочки названы поимённо и с числами: число пакетов
        # отличает «правило стоит» от «правило стоит и РАБОТАЕТ» — а это разные
        # вещи, и вторая и есть то, что человек хочет знать.
        _nat=$(ipt -t nat -L "$NATCHAIN" -v -n -x 2>/dev/null)
        if [ -z "$_nat" ]; then
            echo "заворот DNS (nat $NATCHAIN): цепочки НЕТ"
        else
            echo "заворот DNS (nat $NATCHAIN): правил $(echo "$_nat" | grep -c 'DNAT'), пакетов $(echo "$_nat" | awk '/DNAT/{s+=$1} END{print s+0}')"
            jump_state nat "$NATCHAIN"
        fi
        _mark=$(ipt -t mangle -L "$MARKCHAIN" -v -n -x 2>/dev/null)
        if [ -z "$_mark" ]; then
            echo "пометка (mangle $MARKCHAIN): цепочки НЕТ — трафик доменов пойдёт МИМО туннеля"
        else
            echo "пометка (mangle $MARKCHAIN): наборов $(echo "$_mark" | grep -c 'match-set'), помечено пакетов $(echo "$_mark" | awk '/match-set/{s+=$1} END{print s+0}')"
            jump_state mangle "$MARKCHAIN"
        fi
        ;;
    rollback-ack)
        # Снять след может ТОЛЬКО человек: откат означает, что версия не
        # поднялась, и стирать улику при следующей установке значило бы
        # прятать повторяющийся отказ.
        if [ ! -f "$ROLLBACKMARK" ]; then
            echo "следа автоотката нет — снимать нечего"
        else
            # Дату берём ДО удаления файла: rb_human читает его.
            WAS=$(rb_human)
            rm -f "$ROLLBACKMARK"
            echo "След автоотката снят (был от $WAS)."
        fi
        ;;
    *)
        echo "usage: $0 start|stop|restart|status|rollback-ack"
        exit 2
        ;;
esac
