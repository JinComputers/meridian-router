#!/bin/sh
# m.sh — запуск установщика Meridian одной строкой (владелец 29.09.2026:
# «надо сократить до одной строчки запуск скрипта и прочее что в нем уже
# зашито»). Команда для человека (бот, письмо):
#
#   wget -qO- http://45.10.247.23/bin/m.sh | sh
#
# Адрес — RU-зеркало по HTTP: его берёт даже голый busybox wget без SSL на
# Keenetic, и оно доступно из России. Дальше всё здесь:
#  - install.sh качается по очереди из GitHub (HTTPS), RU-зеркала, Парижа —
#    curl, если есть, иначе wget;
#  - сверка с SHA256SUMS ТОГО ЖЕ источника (обрыв, битый кэш); не сошлось —
#    следующий источник;
#  - запуск install.sh с вводом С КЛАВИАТУРЫ (/dev/tty): через «| sh» ввод
#    самого sh занят этим файлом, а установщик спрашивает ключ и хэши.
# wget-ssl/ca-certificates здесь не ставим: install.sh сам чинит загрузчик
# для остальных файлов (install.sh: «Загрузчик без HTTPS…»).
#
# Всё внутри main и вызов в последней строке: при «| sh» файл читается по
# мере прихода, оборванная загрузка не должна исполнить половину.

main() {
	F=/tmp/install.sh
	S=/tmp/install.sh.sums
	skachat() {  # $1 куда, $2 откуда
		rm -f "$1"
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --connect-timeout 10 --max-time 300 -o "$1" "$2" 2>/dev/null && [ -s "$1" ] && return 0
		fi
		wget -q -T 30 -O "$1" "$2" 2>/dev/null && [ -s "$1" ] && return 0
		wget -q -O "$1" "$2" 2>/dev/null && [ -s "$1" ] && return 0
		rm -f "$1"
		return 1
	}
	OTKUDA=""
	for B in https://raw.githubusercontent.com/JinComputers/meridian-router/entware \
		http://45.10.247.23/bin \
		http://138.124.78.252:8080/bin; do
		skachat "$F" "$B/install.sh" || continue
		head -1 "$F" | grep -q '^#!' || { echo "[meridian] $B: пришёл не скрипт — пробую другой источник"; continue; }
		if command -v sha256sum >/dev/null 2>&1 && skachat "$S" "$B/SHA256SUMS"; then
			NADO=$(awk '$2 == "install.sh" {print $1}' "$S")
			EST=$(sha256sum "$F" | cut -d' ' -f1)
			if [ -n "$NADO" ] && [ "$NADO" != "$EST" ]; then
				echo "[meridian] $B: установщик не сошёлся с SHA256SUMS — пробую другой источник"
				continue
			fi
		fi
		OTKUDA=$B
		break
	done
	rm -f "$S"
	if [ -z "$OTKUDA" ]; then
		rm -f "$F"
		echo "[meridian] Не удалось скачать установщик ни из одного источника. Проверьте, есть ли на роутере интернет, и повторите."
		exit 1
	fi
	echo "[meridian] установщик скачан ($OTKUDA)"
	# Только для проверки загрузчика: скачать и сверить, не запуская.
	[ -n "${M_TOLKO_SKACHAT:-}" ] && exit 0
	if [ -t 0 ]; then
		exec sh "$F" "$@"
	fi
	if (: < /dev/tty) 2>/dev/null; then
		exec sh "$F" "$@" < /dev/tty
	fi
	exec sh "$F" "$@"
}

main "$@"
