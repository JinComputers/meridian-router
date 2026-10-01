#!/bin/sh
# ustanovka-dns.sh — ОДИН исполнитель установки meridian-dns вместе с ipset.
#
# Вызывающих трое, и они не должны заводить свои копии этой логики:
#   1) блок переезда парка (панель + DNS одним заходом);
#   2) установщик нового клиента;
#   3) цель dns в /api/update (сделаем следом).
# Три копии разъедутся молча: починим ipset в одной двери, а в двух соседних
# он останется сломан. Мы этот класс за два дня встречали трижды.
#
# КОДЫ ВОЗВРАТА — это интерфейс, вызывающие судят по ним:
#   0  установлено и ПЕРЕЖИЛО ПЕРЕЗАПУСК
#   1  отказ, откат сделан, причина напечатана
#   2  проверка не выполнена (не узнали; не «хорошо» и не «плохо»)
#
# Ничего не перезапускает, кроме самого сервера DNS. Клиента и туннель не
# трогает: замерено 07.09.2026, что qwdtt-ctl restart идёт в apply(), а apply
# перезапускает клиента — поэтому qwdtt-ctl здесь не зовётся ни разу.

# QWDTT_CHANNEL — тот же принцип и то же имя, что у install.sh (владелец,
# 22.09.2026, ЖИВОЙ СЛУЧАЙ: тестировщик 2 ставил бету, install.sh знал
# QWDTT_CHANNEL=beta, но этот файл его не получал вовсе — BASE был жёстко
# зашит на /bin, и шаг DNS беты молча ставил ПРОД (meridian-dns 0.16 вместо
# 0.35 из беты). Тот же класс дыры, что был у тестировщика 1 в install.sh.
#
# НЕ ЗАДАН вовсе — безопасное умолчание bin (install.sh делает то же самое,
# `${QWDTT_CHANNEL:-bin}`), это НЕ бага: файл вызывают трое (см. шапку), и
# прямой вызов без install.sh — законный путь к боевой раздаче.
#
# ЗАДАН, НО ПУСТ — это СИМПТОМ потерянного канала, не умолчание: кто-то
# явно передал переменную и передал её пустой. Отказ, а не тихий прод —
# ровно то, что случилось у тестировщика 2. Различить «не задан» и «задан
# пустым» приёмом ${VAR+SET} (POSIX): пустая строка — SET, отсутствие — нет.
if [ -z "${QWDTT_CHANNEL+SET}" ]; then
  QWDTT_CHANNEL=bin
elif [ -z "$QWDTT_CHANNEL" ]; then
  echo "[meridian-dns] ОТКАЗ: QWDTT_CHANNEL задан ПУСТЫМ — канал потерялся по дороге, это не настоящее умолчание. Останавливаюсь, не тяну боевое вместо ожидаемого канала." >&2
  exit 1
fi
case "$QWDTT_CHANNEL" in
  bin|beta) ;;
  *) echo "[meridian-dns] ОТКАЗ: QWDTT_CHANNEL='$QWDTT_CHANNEL' неизвестен. Можно: bin, beta" >&2; exit 1 ;;
esac
# local_ipv4/same_net16/BASE_LIST — ТЕМ ЖЕ приёмом, что build_base_urls() в
# install.sh (22.09.2026, живой случай): у владельца провайдер режет НОВЫЕ
# соединения к внешнему 138.124.78.252, а внутренний шлюз (10.77.77.1) идёт
# через уже поднятый туннель и не режется. У тестировщика с тем же классом
# провайдера установка DNS падала бы на внешнем адресе, хотя внутренний был
# бы жив. Внутренний источник пробуется ПЕРВЫМ, но только если сам роутер
# действительно в его /16 (same_net16) — иначе это была бы боевая раздача
# для домашнего роутера, которому 10.77.77.1 не сосед.
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
# BASE — ПЕРВЫЙ элемент списка, для мест, что ещё читают одиночную переменную
# (манифест печати и т.п.); сами закачки идут по ВСЕМУ BASE_LIST.
BASE=$(echo "$BASE_LIST" | awk '{print $1}')
SUF=""
IPSUF=""
T="/tmp/qwdtt-dns-ust"
CLIENT="/opt/bin/qwdtt"
DNSBIN="/opt/bin/meridian-dns"
DNS_INIT="/opt/etc/init.d/S81meridian-dns"
RUNDIR_DNS="/opt/var/run"  # тот же RUN, что в meridian-dns-init.sh
DNS_CONF="/opt/etc/qwdtt/meridian-dns.yaml"
BAKDIR="/opt/var/backup/qwdtt"
CFGBAK="$BAKDIR/meridian-dns.yaml.was"

# ---------- ДВИЖОК МАРШРУТИЗАЦИИ — МИНИМАЛЬНАЯ ВЕРСИЯ ----------
# Тот же уговор и тот же порог, что в meridian-dns-install.sh (правь оба —
# копия логики, не общий файл, тем же классом беды, что уже был с LISTEN,
# 06.09.2026): meridian-dns-init.sh на каждом старте зовёт
# `meridian-route home-ifaces`, команда есть с движка 1.69. Живой случай
# 23.09.2026 — тестировщик 1 застрял на 1.38 (утечка с прода), установка
# 0.36 падала уже ПОСЛЕ остановки текущего DNS. Проверяем ДО любых действий,
# текущий DNS не трогаем, если движка не хватает.
MERIDIAN_ROUTE_BIN=/opt/bin/meridian-route
MERIDIAN_ROUTE_MIN_MAJOR=1
MERIDIAN_ROUTE_MIN_MINOR=69
if [ -x "$MERIDIAN_ROUTE_BIN" ]; then
	_mr_ver=$("$MERIDIAN_ROUTE_BIN" version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
	if [ -n "$_mr_ver" ]; then
		_mr_major=${_mr_ver%.*}
		_mr_minor=${_mr_ver#*.}
		case "$_mr_major" in ''|*[!0-9]*) _mr_major=0 ;; esac
		case "$_mr_minor" in ''|*[!0-9]*) _mr_minor=0 ;; esac
		if [ "$_mr_major" -lt "$MERIDIAN_ROUTE_MIN_MAJOR" ] || \
		   { [ "$_mr_major" -eq "$MERIDIAN_ROUTE_MIN_MAJOR" ] && [ "$_mr_minor" -lt "$MERIDIAN_ROUTE_MIN_MINOR" ]; }; then
			echo "[meridian-dns] ОТКАЗ: движок $_mr_ver слишком старый, нужен ≥$MERIDIAN_ROUTE_MIN_MAJOR.$MERIDIAN_ROUTE_MIN_MINOR — поставь полный набор беты: curl -sf $BASE/../install.sh -o /tmp/install.sh && sh /tmp/install.sh (текущий DNS не трогал)" >&2
			exit 1
		fi
	else
		echo "[meridian-dns] не разобрал версию $MERIDIAN_ROUTE_BIN — проверку версии движка пропускаю, не отказываю вслепую" >&2
	fi
fi

# СУММЫ БОЛЬШЕ НЕ ЗАШИТЫ ЗДЕСЬ (правка 19.09.2026, разбор класса дефекта).
#
# До этой правки DSUM/DSZ на архитектуру и INST_SUM/INIT_SUM/HOOK_SUM лежали
# текстом прямо в скрипте — третьей копией того же факта, что уже есть в
# SHA256SUMS (первая копия — сам файл в раздаче, вторая — строка манифеста).
# Бинари meridian-dns пересобрали 16.09, SHA256SUMS обновили, а эти строки —
# нет: неделю НИ ОДИН установщик не мог поставить DNS ни на одной архитектуре,
# хотя всё нужное давно лежало в раздаче исправным. Три копии одного факта не
# могут не разъехаться (правило 51); чинится не число, а количество копий.
#
# Теперь ОДИН источник истины — SHA256SUMS, тот же манифест, которым уже
# сверяются клиент и панель. Скрипт качает его свежим при каждом запуске
# (manifest_fetch) и ищет по имени файла (manifest_sha) — значит, кто бы и как
# ни пересобрал meridian-dns дальше, эта проверка правится САМА, если верна
# запись в SHA256SUMS. Размер отдельно не храним: правильная сумма уже
# гарантирует правильный размер, а хранить оба — снова та самая вторая копия.
SUMSNEW=""   # путь к скачанному SHA256SUMS, заполняет manifest_fetch

say() { echo "[dns] $*"; }

# QWDTT_DNS_SOURCE_ONLY — тот же приём, что QWDTT_INSTALL_SOURCE_ONLY в
# install.sh (22.09.2026): печатает, откуда возьмёт файлы, и выходит, ничего
# не трогая на роутере. Нужен ИМЕННО для этого файла отдельно от install.sh:
# исторический дефект («канал не дошёл до шага DNS») жил ровно в BASE этого
# скрипта, а install.sh о нём знать не мог — свои источники печатает верно, а
# то, что дальше зовёт этот файл, уже могло потерять канал по дороге.
if [ -n "${QWDTT_DNS_SOURCE_ONLY:-}" ]; then
  say "канал: $QWDTT_CHANNEL"
  say "источник DNS: $BASE"
  say "источники DNS (по порядку, первый успешный побеждает): $BASE_LIST"
  exit 0
fi

# manifest_fetch — скачать SHA256SUMS тем же загрузчиком, что и остальные
# файлы (skachat объявлена ниже по файлу, вызывается уже после неё по факту
# исполнения — в POSIX-шелле это нормально: важен порядок ВЫЗОВОВ, не
# определений). Без манифеста сверять нечем — отказ, а не «пропустим сверку».
manifest_fetch() {
  SUMSNEW="$T/SHA256SUMS"
  if ! skachat_baza "SHA256SUMS$SUF" "$SUMSNEW"; then
    say "ОТКАЗ: не скачать манифест сумм (SHA256SUMS) — без него нечем сверить"
    say "сервер DNS с тем, что реально лежит в раздаче. Ничего не тронуто."
    return 1
  fi
  return 0
}

# manifest_sha <имя-файла-как-в-раздаче> — сумма из СВЕЖЕ СКАЧАННОГО манифеста.
# Пусто — значит манифест об этом файле не знает; вызывающий обязан считать
# это отказом, а не «сумму просто не проверяем» (правило 39 — пустой эталон
# не значит «всё в порядке», значит «мы ничего не увидели»).
manifest_sha() {
  awk -v n="$1" '$2 == n {print $1}' "$SUMSNEW" | head -1
}

# ЧЕЛОВЕЧЕСКИЙ РАЗМЕР. Не для красоты: «7969152» и «7,6 МБ» — это разное знание,
# а решать по нему человеку, который не считает в байтах.
razmer() {
  _b="${1:-0}"
  if [ "$_b" -ge 1048576 ]; then echo "$((_b / 1048576)),$(( (_b % 1048576) * 10 / 1048576 )) МБ"
  elif [ "$_b" -ge 1024 ]; then echo "$((_b / 1024)) КБ"
  else echo "$_b Б"; fi
}

# ЧТО МОЖНО СНЯТЬ. Печатает СВОЙ мусор с НАСТОЯЩИМИ размерами этого роутера и с
# пометкой, восстановимо оно или нет. Ничего не удаляет: показал, назвал,
# решает человек.
#
# Почему отдельной функцией и здесь, а не в блоке: дверей две — отказ по месту
# бывает и у установки DNS, и у переноса панели, — а список должен быть один
# (правило 51). Блок зовёт эту же функцию: `sh ustanovka-dns.sh --chto-snyat`.
#
# Восстановимость решается ЧТЕНИЕМ ФАЙЛА, а не его именем. Имя для такого
# решения не годится: и конфиг meridian-dns.yaml.was, и бинарь qwdtt-web.was
# кончаются одинаково на .was.
#
# opoznat — ЧТО ЭТО ЗА ФАЙЛ. Исходов ЧЕТЫРЕ, и «не знаю» среди них — полноценный:
#   nash-bin     наш собранный бинарь (ELF)
#   nash-skript  наш скрипт (шебанг И наше имя внутри)
#   vash-config  ваши настройки — УЗНАННЫЕ, а не «всё остальное»
#   ne-znayu     не опознали
#
# Исход «не знаю» заведён 08.09.2026 по замечанию владельца. До него всё, что не
# ELF, подписывалось «ваши настройки» — и под эту подпись попадали НАШИ же
# S99qwdtt, S98qwdtt-web, qwdtt-ctl, qwdtt-probe.sh, meridian-dns-init.prev.
# Направление было безопасное (не снимать), но ПРИЧИНА названа чужая, а это тот
# самый дефект: показатель, называющий причину вместо факта, врёт дважды
# (правило 47). Безопасное направление не оправдывает неверную подпись.
#
# Умолчание всё равно безопасное: не узнали — «не снимайте» и в счёт
# освобождаемого не берём. Ошибка в эту сторону стоит мегабайта, ошибка в
# другую — стоит человеку его списка доменов, которого больше нигде нет.
opoznat() {
  if head -c 4 "$1" 2>/dev/null | grep -q 'ELF'; then echo nash-bin; return; fi
  if [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ]; then
    if grep -qE 'qwdtt|meridian' "$1" 2>/dev/null; then echo nash-skript; return; fi
    echo ne-znayu; return
  fi
  # Конфиг УЗНАЁМ, а не предполагаем: либо наши ключи YAML, либо строки вида
  # КЛЮЧ=значение. Не узнали — так и говорим, а не подписываем чужим именем.
  if grep -qE '^[[:space:]]*(groups|rules):' "$1" 2>/dev/null; then echo vash-config; return; fi
  if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null; then echo vash-config; return; fi
  echo ne-znayu
}

chto_snyat() {
  say ""
  say "═══ ЧТО МОЖНО СНЯТЬ НА ЭТОМ РОУТЕРЕ (я ничего не удаляю сам) ═══"
  _svob=$(df -Pk /opt 2>/dev/null | awk 'NR==2{print $4}')   # bb-ok: не число — строкой ниже пробуем df -k, а не верим
  case "$_svob" in ''|*[!0-9]*) _svob=$(df -k /opt 2>/dev/null | awk 'NR==2{print $4}') ;; esac
  case "$_svob" in
    ''|*[!0-9]*) say "свободно сейчас: df ответил непонятным, число не назову" ;;
    *) say "свободно сейчас: $(razmer $((_svob * 1024)))" ;;
  esac
  _mozhno=0; _nashlos=0
  for _f in "$BAKDIR"/* /opt/var/log/*.updater /opt/var/log/*.prev /opt/var/log/*.1; do
    [ -f "$_f" ] || continue
    _nashlos=$((_nashlos + 1))
    _sz=$(wc -c 2>/dev/null < "$_f"); _sz=${_sz:-0}
    case "$_f" in
      /opt/var/log/*) _vid=nash-log ;;
      *) _vid=$(opoznat "$_f") ;;
    esac
    say "  $_f"
    case "$_vid" in
      nash-bin)
        _mozhno=$((_mozhno + _sz))
        say "      $(razmer "$_sz")  — МОЖНО СНЯТЬ: это копия нашей программы,"
        say "      она скачивается заново с раздачи за полминуты." ;;
      nash-skript)
        _mozhno=$((_mozhno + _sz))
        say "      $(razmer "$_sz")  — МОЖНО СНЯТЬ: это копия нашего скрипта,"
        say "      он есть в раздаче и приезжает заново вместе с обновлением." ;;
      nash-log)
        _mozhno=$((_mozhno + _sz))
        say "      $(razmer "$_sz")  — МОЖНО СНЯТЬ: это старый журнал." ;;
      vash-config)
        say "      $(razmer "$_sz")  — НЕ СНИМАТЬ: это ваши настройки (список"
        say "      доменов, конфиг). Заново взять их НЕОТКУДА." ;;
      *)
        say "      $(razmer "$_sz")  — НЕ СНИМАТЬ: я не понял, что это за файл."
        say "      Может быть и наше, и ваше. В счёт освобождаемого не беру." ;;
    esac
  done
  if [ "$_nashlos" = 0 ]; then
    # Пустой список — это не «снимать нечего, всё в порядке», это «нашего мусора
    # нет, и место заняло что-то ЧУЖОЕ» (правило 39). Так и говорим.
    say "  Нашего мусора не нашлось вовсе — ни копий, ни старых журналов."
    say "  Значит место занято не нами. Посмотреть, чем именно:"
    say "      du -sk /opt/* 2>/dev/null | sort -n | tail -15"
    say "  Чужое (lighttpd, php8, nfqws2, /opt/tmp/opkg-*) мы не трогаем."
  else
    say ""
    say "  Итого можно освободить: $(razmer "$_mozhno")"
    say "  Снять — по одному, своей рукой, например:"
    say "      rm -f <путь из списка выше>"
    say "  Строки с пометкой НЕ СНИМАТЬ не трогайте."
  fi
  say "═══════════════════════════════════════════════════════════════"
}

# Отдельный вход для вызывающих: блок зовёт его при СВОЁМ отказе по месту, чтобы
# список был один и тот же, а не два разошедшихся.
if [ "${1:-}" = "--chto-snyat" ]; then
  chto_snyat
  exit 0
fi

# ОДНО ОПОЗНАНИЕ АРХА НА ВСЕХ. Вызывается и отсюда, и снаружи: `--arch`
# печатает строку АРХ=<имя> и выходит. Второго разбора ELF в блоках заводить
# нельзя — он разъедется с этим (правило 51), а блок обкатки панели 6.24 уже
# успел завестись со своим и был бы неверен (см. ниже про uname).
#
# ЧИТАЕМ ELF, А НЕ uname. Замерено 08.09.2026 под qemu на программе, собранной
# под обе арки MIPS:
#     mipsle -> uname -m = "mips"
#     mips   -> uname -m = "mips"
# То есть uname НЕ РАЗЛИЧАЕТ порядок байт: UTS_MACHINE в ядре один на BE и LE.
# Прежняя запасная ветка `mipsel) ARCH=mipsle` была мертва (такого ответа нет
# никогда), а ветка `mips) ARCH=mips` — хуже, чем мертва: на little-endian
# роутере она молча выбирала big-endian набор.
#
# Порядок источников: наш клиент, наша панель, busybox, /bin/sh — первый
# читаемый ELF решает. Хоть один из них есть на любом роутере.
# Значения ставит ПРЯМО В ARCH и ARCH_ISTOCHNIK, а не печатает: вызов через
# $( ) создаёт подоболочку, и всё, что там присвоено, наружу не возвращается.
# На этом уже спотыкались — источник опознания печатался пустым.
opoznat_arch() {
  _a=""; ARCH=""; ARCH_ISTOCHNIK=""
  for _f in "$CLIENT" /opt/bin/qwdtt-web /bin/busybox /bin/sh /bin/cat; do
    [ -f "$_f" ] || continue
    # МАГИЯ ELF — ПЕРВЫМ ДЕЛОМ. Без неё мы читали байты 4, 5, 18, 19 у ЧЕГО
    # УГОДНО: у текстового файла, где пятый байт случайно равен 0x02, ветка
    # big-endian сходилась бы, и роутер получил бы чужую арку. Проверка тем же
    # приёмом, что в opoznat девяноста строками выше: одна функция в файле не
    # имеет права быть строже другой к тому же входу.
    head -c 4 "$_f" 2>/dev/null | grep -q 'ELF' || continue
    _k=$(dd if="$_f" bs=1 skip=4 count=1 2>/dev/null)
    _d=$(dd if="$_f" bs=1 skip=5 count=1 2>/dev/null)
    _m=$(dd if="$_f" bs=1 skip=18 count=1 2>/dev/null)
    _m2=$(dd if="$_f" bs=1 skip=19 count=1 2>/dev/null)
    if [ "$_d" = "$(printf '\2')" ]; then
      # big-endian: e_machine лежит в байте 19, а не 18 (замерено 07.09.2026,
      # сравнение по байту 18 в BE-ветке не совпадало НИКОГДА).
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
  # ЗАПАСНОЙ ПУТЬ — только там, где uname однозначен. Для "mips" он неоднозначен
  # и потому НЕ ГОДИТСЯ: угадать порядок байт нельзя, а угаданный неверно даёт
  # роутеру чужой бинарь. Лучше отказ, чем догадка.
  case "$(uname -m 2>/dev/null)" in
    aarch64)       ARCH=arm64; ARCH_ISTOCHNIK="uname -m"; return 0 ;;
    armv7*|armv6*) ARCH=armv7; ARCH_ISTOCHNIK="uname -m"; return 0 ;;
  esac
  return 1
}

if [ "${1:-}" = "--arch" ]; then
  if ! opoznat_arch; then
    echo "ОТКАЗ: архитектуру не опознать: ни одного читаемого ELF, а uname -m ответил \"$(uname -m 2>/dev/null)\" — по нему порядок байт на MIPS не определить."
    exit 1
  fi
  echo "АРХ=$ARCH"
  echo "источник: $ARCH_ISTOCHNIK"
  exit 0
fi


# ЗАГРУЗЧИК: СПОСОБ ПОДБИРАЕТСЯ ОДИН РАЗ И ЗАПОМИНАЕТСЯ.
#
# 08.09.2026, первый чужой роутер (BusyBox 1.37.0, mipsle): `wget -T` падает по
# сигналу — ровно то, чего мы и опасались с 18.08. Третий вариант спас прогон,
# но перебор шёл на КАЖДОЙ загрузке, и человек получил пять «Segmentation fault»
# подряд без единого слова, что это ожидаемо. Молчаливое падение с продолжением
# читается как поломка, даже когда всё правильно.
#
# Поэтому: подобрали — запомнили — дальше зовём только запомненное, и вслух
# говорим, что именно упало и почему это не беда. Если запомненный способ потом
# откажет (сеть, а не сборка), сбрасываем память и перебираем заново — иначе
# одна сетевая заминка выключила бы рабочий вариант навсегда.
#
# Успехом считается КОД 0 И непустой файл, а не только непустой файл. Упавший по
# сигналу wget возвращает 139, но мог успеть записать часть — и `-s` принял бы
# огрызок за удачу. Это правило 19: скачивание, которое не проверяет запись, —
# не скачивание.
SPOSOB=""          # чем скачали в последний раз (для строки человеку)
SPOSOB_VYBRAN=""   # что подобрали и запоминаем
SKAZANO_PRO_T=0    # предупреждение про -T печатаем один раз

odnim_sposobom() {  # $1 способ, $2 адрес, $3 куда
  rm -f "$3"
  case "$1" in
    curl)         curl -fsSL -m 600 -o "$3" "$2" < /dev/null ;;
    "wget -T")    wget -q -T 600 -O "$3" "$2" < /dev/null ;;   # bb-ok: падение ловится кодом возврата, рядом стоит вариант без -T
    "wget без -T") wget -q -O "$3" "$2" < /dev/null ;;
    *) return 1 ;;
  esac
  _krc=$?
  if [ "$_krc" = 0 ] && [ -s "$3" ]; then return 0; fi
  # Огрызок после падения убираем ЗДЕСЬ, а не «следующей попыткой»: последней
  # попытки может не быть, и тогда он остался бы лежать.
  rm -f "$3"
  return 1
}

skachat() {
  if [ -n "$SPOSOB_VYBRAN" ]; then
    if odnim_sposobom "$SPOSOB_VYBRAN" "$1" "$2"; then SPOSOB="$SPOSOB_VYBRAN"; return 0; fi
    say "    подобранный способ ($SPOSOB_VYBRAN) вдруг не сработал — подбираю заново"
    SPOSOB_VYBRAN=""
  fi
  for _sp in curl "wget -T" "wget без -T"; do
    if [ "$_sp" = curl ] && ! command -v curl >/dev/null 2>&1; then continue; fi
    if odnim_sposobom "$_sp" "$1" "$2"; then
      SPOSOB_VYBRAN="$_sp"; SPOSOB="$_sp"
      return 0
    fi
    if [ "$_sp" = "wget -T" ] && [ "$SKAZANO_PRO_T" = 0 ]; then
      SKAZANO_PRO_T=1
      # Говорим ФАКТ, а не причину: замерено «эта попытка не удалась», а не «эта
      # сборка сломана». Неудача бывает и сетевой, на сборке с исправным -T, и
      # тогда прежний текст врал бы человеку про его роутер (правило 47).
      say "    с ключом -T здесь не сработало. На части сборок BusyBox он падает —"   # bb-ok: это ТЕКСТ человеку, а не вызов wget
      say "    если видите «Segmentation fault», это оно, и это не ваша поломка."
      say "    Дальше качаю без -T и больше -T не пробую."
    fi
  done
  SPOSOB="ни один вариант не сработал"
  return 1
}

# skachat_baza <относительный-путь-в-раздаче> <куда> — пробует ВЕСЬ
# BASE_LIST по порядку (внутренний 10.77.77.1, если применим, затем внешний
# 138.124.78.252), первый успешный побеждает. Тот же приём, что у install.sh
# (`for base in $BASE_URLS`) — здесь не было вовсе, единственный источник был
# зашит намертво, и при обрыве внешнего пути падало ВСЁ, хотя внутренний был
# жив.
skachat_baza() {
  for _baza in $BASE_LIST; do
    if skachat "$_baza/$1" "$2"; then
      return 0
    fi
  done
  return 1
}

sverit() {
  # $1 файл, $2 ждём sha (из manifest_sha), $3 имя для человека.
  # Размер отдельно не сверяем — верная сумма его уже гарантирует; печатаем
  # для глаз, не как условие (правило 47: печатать факт, не вычислять условие
  # из того же самого числа дважды).
  _z=$(wc -c < "$1"); _s=$(sha256sum "$1" | cut -d' ' -f1)
  say "  $3: размер $_z, sha $(echo "$_s" | cut -c1-16)"
  if [ ! -s "$1" ]; then say "    ФАЙЛ ПУСТ"; return 1; fi
  if [ "$_s" != "$2" ]; then say "    СУММА не сошлась с манифестом (SHA256SUMS)"; return 1; fi
  return 0
}

# БЕЗ НОМЕРА ВЕРСИИ ЗДЕСЬ НАРОЧНО (22.09.2026, живой случай): версия в
# заголовке была вписана текстом («0.16») ещё с первой установки этого
# файла, канал/сумма с тех пор менялись, а эта строка — нет. Тестировщик 2
# видел «0.16» в журнале даже когда качался 0.35 из беты: число не имело
# отношения к тому, что реально скачивается. Настоящая версия — ниже, из
# СКАЧАННОГО бинаря (REALVER), не из текста скрипта.
say "=== УСТАНОВКА meridian-dns (канал $QWDTT_CHANNEL), $(date '+%F %T') ==="
mkdir -p "$T" "$BAKDIR"

# ---------- 1. АРХИТЕКТУРА ----------
# По ELF стоящего клиента, без записи на диск. У big-endian e_machine лежит в
# байте 19, а не 18: qwdtt-mips даёт 18=0x00 19=0x08 — замерено 07.09.2026,
# сравнение байта 18 в BE-ветке не совпадало НИКОГДА.
opoznat_arch
if [ -z "$ARCH" ]; then
  say "ОТКАЗ: архитектуру не опознать. Ни одного читаемого ELF (клиент: $(ls "$CLIENT" 2>/dev/null || echo нет)), а uname -m ответил \"$(uname -m 2>/dev/null)\" — по нему порядок байт на MIPS не определить. Ничего не тронуто."
  exit 1
fi
say "канал: $QWDTT_CHANNEL (источники по порядку: $BASE_LIST)"
say "арх: $ARCH (по $ARCH_ISTOCHNIK)"
SPOSOB="ещё не качали"
# Машиночитаемая строка для вызывающих. Разбирать ELF второй раз им нельзя:
# две копии одной логики разъезжаются молча.
echo "АРХ=$ARCH"
case "$ARCH" in
  # ВНИМАНИЕ, IPARCH — это НЕ имя цели entware, а хвост ИМЕНИ ФАЙЛА пакета.
  # Цель называется aarch64-k3.10, а файл в ней — ipset_7.24-1_aarch64-3.10.ipk.
  # Слова похожи, роли разные. Проверено 08.09.2026 загрузкой: все 12 адресов
  # с этими хвостами дают 200, а с именами целей — 404. Не «поправлять» на цель.
  # Сумм и размеров здесь больше нет — см. manifest_sha выше.
  arm64)  IPARCH="aarch64-3.10" ;;
  armv7)  IPARCH="armv7-3.2" ;;
  mips)   IPARCH="mips-3.4" ;;
  mipsle) IPARCH="mipsel-3.4" ;;
esac

# ---------- 2. ЗАГРУЗКА НАБОРА ----------
say "--- загрузка набора DNS (канал $QWDTT_CHANNEL)"
if ! manifest_fetch; then
  rm -rf "$T"
  exit 1
fi
DNSNEW="$T/meridian-dns"; INSTNEW="$T/install.sh"; INITNEW="$T/init.sh"; HOOKNEW="$T/hook.sh"
RC=0
skachat_baza "meridian-dns-$ARCH$SUF" "$DNSNEW"; if [ $? -ne 0 ]; then RC=1; fi
skachat_baza "meridian-dns-install.sh$SUF" "$INSTNEW"; if [ $? -ne 0 ]; then RC=1; fi
skachat_baza "meridian-dns-init.sh$SUF" "$INITNEW"; if [ $? -ne 0 ]; then RC=1; fi
skachat_baza "meridian-dns-netfilter-hook.sh$SUF" "$HOOKNEW"; if [ $? -ne 0 ]; then RC=1; fi
say "скачано способом: $SPOSOB"
if [ "$RC" != 0 ]; then
  say "ОТКАЗ: что-то не скачалось. Ничего боевого не тронуто."
  rm -rf "$T"
  exit 1
fi
# Суммы — ИЗ ЭТОГО ЖЕ манифеста, скачанного минутой раньше, а не из текста
# скрипта. Имя файла в раздаче — единственное, что меняем на суффикс/архитектуру.
DSUM=$(manifest_sha "meridian-dns-$ARCH$SUF")
INST_SUM=$(manifest_sha "meridian-dns-install.sh$SUF")
INIT_SUM=$(manifest_sha "meridian-dns-init.sh$SUF")
HOOK_SUM=$(manifest_sha "meridian-dns-netfilter-hook.sh$SUF")
NEDOSTAET=""
[ -n "$DSUM" ] || NEDOSTAET="$NEDOSTAET meridian-dns-$ARCH$SUF"
[ -n "$INST_SUM" ] || NEDOSTAET="$NEDOSTAET meridian-dns-install.sh$SUF"
[ -n "$INIT_SUM" ] || NEDOSTAET="$NEDOSTAET meridian-dns-init.sh$SUF"
[ -n "$HOOK_SUM" ] || NEDOSTAET="$NEDOSTAET meridian-dns-netfilter-hook.sh$SUF"
if [ -n "$NEDOSTAET" ]; then
  say "ОТКАЗ: в SHA256SUMS нет строки для:$NEDOSTAET"
  say "Манифест неполон — сверить нечем. Ничего не тронуто."
  rm -rf "$T"
  exit 1
fi
BAD=0
sverit "$DNSNEW" "$DSUM" "сервер ($ARCH)"; if [ $? -ne 0 ]; then BAD=1; fi
sverit "$INSTNEW" "$INST_SUM" "установщик"; if [ $? -ne 0 ]; then BAD=1; fi
sverit "$INITNEW" "$INIT_SUM" "init"; if [ $? -ne 0 ]; then BAD=1; fi
sverit "$HOOKNEW" "$HOOK_SUM" "крючок"; if [ $? -ne 0 ]; then BAD=1; fi
if [ "$BAD" != 0 ]; then
  say "ОТКАЗ по сумме. Ничего боевого не тронуто."
  rm -rf "$T"
  exit 1
fi
chmod +x "$DNSNEW" "$INSTNEW" "$INITNEW" "$HOOKNEW"

# ---------- 3. АДРЕС ПРОСЛУШИВАНИЯ ----------
# Спрашиваем СКАЧАННЫЙ бинарь, а не гадаем. Он же даст адрес для probe: голый
# probe уходит на умолчание auto:5453, разрешить «auto» не умеет и возвращает 1
# даже на исправном сервере — замерено 07.09.2026.
"$DNSNEW" resolve-listen -listen auto:5453 -ifaces br0 < /dev/null > "$T/rl.out" 2>"$T/rl.err"
RLRC=$?
RLADDR=$(head -1 "$T/rl.out" 2>/dev/null)
if [ "$RLRC" != 0 ] || [ -z "$RLADDR" ]; then
  say "ОТКАЗ: адрес прослушивания не определён (код $RLRC). Ставить вслепую нельзя."
  sed 's/^/    /' "$T/rl.err" 2>/dev/null
  rm -rf "$T"
  exit 1
fi
say "сервер встанет на: $RLADDR"

# ---------- 4. БЭКАП КОНФИГА ----------
# «Было 0» и «не спросили» — разные вещи. Старый сервер может не знать глагола
# domains show (код 2), и тогда ноль означает «нечем спросить», а печатался бы
# как факт.
DOMBEFORE="не спрашивали (сервера ещё нет)"
if [ -x "$DNSBIN" ]; then
  _do=$("$DNSBIN" -config "$DNS_CONF" domains show < /dev/null 2>/dev/null)
  _dc=$?
  if [ "$_dc" = 0 ]; then
    DOMBEFORE="$(echo "$_do" | grep -c 'id=') (считано domains show прежнего сервера)"
  else
    DOMBEFORE="не спросили: прежний сервер не понял domains show (код $_dc)"
  fi
fi
if [ -f "$DNS_CONF" ]; then
  cp "$DNS_CONF" "$CFGBAK"
  say "конфиг сохранён в $CFGBAK ($(wc -c < "$CFGBAK") б)"
  say "доменов до установки: $DOMBEFORE"
fi

# ---------- 5. IPSET КАК ЗАВИСИМОСТЬ ----------
# Установщик 0.16 различает два случая своими кодами (замерено живым прогоном
# 08.09.2026: без утилиты он и правда отдаёт 7):
#   7 — утилиты ipset НЕТ вовсе. Лечится нашими пакетами.
#   8 — утилита есть, наборы не работают: ядро или права. Пакеты НЕ помогут.
# Годится ли эта система для наших пакетов ipset. Спрашиваем РОУТЕР, а не
# таблицу: имя загрузчика у каждой арки своё, и вторая таблица имён разъехалась
# бы с первой (правило 51).
#
# Замерено 08.09.2026 распаковкой всех двенадцати пакетов: наши три несут только
# /opt/sbin/ipset, libipset.so.13 и libmnl.so.0. Линковщику нужны сверх того
# libc.so.6, libdl.so.2 и загрузчик /opt/lib/ld-* — они из БАЗЫ entware, и если
# база собрана на musl, opkg установит пакеты успешно, а ipset не запустится
# вовсе. Отказ по этой причине обязан называть её ИМЕНЕМ, а не симптомом
# «набор не создаётся» (правило 47).
sistema_pod_nashi_pakety() {
  _musl=$(ls /opt/lib/ld-musl-*.so* 2>/dev/null | head -1)
  if [ -n "$_musl" ]; then
    say "ОТКАЗ: entware на этом роутере собран на musl (нашёл $_musl),"
    say "а наши пакеты ipset собраны под glibc. Они бы установились и не заработали."
    say "Ничего не устанавливаю. Утилиту ipset для musl-сборки надо брать из"
    say "родного репозитория этого entware: opkg update && opkg install ipset"
    return 1
  fi
  # Образец ld*.so*, а НЕ ld-*.so*. На MIPS загрузчик называется ld.so.1 — без
  # дефиса, — и образец с дефисом его не находит. Первая редакция этой проверки
  # (08.09.2026) отказала бы на КАЖДОМ исправном mips/mipsle роутере, то есть на
  # большей части парка, и сказала бы при этом «entware собран без glibc».
  # Поймано стендом на случае «загрузчик ld.so.1 есть, libc.so.6 нет»: код
  # возврата был верный, а причина названа чужая.
  _ld=$(ls /opt/lib/ld*.so* 2>/dev/null | head -1)
  if [ -z "$_ld" ]; then
    say "ОТКАЗ: entware на этом роутере собран без glibc — в /opt/lib нет ни одного"
    say "загрузчика ld-*.so. Наши пакеты ipset без него не запустятся. Не устанавливаю."
    return 1
  fi
  if [ ! -e /opt/lib/libc.so.6 ]; then
    say "ОТКАЗ: в /opt/lib нет libc.so.6, а её требуют и ipset, и libipset."
    say "Загрузчик при этом есть ($_ld) — значит база entware неполная. Не устанавливаю."
    return 1
  fi
  say "  система годится: загрузчик $_ld, libc.so.6 на месте"
  return 0
}

postavit_ipset() {
  sistema_pod_nashi_pakety || return 1
  say "--- ставлю ipset ($IPARCH): три пакета, зависимости сняты линковщиком"
  IBAD=0
  for row in "libmnl_1.0.5-1 libmnl" "libipset_7.24-1 libipset" "ipset_7.24-1 ipset"; do
    n=$(echo "$row" | awk '{print $1}'); short=$(echo "$row" | awk '{print $2}')
    f="$T/$short.ipk"
    skachat_baza "${n}_${IPARCH}${IPSUF}.ipk" "$f"
    if [ $? -ne 0 ]; then say "  $short: НЕ СКАЧАЛСЯ"; IBAD=1; continue; fi
    case "${short}_${IPARCH}" in
      libmnl_aarch64-3.10)   es=9265;  eh=20875d83b957cd3fa1549f743b986da1939c778850087d61c479549b22d6a77c ;;
      libipset_aarch64-3.10) es=57266; eh=5eee9288e63eafca243ec64ce4418b7d9485b5714c9899ae356c36ed7aac9ae2 ;;
      ipset_aarch64-3.10)    es=2901;  eh=50fcc12a2da053c2f948422ef23c5eb8f11de45347ecc1742a78e2198ee0692d ;;
      libmnl_armv7-3.2)      es=7261;  eh=414eb670ca7a9da95ed17762c1e7d8e14f2f281d2b16f74f58a92bfb4588ce64 ;;
      libipset_armv7-3.2)    es=49317; eh=6defd84379e3d8306c9089b45c000fc8e7008999fc38aee49c2da8477b37393f ;;
      ipset_armv7-3.2)       es=2657;  eh=521d41e4cb6d17c57995c0e90f2cac52791605891978a16dab28fed32471a2e9 ;;
      libmnl_mipsel-3.4)     es=8066;  eh=fe8314dc719eed8b0add515fe06538c0e6fd5d3dfb18da0f865846b0b356712b ;;
      libipset_mipsel-3.4)   es=51236; eh=e8f74159b43760ac410dde1d8e009b62f2d4e799b9bc36cec6ca56b44ee1415e ;;
      ipset_mipsel-3.4)      es=2901;  eh=70fb821f3a4c8962a1a065d965080834cbdbcb73137aa67d9dd0157a30fac5c8 ;;
      libmnl_mips-3.4)       es=8090;  eh=fb2f6e8aeba26a17c21a3bccb2da3de5c305d50b095b76ad1cd8f5284961b151 ;;
      libipset_mips-3.4)     es=52051; eh=60b9a3d4bad19afb2dbacb23195ec07bb941fd03799422e476e79be36af08191 ;;
      ipset_mips-3.4)        es=2861;  eh=3361a7f3d72a19dfc4bc9d2ccd7b9b177efd7ef05768fc20b2795fde40b9b1f3 ;;
      *) say "  $short: суммы для $IPARCH нет в скрипте"; IBAD=1; continue ;;
    esac
    sverit "$f" "$eh" "$es" "$short"; if [ $? -ne 0 ]; then IBAD=1; fi
  done
  if [ "$IBAD" != 0 ]; then
    say "ОТКАЗ: пакеты ipset не сошлись. Не устанавливаю."
    return 1
  fi
  opkg install "$T/libmnl.ipk" "$T/libipset.ipk" "$T/ipset.ipk"
  ORC=$?
  say "  opkg вернул: $ORC"
  # ПРОВЕРЯЕМ СОЗДАНИЕМ НАБОРА, а не наличием файла: у пилота модуль ядра был,
  # а утилиты не было, и обратный случай тоже бывает.
  IP=/opt/sbin/ipset
  if [ ! -x "$IP" ]; then IP=$(command -v ipset); fi
  if [ -z "$IP" ]; then
    say "ОТКАЗ: утилита ipset не появилась (opkg код $ORC)."
    return 1
  fi
  PN=dns_ust_proba_$$
  "$IP" destroy "$PN" >/dev/null 2>&1
  CROUT=$("$IP" create "$PN" hash:net family inet 2>&1)
  CR=$?
  CH=$("$IP" list -n 2>/dev/null | grep -c "^$PN$")
  "$IP" destroy "$PN" >/dev/null 2>&1
  if [ "$CR" != 0 ]; then
    say "ОТКАЗ: ipset поставлен, но набор не создаётся: $CROUT"
    return 1
  fi
  if [ "$CH" != 1 ]; then
    say "ОТКАЗ: создание вернуло 0, а набора в списке нет."
    return 1
  fi
  say "  ipset работает: набор создан и снят"
  return 0
}

# ---------- 6. УСТАНОВКА ----------
postavit() {
  # Вывод идёт человеку живьём И в файл: по файлу решаем, был ли отказ ПРО МЕСТО.
  # Код возврата берём не после конвейера — там пришёл бы код tee.
  rm -f "$T/inst.rc"
  { sh "$INSTNEW" "$DNSNEW" "$INITNEW" "$HOOKNEW" < /dev/null 2>&1; echo "REZ=$?" > "$T/inst.rc"; } | tee "$T/inst.out"
  _ir=$(sed -n 's/^REZ=//p' "$T/inst.rc" 2>/dev/null)
  # Пустой код — это «прогон не состоялся», а не «получилось» (правило 41).
  # Отдаём заведомо не-ноль и говорим об этом отдельной строкой.
  if [ -z "$_ir" ]; then
    say "установщик не доработал до конца — кода возврата нет"
    return 90
  fi
  return "$_ir"
}

# ПРО МЕСТО ЛИ ОТКАЗ. Три исхода, не два.
#
# 08.09.2026 на роутере с 54 ГБ свободных отказ был про чужой заворот DNS, а
# следом шло тридцать строк про уборку — человек читал их как часть проблемы.
# Но и «печатать по свободному месту» не годится: порог DSZ*2 — это ~15,4 МБ, а
# у владельца свободно около 10 МБ, то есть на ТЕСНОМ роутере любой отказ снова
# объявлялся бы «делом в месте». Лечить надо не порог, а УТВЕРЖДЕНИЕ:
#   2 — установщик сам сказал про нехватку -> «Дело в месте» (его слова, факт);
#   1 — текст молчит, но свободного мало   -> «не про место по тексту, но здесь
#                                             тесно» + список на всякий случай;
#   0 — текст молчит и места хватает       -> одна строка с командой.
#
# ОБРАЗЦЫ ВЫПИСАНЫ ИЗ ИСХОДНИКА УСТАНОВЩИКА, а не придуманы. Файл
# meridian-dns-install.sh .v137test (38514 Б, b3cfda39…), все пять его отказов,
# которые бывают из-за места:
#   :203 die "не записать $BIN.incoming — вероятно, не хватило места (свободно N КБ)"
#   :208 die "записалось не полностью: G из N байт — не хватило места (свободно N КБ)"
#   :245 die "на перезапись бэкапа нужно ещё ~N КБ (прежний бинарь …, уже занято копией …)"
#   :411 rollback "не удалось создать $CONF (нет места или прав)"
#   :457 rollback "прежний конфиг … не отложить в … (нет прав или места) …"
#
# Придуманный образец ловил из них ОДИН из пяти: `не хвата` не совпадает с «не
# хватило» (хват-И-ло), а строка 245 слова «место» не содержит вовсе. Это и есть
# цена сочинённого образца против прочитанного.
#
# Смена формулировки у кота 1 обязана РОНЯТЬ наш стенд (test-zagruzchik.sh,
# раздел 5 берёт эти строки из САМОГО файла установщика по номерам и требует
# совпадения), а не молча выключать признак.
OBR_MESTA='не хват|нужно ещё|нет места|или места|no space|ENOSPC|disk full|out of space'

pro_mesto_po_tekstu() {
  grep -qiE "$OBR_MESTA" "$T/inst.out" 2>/dev/null
}

# Печатает СКОЛЬКО свободно, или пусто, если не узнали. Пусто — это «не узнали»,
# а не «мало» и не «много» (правило 39).
svobodno_kb() {
  _sv=$(df -Pk /opt 2>/dev/null | awk 'NR==2{print $4}')   # bb-ok: не число — строкой ниже пробуем df -k
  case "$_sv" in ''|*[!0-9]*) _sv=$(df -k /opt 2>/dev/null | awk 'NR==2{print $4}') ;; esac
  case "$_sv" in ''|*[!0-9]*) return 1 ;; esac
  echo "$_sv"
}

# 2 — сказал установщик; 1 — тесно, но он молчит; 0 — ни то, ни другое.
otkaz_pro_mesto() {
  if pro_mesto_po_tekstu; then return 2; fi
  _sv=$(svobodno_kb) || return 0
  _nado=$(( (DSZ * 2 + 1023) / 1024 ))
  if [ "$_sv" -lt "$_nado" ]; then SVOB_TESNO="$_sv"; return 1; fi
  return 0
}
say "--- установка"
postavit
IRC=$?
say "установщик вернул код: $IRC"
if [ "$IRC" = 7 ]; then
  say "код 7 — утилиты ipset нет. Ставлю пакеты и повторяю установку."
  postavit_ipset
  if [ $? -ne 0 ]; then
    say "ОТКАЗ: ipset поставить не удалось. DNS не установлен, роутер как был."
    rm -rf "$T"
    exit 1
  fi
  postavit
  IRC=$?
  say "установщик после ipset вернул код: $IRC"
fi
if [ "$IRC" = 8 ]; then
  say "ОТКАЗ: ipset есть, но наборы не работают (код 8). Это ядро или права —"
  say "наши пакеты тут не помогут, ставить их бессмысленно. Установщик откатился сам."
  rm -rf "$T"
  exit 1
fi
if [ "$IRC" != 0 ]; then
  say "ОТКАЗ: установщик вернул $IRC и откатился сам. Роутер как был."
  # Самый частый отказ установщика — по месту (так было у владельца 08.09.2026).
  # Причину его словами мы не переписываем (правило 47: не называть причину,
  # которую не мерили) — но список показываем всегда: если дело в месте, человек
  # прочитает, ЧТО снимать, а не пойдёт спрашивать нас.
otkaz_pro_mesto
  case $? in
    2) say "ДЕЛО В МЕСТЕ — так сказал сам установщик (его строки выше)."
       chto_snyat ;;
    1) say "По тексту установщика отказ НЕ про место. Но свободного здесь мало"
       say "(${SVOB_TESNO} КБ), поэтому на всякий случай показываю, что можно снять:"
       chto_snyat ;;
    *) say "Отказ не про место: установщик о нём не говорил, и свободного хватает."
       say "Если всё же окажется в нём — посмотреть, что можно снять:"
       say "    sh $0 --chto-snyat" ;;
  esac
  rm -rf "$T"
  exit 1
fi

# ---------- 7. ПЕРЕЖИВЁТ ЛИ ПЕРЕЗАПУСК ----------
# Установка считается состоявшейся, только если переживает перезапуск: мгновенное
# состояние мы создали сами секунду назад, а человек окажется в другом — завтра
# утром, после перезагрузки.
say "--- перезапуск сервера DNS и проверка (клиента и туннель не трогаю)"
sh "$DNS_INIT" stop < /dev/null
sh "$DNS_INIT" start < /dev/null
sleep 3
PRC=127
if [ -x "$DNSBIN" ]; then
  "$DNSBIN" probe -listen "$RLADDR" < /dev/null > "$T/probe.out" 2>&1
  PRC=$?
fi
say "probe после перезапуска: $PRC (0 — отвечает, 1 — молчит)"
if [ "$PRC" = 0 ]; then
  DOMAFTER=$("$DNSBIN" -config "$DNS_CONF" domains show < /dev/null 2>/dev/null | grep -c 'id=')
  say "доменов: до установки — $DOMBEFORE; сейчас — $DOMAFTER"
  # РЕАЛЬНАЯ версия и сумма — у СТОЯЩЕГО бинаря, а не текстом в скрипте (та
  # же правка, что в заголовке выше — живой случай 22.09.2026). Сумма — тем
  # же DSUM, что уже сверили при скачивании: если совпадёт, это подтверждение
  # не гаданием, а тем же самым числом.
  REALVER=$("$DNSBIN" version 2>/dev/null)
  REALSHA=$(sha256sum "$DNSBIN" 2>/dev/null | awk '{print $1}')
  say "установлена версия: ${REALVER:-неизвестна}, sha256: ${REALSHA:-неизвестна}"
  if [ -n "$DSUM" ] && [ "$REALSHA" = "$DSUM" ]; then
    say "сумма совпала с манифестом канала $QWDTT_CHANNEL — установлено именно то, что раздаёт этот канал"
  elif [ -n "$DSUM" ]; then
    say "ВНИМАНИЕ: сумма НЕ совпала с манифестом канала $QWDTT_CHANNEL (ждали $DSUM) — разберитесь, прежде чем доверять установке"
  fi
  # ПРОЦЕССОВ РОВНО ДВА — ПО ФАКТУ, а не по вере в то, что install/init
  # отработали правильно (22.09.2026, живой случай HERO: сирота-guard
  # переживал stop СТАРОГО init.sh молча, установка при этом отчитывалась
  # «готово»). Считаем по /proc (exe=DNSBIN, последнее слово argv run/guard),
  # печатаем оба pid-файла — та же проверка, что теперь есть в блоке HERO.
  _proc_n=0
  for _p in /proc/[0-9]*; do
    _ex=$(readlink "$_p/exe" 2>/dev/null) || continue
    case "$_ex" in "$DNSBIN"|"$DNSBIN (deleted)") ;; *) continue ;; esac
    _cmd=$(tr '\0' '\n' < "$_p/cmdline" 2>/dev/null | tail -1)
    case "$_cmd" in run|guard) _proc_n=$((_proc_n+1)) ;; esac
  done
  say "процессов meridian-dns (run+guard) сейчас: $_proc_n (ждали 2)"
  say "  $RUNDIR_DNS/meridian-dns.pid: $(cat "$RUNDIR_DNS/meridian-dns.pid" 2>/dev/null || echo 'нет файла')"
  say "  $RUNDIR_DNS/meridian-dns-guard.pid: $(cat "$RUNDIR_DNS/meridian-dns-guard.pid" 2>/dev/null || echo 'нет файла')"
  [ "$_proc_n" = 2 ] || say "  ВНИМАНИЕ: ожидали ровно 2 — если не сошлось, смотрите руками (ps w | grep meridian-dns)"
  say "ГОТОВО: DNS установлен и пережил перезапуск."
  rm -rf "$T"
  exit 0
fi
if [ "$PRC" != 1 ]; then
  say "ПРОВЕРКА НЕ ВЫПОЛНЕНА: probe не ответил вовсе (код $PRC)."
  say "Это не «хорошо» и не «плохо» — мы не узнали. Ничего не откатываю."
  sed 's/^/    /' "$T/probe.out" 2>/dev/null
  rm -rf "$T"
  exit 2
fi
say "КРАСНОЕ: после перезапуска сервер не отвечает — завтра после перезагрузки"
say "роутера DNS не поднялся бы, а установка выглядела бы удачной."
sed 's/^/    /' "$T/probe.out" 2>/dev/null
tail -6 /opt/var/log/meridian-dns.log 2>/dev/null | sed 's/^/    лог: /'
if [ -f "$CFGBAK" ]; then
  say "возвращаю прежний конфиг из $CFGBAK и перезапускаю"
  cp "$CFGBAK" "$DNS_CONF"
  sh "$DNS_INIT" stop < /dev/null
  sh "$DNS_INIT" start < /dev/null
  sleep 3
  "$DNSBIN" probe -listen "$RLADDR" < /dev/null >/dev/null 2>&1
  if [ $? = 0 ]; then
    say "сервер поднялся на ПРЕЖНЕМ конфиге: новый список не применён, DNS работает."
    rm -rf "$T"
    exit 1
  fi
fi
say "И на прежнем конфиге сервер не поднялся."
say ""
say "ЧТО ЭТО ЗНАЧИТ ДЛЯ ВАС. Я останавливаю наш DNS, чтобы он не перехватывал"
say "запросы вхолостую: иначе дом остался бы вовсе без разрешения имён."
say "ЕСЛИ У ВАС ДО ЭТОГО РАБОТАЛ ОБХОД ПО ДОМЕНАМ — сейчас он не работает."
say "Это не уборка мусора, это потеря того, что работало, и мы это признаём."
say ""
say "ВЕРНУТЬ ОБХОД, когда разберёмся (или чтобы попробовать прямо сейчас):"
say "    sh $DNS_INIT start"
say "Прежний конфиг лежит в $CFGBAK — если нынешний испорчен, вернуть его так:"
say "    cp $CFGBAK $DNS_CONF ; sh $DNS_INIT stop ; sh $DNS_INIT start"
sh "$DNS_INIT" stop < /dev/null
say ""
say "Пришлите нам весь вывод этого окна целиком."
rm -rf "$T"
exit 1
