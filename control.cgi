#!/bin/sh
# control.cgi - backend for the zm2k Keenetic panel.
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH

ZM2K_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$ZM2K_DIR/zm2k_lib.sh"

printf 'Content-Type: text/plain; charset=utf-8\r\n'
printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
printf 'Pragma: no-cache\r\n\r\n'

ACTION=${QUERY_STRING%%&*}
ACTION=${ACTION%%=*}

qs_get() {
	printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

require_write() {
	if [ "$ZM2K_READONLY" = "1" ]; then
		echo "READONLY|Панель в режиме только чтения (ZM2K_READONLY=1)"
		exit 0
	fi
}

valid_name() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

valid_ids() {
	[ -z "$1" ] && return 0
	oldifs=$IFS
	IFS=','
	for x in $1; do
		IFS=$oldifs
		valid_name "$x" || { IFS=$oldifs; return 1; }
		IFS=','
	done
	IFS=$oldifs
	return 0
}

list_path() {
	case "$1" in
		sites.list) printf '%s\n' "$ZM2K_SITES" ;;
		*) printf '%s\n' "$ZM2K_ETC/$1" ;;
	esac
}

case "$ACTION" in
	check_zapret)
		zm2k_status
		;;

	get_status)
		status=$(zm2k_status)
		init=$(zm2k_find_init 2>/dev/null)
		name=$(zm2k_current_info | cut -d'|' -f3)
		mode=$(zm2k_conf_mode)
		pid=$(pidof nfqws 2>/dev/null | awk '{print $1}')
		job=0
		zm2k_job_running && job=1
		ro=0
		[ "$ZM2K_READONLY" = "1" ] && ro=1
		printf 'STATUS|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$status" "$init" "$ZM2K_CONF" "$name" "$mode" "$pid" "$job" "$ro"
		;;

	get_configs)
		[ "$(qs_get refresh)" = "1" ] && zm2k_candidates_invalidate
		name=$(zm2k_current_info | cut -d'|' -f3)
		fsdir=$(zm2k_flowseal_dir 2>/dev/null)
		[ -z "$fsdir" ] && fsdir="-"
		printf 'INFO|%s|%s|%s|%s\n' "$(zm2k_conf_mode)" "$(zm2k_status)" "$fsdir" "$name"
		zm2k_candidates_cached | sed 's/^/CFG|/'
		;;

	get_list)
		file=$(qs_get file)
		valid_name "$file" || { echo "ERROR|Недопустимое имя файла"; exit 0; }
		path=$(list_path "$file")
		if [ ! -f "$path" ]; then
			echo "ERROR|Файл не найден: $file"
			exit 0
		fi
		size=$(wc -c < "$path" | tr -d ' ')
		lines=$(wc -l < "$path" | tr -d ' ')
		printf 'LIST|%s|%s|%s\n' "$file" "$size" "$lines"
		head -n 500 "$path"
		[ "$lines" -gt 500 ] 2>/dev/null && echo "TRUNC|1"
		;;

	save_list)
		require_write
		if [ "$REQUEST_METHOD" != "POST" ]; then
			echo "ERROR|Требуется POST"
			exit 0
		fi
		file=$(qs_get file)
		valid_name "$file" || { echo "ERROR|Недопустимое имя файла"; exit 0; }
		case "$file" in
			*.list|*.conf) ;;
			*) echo "ERROR|Можно сохранять только .list и .conf"; exit 0 ;;
		esac
		path=$(list_path "$file")
		tmp="${path}.tmp.$$"
		cat > "$tmp" || { rm -f "$tmp"; echo "ERROR|Ошибка записи"; exit 0; }
		bytes=$(wc -c < "$tmp" | tr -d ' ')
		if [ "$bytes" -gt 1048576 ] 2>/dev/null; then
			rm -f "$tmp"
			echo "ERROR|Файл слишком большой"
			exit 0
		fi
		cp -f "$path" "${path}.bak" 2>/dev/null
		if mv -f "$tmp" "$path"; then
			chmod 644 "$path" 2>/dev/null
			echo "OK|$file|$bytes"
		else
			rm -f "$tmp"
			echo "ERROR|Нет прав на запись"
		fi
		;;

	apply_config)
		require_write
		id=$(qs_get id)
		mode=$(qs_get mode)
		valid_name "$id" || { echo "ERROR|Недопустимый id"; exit 0; }
		case "$mode" in list|all) ;; *) mode=all ;; esac
		req_id=$id
		req_mode=$mode
		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi
		trap 'zm2k_lock_release' EXIT INT TERM
		zm2k_apply_candidate "$req_id" "$req_mode"
		rc=$?
		if [ "$rc" = 0 ]; then
			echo "OK|$req_id|$(zm2k_status)|$req_mode"
		elif [ "$rc" = 2 ]; then
			echo "FAIL|nfqws не запустился, конфиг возвращён"
		else
			echo "FAIL|Конфигурация не найдена или ошибка записи"
		fi
		;;

	restore_original)
		require_write
		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi
		trap 'zm2k_lock_release' EXIT INT TERM
		if zm2k_restore_original; then
			echo "OK|restored|$(zm2k_status)"
		else
			echo "FAIL|Резервная копия не найдена"
		fi
		;;

	restart_zapret)
		require_write
		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi
		trap 'zm2k_lock_release' EXIT INT TERM
		if zm2k_restart; then echo "OK|restarted"; else echo "FAIL|Не удалось перезапустить"; fi
		;;

	stop_zapret)
		require_write
		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi
		trap 'zm2k_lock_release' EXIT INT TERM
		zm2k_stop
		echo "OK|stopped|$(zm2k_status)"
		;;

	start_zapret)
		require_write
		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi
		trap 'zm2k_lock_release' EXIT INT TERM
		if zm2k_start; then echo "OK|started"; else echo "FAIL|Не удалось запустить"; fi
		;;

	test_sites)
		if zm2k_job_running; then
			echo "BUSY|Идёт автоподбор конфигурации"
			exit 0
		fi
		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi
		trap 'zm2k_lock_release' EXIT INT TERM
		echo "MODE|$(zm2k_conf_mode)"
		out="/tmp/zm2k_test.$$.txt"
		if zm2k_test_sites "$out"; then
			cat "$out"
		else
			echo "ERROR|Список сайтов не найден"
		fi
		rm -f "$out"
		;;

	autotest_start)
		require_write
		if zm2k_job_running; then
			echo "BUSY|Автоподбор уже запущен"
			exit 0
		fi
		ids=$(qs_get ids | sed 's/%2C/,/g; s/%2c/,/g')
		valid_ids "$ids" || { echo "ERROR|Недопустимый список id"; exit 0; }
		mode=$(qs_get mode)
		case "$mode" in list|all) ;; *) mode=all ;; esac
		apply=$(qs_get apply)
		[ "$apply" = 1 ] || apply=0

		if ! zm2k_lock_acquire; then
			echo "BUSY|Уже выполняется другая операция"
			exit 0
		fi

		rm -rf "$ZM2K_JOB" 2>/dev/null
		mkdir -p "$ZM2K_JOB/sites" 2>/dev/null
		printf '%s' "$ids" | tr ',' '\n' > "$ZM2K_JOB/ids"
		printf '%s\n' "$mode" > "$ZM2K_JOB/final_mode"
		[ "$apply" = 1 ] && : > "$ZM2K_JOB/apply_best"
		printf 'starting|0|0|init|||\n' > "$ZM2K_JOB/state"
		: > "$ZM2K_JOB/log"
		: > "$ZM2K_JOB/results"

		nohup sh "$ZM2K_DIR/zm2k_autotest.sh" >/dev/null 2>&1 </dev/null &
		wpid=$!
		printf '%s\n' "$wpid" > "$ZM2K_LOCK/pid"
		printf '%s\n' "$wpid" > "$ZM2K_JOB/pid"
		sleep 1
		if ! kill -0 "$wpid" 2>/dev/null; then
			zm2k_lock_release
			echo "ERROR|Не удалось запустить фоновый процесс"
			exit 0
		fi
		echo "STARTED|$wpid"
		;;

	autotest_status)
		if [ ! -d "$ZM2K_JOB" ]; then
			echo "JOB|idle|0|0|idle|||"
			exit 0
		fi
		state=$(tail -n 1 "$ZM2K_JOB/state" 2>/dev/null)
		[ -z "$state" ] && state="starting|0|0|init|||"
		if ! zm2k_job_running && [ ! -f "$ZM2K_JOB/done" ]; then
			case "$state" in
				running*|starting*)
					echo "JOB|dead|$(printf '%s' "$state" | cut -d'|' -f2-5)"
					zm2k_lock_release
					;;
				*) echo "JOB|$state" ;;
			esac
		else
			echo "JOB|$state"
		fi
		cat "$ZM2K_JOB/results" 2>/dev/null
		curid=$(printf '%s' "$state" | cut -d'|' -f5)
		if [ -n "$curid" ] && [ -f "$ZM2K_JOB/sites/$curid" ]; then
			cat "$ZM2K_JOB/sites/$curid" 2>/dev/null
		fi
		tail -n 30 "$ZM2K_JOB/log" 2>/dev/null | sed 's/^/LOG|/'
		[ -f "$ZM2K_JOB/done" ] && cat "$ZM2K_JOB/done"
		;;

	autotest_cancel)
		if [ -d "$ZM2K_JOB" ]; then
			: > "$ZM2K_JOB/cancel"
			echo "CANCEL|requested"
		else
			echo "CANCEL|idle"
		fi
		;;

	get_result_sites)
		id=$(qs_get id)
		valid_name "$id" || { echo "ERROR|Недопустимый id"; exit 0; }
		file="$ZM2K_JOB/sites/$id"
		if [ ! -f "$file" ]; then
			echo "ERROR|Нет данных по сайтам для этого конфига"
			exit 0
		fi
		printf 'RESULT|%s\n' "$id"
		grep "^RESULT|$id|" "$ZM2K_JOB/results" 2>/dev/null | head -n 1 | sed 's/^RESULT|/META|/'
		cat "$file" 2>/dev/null
		;;

	autotest_clear)
		if zm2k_job_running; then
			echo "BUSY|Автоподбор ещё выполняется"
			exit 0
		fi
		rm -rf "$ZM2K_JOB" 2>/dev/null
		echo "CLEARED"
		;;

	get_ifaces)
		echo "IFACE|NAME|PRETTY|IP|STATE"
		NWG_LIST=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(nwg|wg)' | tr '\n' ' ')
		for IF in br0 br1 ppp0 $NWG_LIST; do
			ip link show "$IF" >/dev/null 2>&1 || continue
			IP=$(ip -o -4 addr show "$IF" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n 1)
			[ -z "$IP" ] && IP="-"
			STATE=$(cat "/sys/class/net/$IF/operstate" 2>/dev/null)
			[ -z "$STATE" ] && STATE="-"
			case "$IF" in
				br0) PRETTY="Домашняя сеть" ;;
				br1) PRETTY="Гостевая сеть" ;;
				ppp0) PRETTY="Интернет (PPPoE)" ;;
				nwg*|wg*)
					IDX=$(printf '%s' "$IF" | sed 's/^[a-z]*//')
					DESC=$(LD_LIBRARY_PATH= ndmc -c "show interface Wireguard$IDX" 2>/dev/null |
						grep "description:" | sed 's/.*description: //; s/ *$//')
					[ -n "$DESC" ] && PRETTY="$DESC" || PRETTY="VPN Wireguard $IDX"
					;;
				*) PRETTY="$IF" ;;
			esac
			printf 'IFACE|%s|%s|%s|%s\n' "$IF" "$PRETTY" "$IP" "$STATE"
		done
		;;

	get_log)
		src=$(qs_get src)
		case "$src" in
			worker) file="$ZM2K_JOB/log" ;;
			nfqws) file="/opt/var/log/nfqws.log" ;;
			*) file="/opt/var/log/nfqws.log" ;;
		esac
		if [ -f "$file" ]; then
			printf 'LOG|%s|%s\n' "$src" "$file"
			tail -n 200 "$file"
		else
			printf 'ERROR|Файл не найден: %s\n' "$file"
		fi
		;;

	*)
		echo "ERROR|Неизвестное действие"
		;;
esac
