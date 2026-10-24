#!/bin/sh /etc/rc.common
# Автозапуск панели управления на OpenWRT (procd).
#
# Раздаётся файлом с 17.08.2026 — по той же причине, что и Entware-вариант.
# Отдельно важное: без `enable` (симлинк в /etc/rc.d) служба не поднимется после
# перезагрузки роутера. На GL-MT3000 с OpenWrt 25.12.5 автозапуска не оказалось
# вовсе, и панель с клиентом работали только потому, что их запустил установщик
# в той же сессии.
#
# ПУТЬ К БИНАРЮ ИСПРАВЛЕН 14.09.2026: было /opt/bin/qwdtt-web — путь Entware,
# скопированный из Entware-варианта не глядя. На нативном OpenWrt (без Entware)
# install.sh кладёт панель в /usr/sbin (INSTALL_DIR для этой платформы), и
# /opt/bin там не существует вовсе. procd на такую команду молча не поднимал
# службу: автозапуск включался (симлинк в rc.d есть), а порт 8090 не отвечал
# никогда. Раньше это не было видно — установщик писал «панель установлена и
# запущена» БЕЗУСЛОВНО, без проверки. Найдено владельцем на живом роутере
# GL-MT3000 сразу после того, как установщик научился эту проверку делать.
START=98
STOP=11
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/sbin/qwdtt-web
	# 18.10.2026: роутеры с памятью меньше 200 МБ (128 МБ) — панель с ограничением памяти Go, как у Entware-варианта.
	_mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' "${QWDTT_MEMINFO:-/proc/meminfo}" 2>/dev/null); case "$_mem_kb" in ''|*[!0-9]*) _mem_kb=0 ;; esac
	if [ "$_mem_kb" -gt 0 ] && [ "$_mem_kb" -lt 200000 ]; then
		procd_set_param env GOGC="${GOGC:-50}" GOMEMLIMIT="${GOMEMLIMIT:-10MiB}"
	fi
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
