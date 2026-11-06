#!/bin/sh
# udalit.sh — полное удаление Meridian с роутера (Keenetic/Entware и OpenWrt).
#   wget -qO- http://45.10.247.23/bin/udalit.sh | sh
# Убирает ТОЛЬКО наше: службы, файлы, правила, подключение «Meridian» в прошивке Keenetic. Системные пакеты (iptables, kmod-tun,
# wget-ssl, ca-certificates, cron и пр.) не трогает — урок 21.10.2026: opkg remove --autoremove унёс iptables вместе с nfqws2.
# Настройки DNS-серверов роутера не меняет. Перед удалением просит подтвердить (ввод с клавиатуры); без терминала — отказ.
# Для стенда: UDALIT_ROOT=<каталог-песочница> (все пути внутри него, процессы и сеть не трогаются), UDALIT_YES=1 (без вопроса).
# Весь код в main, вызов в последней строке: оборванная загрузка «| sh» не исполнит половину.

main() {
	R="${UDALIT_ROOT:-}"
	say() { echo "[meridian-удаление] $*"; }

	if [ -n "$R" ]; then
		case "$R" in /?*) ;; *) say "UDALIT_ROOT должен быть абсолютным путём"; return 1 ;; esac
		[ -d "$R" ] || { say "нет каталога $R"; return 1; }
	fi

	# --- платформа
	if [ -d "$R/opt/etc/init.d" ] && { [ -d "$R/opt/etc/qwdtt" ] || [ -d "$R/opt/etc/meridian" ]; }; then P=entware
	elif [ -d "$R/etc/qwdtt" ] || [ -x "$R/etc/init.d/qwdtt" ] || [ -d "$R/etc/meridian" ]; then P=openwrt
	elif [ -d "$R/opt/etc/init.d" ]; then P=entware
	else say "Meridian на этом роутере не найден (нет ни /opt/etc/qwdtt, ни /etc/qwdtt). Ничего не делаю."; return 0
	fi
	say "платформа: $P"

	# --- подтверждение
	if [ "${UDALIT_YES:-}" != 1 ]; then
		if [ ! -r /dev/tty ]; then say "ОТКАЗ: нет терминала для подтверждения. Запустите:  wget -qO- http://45.10.247.23/bin/udalit.sh > /tmp/u.sh; sh /tmp/u.sh"; return 1; fi
		echo "[meridian-удаление] Будет удалено: клиент, панель, DNS, анти-DPI, маршруты, настройки и ключ Meridian на этом роутере."
		echo "[meridian-удаление] Интернет через роутер останется (после удаления рекомендуется перезагрузка). Продолжить? Напишите  да  и Enter:"
		read ans < /dev/tty || ans=""
		case "$ans" in да|Да|ДА|yes|YES|y|Y) ;; *) say "отменено, ничего не тронуто"; return 0 ;; esac
	fi

	n=0
	rmf() { # удалить файлы/каталоги по шаблонам; считаем сработавшее
		for _p in "$@"; do
			for _f in $_p; do
				[ -e "$_f" ] || [ -L "$_f" ] || continue
				rm -rf "$_f" 2>/dev/null && n=$((n+1))
			done
		done
	}
	kill_names() {
		[ -n "$R" ] && return 0
		for _nm in "$@"; do
			_pids=$(pidof "$_nm" 2>/dev/null) || _pids=""
			[ -n "$_pids" ] && kill $_pids 2>/dev/null
		done
		sleep 1
		for _nm in "$@"; do
			_pids=$(pidof "$_nm" 2>/dev/null) || _pids=""
			[ -n "$_pids" ] && kill -9 $_pids 2>/dev/null
		done
		return 0
	}
	cron_clean() { # $1 — файл cron
		[ -f "$1" ] || return 0
		grep -q -i -e meridian -e qwdtt "$1" 2>/dev/null || return 0
		cp -p "$1" "$1.pered-udaleniem" 2>/dev/null
		grep -v -i -e meridian -e qwdtt "$1.pered-udaleniem" > "$1.new" 2>/dev/null
		cat "$1.new" > "$1" 2>/dev/null; rm -f "$1.new"
		say "cron: строки Meridian убраны (копия: $1.pered-udaleniem)"
	}
	fw_clean() { # правила iptables с нашими цепочками/интерфейсом
		[ -n "$R" ] && return 0
		command -v iptables >/dev/null 2>&1 || return 0
		for _t in nat mangle filter raw; do
			iptables -t "$_t" -S 2>/dev/null | grep -E 'MERIDIAN|-o meridian|-i meridian|-o opkgtun0|-i opkgtun0' | grep '^-A' | while read -r _l; do
				# shellcheck disable=SC2086
				iptables -t "$_t" $(echo "$_l" | sed 's/^-A/-D/') 2>/dev/null
			done
			for _c in $(iptables -t "$_t" -S 2>/dev/null | sed -n 's/^-N \(MERIDIAN[A-Za-z0-9_]*\)$/\1/p'); do
				iptables -t "$_t" -F "$_c" 2>/dev/null; iptables -t "$_t" -X "$_c" 2>/dev/null
			done
		done
		# маршрутные правила с нашими метками/таблицами
		for _m in 0x1c9/0x1ff 0x1ca/0x1ff 0xffffaaa 0xffffaab; do
			_i=0; while ip rule del fwmark "$_m" 2>/dev/null && [ "$_i" -lt 5 ]; do _i=$((_i+1)); done
		done
		nft delete table inet meridian 2>/dev/null
		return 0
	}

	if [ "$P" = entware ]; then
		# 1. остановить службы (каждая чистит за собой), затем добить процессы
		for _s in "$R"/opt/etc/init.d/S99qwdtt "$R"/opt/etc/init.d/S98qwdtt-web "$R"/opt/etc/init.d/S98meridian-web "$R"/opt/etc/init.d/S97meridian-router \
		          "$R"/opt/etc/init.d/S81meridian-dns "$R"/opt/etc/init.d/S51meridian-antidpi; do
			[ -x "$_s" ] || continue
			[ -n "$R" ] || ( "$_s" stop >/dev/null 2>&1 & )
		done
		[ -n "$R" ] || sleep 5
		kill_names qwdtt qwdtt-web meridian-web qwdtt-probe meridian-dns meridian-route meridian-antidpi meridian-ctl
		say "службы остановлены"
		# 2. cron
		cron_clean "$R/opt/etc/crontabs/root"
		# 3. подключение «Meridian» в прошивке — только если оно наше
		if [ -z "$R" ] && command -v ndmc >/dev/null 2>&1; then
			_r=$(wget -qO- http://localhost:79/rci/show/interface/OpkgTun0 2>/dev/null) || _r=""
			case "$_r" in
				*'"description": "Meridian"'*)
					if LD_LIBRARY_PATH= ndmc -c "no interface OpkgTun0" 2>&1 | grep -qi -e error -e failed; then
						say "ВНИМАНИЕ: подключение «Meridian» в прошивке не удалилось — уберите его вручную в веб-интерфейсе (Интернет → Другие подключения)"
					else
						LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
						say "подключение «Meridian» в прошивке удалено, настройки сохранены"
					fi ;;
				*'"id": "OpkgTun0"'*) say "подключение OpkgTun0 в прошивке не наше (другое описание) — не трогаю" ;;
			esac
		fi
		# 4. правила
		fw_clean
		# 5. файлы
		rmf "$R"/opt/etc/init.d/S99qwdtt "$R"/opt/etc/init.d/S98qwdtt-web "$R"/opt/etc/init.d/S98meridian-web "$R"/opt/etc/init.d/S97meridian-router \
		    "$R"/opt/etc/init.d/S81meridian-dns "$R"/opt/etc/init.d/S51meridian-antidpi* "$R"/opt/etc/init.d/S00meridian-fastnat* \
		    "$R"/opt/etc/ndm/netfilter.d/*meridian* "$R"/opt/etc/ndm/*.d/*meridian* "$R"/opt/etc/ndm/*.d/*qwdtt* \
		    "$R"/opt/bin/meridian-* "$R"/opt/bin/qwdtt "$R"/opt/bin/qwdtt-* "$R"/opt/bin/.meridian-* \
		    "$R"/opt/sbin/meridian-* "$R"/opt/sbin/qwdtt "$R"/opt/sbin/qwdtt-* \
		    "$R"/opt/etc/meridian "$R"/opt/etc/meridian-antidpi "$R"/opt/etc/meridian-router "$R"/opt/etc/qwdtt \
		    "$R"/opt/var/backup/meridian-dns "$R"/opt/var/backup/qwdtt \
		    "$R"/opt/var/log/meridian* "$R"/opt/var/log/qwdtt* "$R"/opt/var/run/meridian* "$R"/opt/var/run/qwdtt* \
		    "$R"/tmp/qwdtt-run "$R"/tmp/install.sh "$R"/tmp/install.sh.sums "$R"/tmp/meridian-install.log
	else
		for _s in "$R"/etc/init.d/qwdtt* "$R"/etc/init.d/meridian*; do
			[ -x "$_s" ] || continue
			[ -n "$R" ] || { ( "$_s" stop >/dev/null 2>&1 & ); "$_s" disable >/dev/null 2>&1; }
		done
		[ -n "$R" ] || sleep 3
		kill_names qwdtt-run qwdtt-web meridian-web meridian-run meridian-dns meridian-antidpi meridian-route-hold meridian-mode
		say "службы остановлены и сняты с автозапуска"
		cron_clean "$R/etc/crontabs/root"
		if [ -z "$R" ] && command -v uci >/dev/null 2>&1; then
			uci -q get firewall.meridian >/dev/null 2>&1 && uci -q delete firewall.meridian
			uci -q get firewall.meridian_fwd >/dev/null 2>&1 && uci -q delete firewall.meridian_fwd
			uci -q commit firewall 2>/dev/null
			for _z in $(uci -q show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^.=]*\)\.network=.*meridianraw.*/\1/p"); do
				uci -q del_list "$_z.network=meridianraw" 2>/dev/null
			done
			uci -q commit firewall 2>/dev/null
			for _n in meridianraw wdttraw; do uci -q get network.$_n >/dev/null 2>&1 && uci -q delete network.$_n; done
			uci -q commit network 2>/dev/null
			say "настройки uci (зона meridian, сеть meridianraw) убраны"
			# пакеты ТОЛЬКО наши, без --autoremove
			if command -v apk >/dev/null 2>&1; then apk del luci-app-meridian meridian-web >/dev/null 2>&1
			elif command -v opkg >/dev/null 2>&1; then opkg remove luci-app-meridian meridian-web >/dev/null 2>&1; fi
		fi
		fw_clean
		rmf "$R"/etc/init.d/qwdtt* "$R"/etc/init.d/meridian* "$R"/etc/rc.d/*qwdtt* "$R"/etc/rc.d/*meridian* \
		    "$R"/etc/hotplug.d/iface/*meridian* "$R"/etc/hotplug.d/iface/*qwdtt* \
		    "$R"/usr/sbin/meridian-* "$R"/usr/sbin/qwdtt "$R"/usr/sbin/qwdtt-* "$R"/usr/bin/meridian-ctl "$R"/usr/bin/qwdtt-ctl \
		    "$R"/etc/qwdtt "$R"/etc/meridian "$R"/etc/meridian-antidpi "$R"/etc/dnsmasq.d/*meridian* \
		    "$R"/www/luci-static/resources/view/meridian "$R"/usr/share/luci/menu.d/luci-app-meridian.json \
		    "$R"/usr/share/rpcd/acl.d/luci-app-meridian.json \
		    "$R"/tmp/qwdtt-run "$R"/tmp/install.sh "$R"/tmp/install.sh.sums "$R"/tmp/meridian-install.log "$R"/var/log/qwdtt.log "$R"/var/log/meridian*
		if [ -z "$R" ]; then
			rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
			/etc/init.d/firewall reload >/dev/null 2>&1; /etc/init.d/network reload >/dev/null 2>&1
			[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1
			[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1
		fi
	fi

	say "удалено объектов: $n"
	say "ГОТОВО. Meridian удалён. Рекомендуется перезагрузить роутер, чтобы сбросились остатки правил."
	return 0
}

main "$@"
