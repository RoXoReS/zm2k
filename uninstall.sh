#!/bin/sh
# zm2k uninstall.sh - remove the zm2k web panel.
#
# Modes:
#   panel - remove the web panel + lighttpd site and restore nfqws.conf to the
#           snapshot taken before the panel was installed. nfqws stays.
#   all   - remove the web panel and nfqws/zapret files (service, config,
#           binaries, fake files). A backup is written to /tmp first.
#
# Usage:
#   sh uninstall.sh [--panel-only | --all] [-y] [--no-restart] [--purge-state]
#
# Without a mode it shows an interactive menu.

set -u

PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH
export PATH

STATE_DIR=${ZM2K_STATE_DIR:-/opt/etc/zm2k-install}
WEB_DIR=/opt/share/www/zm2k
PORT=9092
LIGHTTPD_CONF=/opt/etc/lighttpd/conf.d/92-zm2k.conf
NFQWS_ETC=/opt/etc/nfqws
NFQWS_CONF=$NFQWS_ETC/nfqws.conf
OPKG_REPO_CONF=${ZM2K_OPKG_REPO_CONF:-/opt/etc/opkg/nfqws-keenetic.conf}
NFQWS_PKG=${ZM2K_NFQWS_PKG:-nfqws-keenetic}

if [ -f "$STATE_DIR/state.conf" ]; then
	. "$STATE_DIR/state.conf"
fi

BACKUP_DIR=$STATE_DIR/backups
MODE=""
ASSUME_YES=0
PURGE_STATE=0
NO_RESTART=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Удаление панели zm2k.

  sh uninstall.sh [режим] [опции]

Режимы:
  --panel-only   удалить только веб-панель; nfqws-keenetic оставить и
                 восстановить nfqws.conf из снимка, сделанного при установке
  --all          удалить панель и nfqws-keenetic/zapret полностью
                 (opkg remove --autoremove nfqws-keenetic + остатки файлов)

Опции:
  -y, --yes      не спрашивать подтверждение (режим --all всё равно требует
                 явного --all)
  --no-restart   не перезапускать lighttpd/nfqws
  --purge-state  удалить служебный каталог с резервными копиями
  -h, --help     эта справка
EOF
}

confirm() {
	[ "$ASSUME_YES" = 1 ] && return 0
	printf '%s [y/N]: ' "$1"
	read -r ans || return 1
	case "$ans" in
		y|Y|yes|YES) return 0 ;;
	esac
	return 1
}

find_init() {
	if [ -f "$STATE_DIR/nfqws.init" ]; then
		saved=$(cat "$STATE_DIR/nfqws.init" 2>/dev/null)
		if [ -n "$saved" ] && [ -x "$saved" ]; then
			printf '%s\n' "$saved"
			return 0
		fi
	fi
	if [ -n "${ZM2K_INIT:-}" ] && [ -x "$ZM2K_INIT" ]; then
		printf '%s\n' "$ZM2K_INIT"
		return 0
	fi
	for f in /opt/etc/init.d/S51nfqws /opt/etc/init.d/S51nfqws2; do
		[ -x "$f" ] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

stop_autotest() {
	if [ -f /tmp/zm2k.lock/pid ]; then
		pid=$(cat /tmp/zm2k.lock/pid 2>/dev/null)
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			say "Останавливаю автоподбор (PID $pid)..."
			kill "$pid" 2>/dev/null
			i=0
			while [ $i -lt 8 ] && kill -0 "$pid" 2>/dev/null; do
				sleep 1
				i=$((i + 1))
			done
			kill -9 "$pid" 2>/dev/null
		fi
	fi
	rm -rf /tmp/zm2k.lock /tmp/zm2k_job 2>/dev/null
}

backup_webdir() {
	[ -d "$WEB_DIR" ] || return 0
	mkdir -p "$BACKUP_DIR" 2>/dev/null || return 0
	ts=$(date +%Y%m%d-%H%M%S)
	if tar -czf "$BACKUP_DIR/webdir-removed-$ts.tar.gz" -C "$(dirname "$WEB_DIR")" "$(basename "$WEB_DIR")" 2>/dev/null; then
		say "Резервная копия панели: $BACKUP_DIR/webdir-removed-$ts.tar.gz"
	else
		warn "не удалось сохранить резервную копию $WEB_DIR"
	fi
}

remove_panel() {
	backup_webdir

	if [ -f "$STATE_DIR/manifest" ]; then
		while IFS= read -r rel; do
			[ -z "$rel" ] && continue
			case "$rel" in
				*/) rm -rf "$WEB_DIR/${rel%/}" ;;
				*) rm -f "$WEB_DIR/$rel" ;;
			esac
		done < "$STATE_DIR/manifest"
	else
		for f in index.html app.js control.cgi zm2k_lib.sh zm2k_autotest.sh zm2k_rescue.sh flowseal.awk sites.list bins.map README.md; do
			rm -f "$WEB_DIR/$f"
		done
		rm -rf "$WEB_DIR/flowseal"
	fi

	if [ "$(cat "$STATE_DIR/webdir.existed" 2>/dev/null || echo 0)" = "1" ]; then
		rmdir "$WEB_DIR" 2>/dev/null || true
	else
		rm -rf "$WEB_DIR"
	fi
	say "Веб-панель удалена: $WEB_DIR"

	if [ "$(cat "$STATE_DIR/lighttpd.conf.existed" 2>/dev/null || echo 0)" = "1" ] && [ -f "$STATE_DIR/lighttpd.conf.preinstall" ]; then
		cp -f "$STATE_DIR/lighttpd.conf.preinstall" "$LIGHTTPD_CONF" \
			&& say "Восстановлен прежний $LIGHTTPD_CONF"
	else
		rm -f "$LIGHTTPD_CONF"
		say "Удалён $LIGHTTPD_CONF"
	fi
}

restore_nfqws_conf() {
	restored=0
	if [ -f "$STATE_DIR/nfqws.conf.preinstall" ]; then
		cp -f "$STATE_DIR/nfqws.conf.preinstall" "$NFQWS_CONF" && restored=1
	elif [ -f "$NFQWS_CONF.zm2k.orig" ]; then
		cp -f "$NFQWS_CONF.zm2k.orig" "$NFQWS_CONF" && restored=1
	elif [ -f "$NFQWS_CONF.zm2k.bak" ]; then
		cp -f "$NFQWS_CONF.zm2k.bak" "$NFQWS_CONF" && restored=1
	fi

	if [ "$restored" = 1 ]; then
		chmod 644 "$NFQWS_CONF" 2>/dev/null
		say "nfqws.conf восстановлен: $NFQWS_CONF"
	else
		warn "снимок nfqws.conf не найден — текущий конфиг оставлен без изменений"
	fi

	# Move the panel's own backups out of the config directory.
	for b in "$NFQWS_CONF.zm2k.orig" "$NFQWS_CONF.zm2k.bak"; do
		[ -f "$b" ] || continue
		mkdir -p "$BACKUP_DIR/nfqws" 2>/dev/null
		mv -f "$b" "$BACKUP_DIR/nfqws/" 2>/dev/null || rm -f "$b"
	done
}

apply_nfqws_state() {
	init=$(find_init || true)
	if [ -z "$init" ]; then
		say "init-скрипт nfqws не найден — перезапуск не требуется"
		return 0
	fi

	was=$(cat "$STATE_DIR/nfqws.was_running" 2>/dev/null || echo "")
	case "$was" in
		1)
			if "$init" restart >/dev/null 2>&1 || "$init" start >/dev/null 2>&1; then
				say "nfqws перезапущен"
			else
				warn "не удалось перезапустить nfqws — проверь $NFQWS_CONF"
			fi
			;;
		0)
			"$init" stop >/dev/null 2>&1 || true
			say "nfqws остановлен (до установки панели он был остановлен)"
			;;
		*)
			if pidof nfqws >/dev/null 2>&1; then
				"$init" restart >/dev/null 2>&1 || warn "не удалось перезапустить nfqws"
			fi
			;;
	esac
}

remove_nfqws() {
	init=$(find_init || true)
	[ -n "$init" ] && "$init" stop >/dev/null 2>&1

	pids=$(pidof nfqws 2>/dev/null || true)
	if [ -n "$pids" ]; then
		kill $pids 2>/dev/null
		sleep 1
		pids=$(pidof nfqws 2>/dev/null || true)
		[ -n "$pids" ] && kill -9 $pids 2>/dev/null
	fi

	# Backup known zapret/nfqws paths before deleting them.
	ts=$(date +%Y%m%d-%H%M%S)
	backup=/tmp/zm2k-nfqws-backup-$ts.tar.gz
	relpaths=""
	for p in "$NFQWS_ETC" /opt/share/zapret /opt/zapret \
		/opt/bin/nfqws /opt/sbin/nfqws /opt/usr/bin/nfqws /opt/usr/sbin/nfqws \
		/opt/etc/init.d/S51nfqws /opt/etc/init.d/S51nfqws2; do
		[ -e "$p" ] && relpaths="$relpaths ${p#/}"
	done
	if [ "$(cat "$STATE_DIR/nfqws.repo.added" 2>/dev/null || echo 0)" = "1" ] && [ -f "$OPKG_REPO_CONF" ]; then
		relpaths="$relpaths ${OPKG_REPO_CONF#/}"
	fi
	if [ -n "$relpaths" ]; then
		if tar -czf "$backup" -C / $relpaths 2>/dev/null; then
			say "Резервная копия nfqws: $backup"
		else
			warn "не удалось создать резервную копию nfqws"
		fi
	fi

	# Prefer the official package manager removal.
	if command -v opkg >/dev/null 2>&1; then
		if opkg list-installed 2>/dev/null | awk -v p="$NFQWS_PKG" '$1 == p { found = 1 } END { exit !found }'; then
			say "opkg remove --autoremove $NFQWS_PKG"
			opkg remove --autoremove "$NFQWS_PKG" >/dev/null 2>&1 \
				|| warn "opkg не смог удалить $NFQWS_PKG"
		fi
		pkgs=$(opkg list-installed 2>/dev/null | awk '{print $1}' | grep -E '^(nfqws|zapret)' || true)
		for pkg in $pkgs; do
			[ "$pkg" = "$NFQWS_PKG" ] && continue
			say "opkg remove $pkg"
			opkg remove "$pkg" >/dev/null 2>&1 || warn "opkg не смог удалить $pkg"
		done
	fi

	# Remove the opkg repo only if the installer added it.
	if [ "$(cat "$STATE_DIR/nfqws.repo.added" 2>/dev/null || echo 0)" = "1" ]; then
		rm -f "$OPKG_REPO_CONF"
		say "Удалён репозиторий: $OPKG_REPO_CONF"
	fi

	for p in "$NFQWS_ETC" /opt/share/zapret /opt/zapret \
		/opt/bin/nfqws /opt/sbin/nfqws /opt/usr/bin/nfqws /opt/usr/sbin/nfqws \
		/opt/etc/init.d/S51nfqws /opt/etc/init.d/S51nfqws2; do
		if [ -e "$p" ]; then
			rm -rf "$p" && say "Удалено: $p"
		fi
	done

	say "Проверь iptables/nftables: правила zapret должны быть сняты init-скриптом."
}

restart_lighttpd() {
	[ "$NO_RESTART" = 1 ] && return 0
	if [ -x /opt/etc/init.d/S80lighttpd ]; then
		if /opt/etc/init.d/S80lighttpd restart >/dev/null 2>&1; then
			say "lighttpd перезапущен"
		else
			warn "не удалось перезапустить lighttpd"
		fi
	elif pidof lighttpd >/dev/null 2>&1 && command -v killall >/dev/null 2>&1; then
		killall -HUP lighttpd 2>/dev/null && say "lighttpd перезагружен (HUP)"
	else
		warn "перезапусти lighttpd вручную"
	fi
}

choose_mode() {
	[ -n "$MODE" ] && return 0
	if [ ! -t 0 ]; then
		die "нет интерактивного ввода: укажи --panel-only или --all"
	fi
	say "Что удалить?"
	say "  1) Только веб-панель. nfqws останется, его конфиг вернётся к состоянию до установки."
	say "  2) Веб-панель и nfqws-keenetic полностью (служба, конфиг, бинарники, файлы zapret)."
	say "  3) Отмена."
	printf 'Выбор [1/2/3]: '
	read -r ans || exit 1
	case "$ans" in
		1) MODE=panel ;;
		2) MODE=all ;;
		3|"") say "Отменено."; exit 0 ;;
		*) die "неверный выбор: $ans" ;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
		--panel-only) MODE=panel ;;
		--all) MODE=all ;;
		-y|--yes) ASSUME_YES=1 ;;
		--no-restart) NO_RESTART=1 ;;
		--purge-state) PURGE_STATE=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "неизвестная опция: $1 (см. --help)" ;;
	esac
	shift
done

[ "${ZM2K_ALLOW_NONROOT:-0}" = 1 ] || [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || die "запусти от root: ssh root@<IP-роутера>"

say "== zm2k uninstaller =="
[ -d "$STATE_DIR" ] || warn "служебный каталог $STATE_DIR не найден — использую стандартные пути"

choose_mode

if [ "$MODE" = "panel" ]; then
	confirm "Удалить веб-панель и восстановить nfqws.conf?" || { say "Отменено."; exit 0; }
	stop_autotest
	restore_nfqws_conf
	remove_panel
	[ "$NO_RESTART" = 1 ] || apply_nfqws_state
	restart_lighttpd
else
	if [ "$ASSUME_YES" != 1 ]; then
		printf 'Это удалит nfqws-keenetic/zapret с роутера. Введите yes для продолжения: '
		read -r ans || exit 1
		[ "$ans" = "yes" ] || { say "Отменено."; exit 0; }
	fi
	stop_autotest
	remove_panel
	remove_nfqws
	restart_lighttpd
fi

say ""
say "Готово."
if [ -d "$BACKUP_DIR" ]; then
	say "Резервные копии: $BACKUP_DIR"
fi

if [ "$PURGE_STATE" = 1 ]; then
	rm -rf "$STATE_DIR"
	say "Служебный каталог удалён: $STATE_DIR"
elif [ -t 0 ] && [ "$ASSUME_YES" != 1 ] && [ -d "$STATE_DIR" ]; then
	printf 'Удалить служебный каталог с резервными копиями %s? [y/N]: ' "$STATE_DIR"
	read -r ans || ans=""
	case "$ans" in
		y|Y|yes|YES) rm -rf "$STATE_DIR"; say "Служебный каталог удалён." ;;
	esac
fi
