#!/bin/sh
# zm2k_rescue.sh - emergency recovery for the zm2k panel.
# Stops a running autotest, restores the original nfqws.conf and restarts zapret.
# Safe to run over SSH when the web panel is unreachable or the internet is down.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH

ZM2K_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$ZM2K_DIR/zm2k_lib.sh"

say() { printf '%s\n' "$*"; }

say "== zm2k rescue =="

# 1. Stop the background autotest worker (if any).
if [ -f "$ZM2K_LOCK/pid" ]; then
	pid=$(cat "$ZM2K_LOCK/pid" 2>/dev/null)
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
rm -rf "$ZM2K_LOCK" 2>/dev/null

# 2. Restore the original configuration.
if [ -f "$ZM2K_CONF.zm2k.orig" ]; then
	cp -f "$ZM2K_CONF.zm2k.orig" "$ZM2K_CONF"
	chmod 644 "$ZM2K_CONF" 2>/dev/null
	say "Восстановлен $ZM2K_CONF из .zm2k.orig"
elif [ -f "$ZM2K_CONF.zm2k.bak" ]; then
	cp -f "$ZM2K_CONF.zm2k.bak" "$ZM2K_CONF"
	chmod 644 "$ZM2K_CONF" 2>/dev/null
	say "Восстановлен $ZM2K_CONF из .zm2k.bak"
elif [ -f "$ZM2K_JOB/backup.conf" ]; then
	cp -f "$ZM2K_JOB/backup.conf" "$ZM2K_CONF"
	chmod 644 "$ZM2K_CONF" 2>/dev/null
	say "Восстановлен $ZM2K_CONF из резервной копии автоподбора"
else
	say "Резервная копия не найдена — конфиг оставлен без изменений."
fi

# 3. Restart zapret. If it cannot start, stop it so plain internet works.
if zm2k_restart; then
	say "zapret перезапущен: $(zm2k_status)"
else
	say "Не удалось перезапустить zapret. Останавливаю его (интернет без обхода DPI)."
	zm2k_stop
	say "Статус: $(zm2k_status)"
	say "Проверь конфиг вручную: $ZM2K_CONF"
fi

say "Готово."
