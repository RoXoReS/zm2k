#!/bin/sh
# zm2k_lib.sh - shared helpers for the zm2k Keenetic panel.
# POSIX sh / BusyBox compatible. No bashisms.

ZM2K_DIR=${ZM2K_DIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}
ZM2K_ETC=${ZM2K_ETC:-/opt/etc/nfqws}
ZM2K_CONF=${ZM2K_CONF:-$ZM2K_ETC/nfqws.conf}
ZM2K_JOB=${ZM2K_JOB:-/tmp/zm2k_job}
ZM2K_LOCK=${ZM2K_LOCK:-/tmp/zm2k.lock}
ZM2K_SITES=${ZM2K_SITES:-$ZM2K_DIR/sites.list}
ZM2K_FLOWSEAL=${ZM2K_FLOWSEAL:-$ZM2K_DIR/flowseal}
ZM2K_INIT=${ZM2K_INIT:-}
# Safety: 1 = panel only reads, every mutating action is blocked.
# Default 0: changes are allowed, but only after an explicit button + confirm.
ZM2K_READONLY=${ZM2K_READONLY:-0}

# ---------------------------------------------------------------- init script
zm2k_find_init() {
	if [ -n "$ZM2K_INIT" ] && [ -f "$ZM2K_INIT" ]; then
		printf '%s\n' "$ZM2K_INIT"
		return 0
	fi
	for f in /opt/etc/init.d/S51nfqws /opt/etc/init.d/S51nfqws2; do
		if [ -f "$f" ]; then
			printf '%s\n' "$f"
			return 0
		fi
	done
	return 1
}

zm2k_status() {
	init=$(zm2k_find_init) || { echo NOT_INSTALLED; return 0; }
	out=$("$init" status 2>/dev/null)
	if printf '%s' "$out" | grep -q "is running"; then
		echo RUNNING
	elif pidof nfqws >/dev/null 2>&1; then
		echo RUNNING
	else
		echo STOPPED
	fi
}

zm2k_restart() {
	init=$(zm2k_find_init) || return 1
	"$init" stop >/dev/null 2>&1
	i=0
	while [ $i -lt 8 ]; do
		[ "$(zm2k_status)" = RUNNING ] || break
		sleep 1
		i=$((i + 1))
	done
	if [ "$(zm2k_status)" = RUNNING ]; then
		for p in $(pidof nfqws 2>/dev/null); do kill "$p" 2>/dev/null; done
		sleep 1
	fi
	"$init" start >/dev/null 2>&1
	i=0
	while [ $i -lt 12 ]; do
		[ "$(zm2k_status)" = RUNNING ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

zm2k_stop() {
	init=$(zm2k_find_init) || return 1
	"$init" stop >/dev/null 2>&1
	return 0
}

zm2k_start() {
	init=$(zm2k_find_init) || return 1
	"$init" start >/dev/null 2>&1
	i=0
	while [ $i -lt 12 ]; do
		[ "$(zm2k_status)" = RUNNING ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# ------------------------------------------------------------------ lock/job
zm2k_lock_acquire() {
	if mkdir "$ZM2K_LOCK" 2>/dev/null; then
		printf '%s\n' "$$" > "$ZM2K_LOCK/pid"
		return 0
	fi
	pid=$(cat "$ZM2K_LOCK/pid" 2>/dev/null)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	rm -rf "$ZM2K_LOCK" 2>/dev/null
	if mkdir "$ZM2K_LOCK" 2>/dev/null; then
		printf '%s\n' "$$" > "$ZM2K_LOCK/pid"
		return 0
	fi
	return 1
}

zm2k_lock_release() {
	rm -rf "$ZM2K_LOCK" 2>/dev/null
}

zm2k_job_running() {
	if [ -f "$ZM2K_LOCK/pid" ]; then
		pid=$(cat "$ZM2K_LOCK/pid" 2>/dev/null)
		[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	fi
	# The lock may hold a launcher wrapper pid; the worker writes its own pid.
	if [ -f "$ZM2K_JOB/pid" ]; then
		pid=$(cat "$ZM2K_JOB/pid" 2>/dev/null)
		[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
	fi
	return 1
}

# --------------------------------------------------------------- nfqws.conf
zm2k_conf_get() {
	[ -f "$ZM2K_CONF" ] || { echo ""; return 1; }
	line=$(grep "^$1=" "$ZM2K_CONF" 2>/dev/null | head -n 1)
	[ -z "$line" ] && { echo ""; return 1; }
	val=${line#*=}
	case "$val" in
		\"*\") val=${val#\"}; val=${val%\"} ;;
	esac
	printf '%s\n' "$val"
}

zm2k_conf_mode() {
	v=$(zm2k_conf_get NFQWS_EXTRA_ARGS)
	case "$v" in
		*MODE_ALL*) echo all ;;
		*MODE_LIST*) echo list ;;
		*) echo custom ;;
	esac
}

zm2k_conf_backup_once() {
	[ -f "$ZM2K_CONF" ] || return 1
	[ -f "$ZM2K_CONF.zm2k.orig" ] || cp -f "$ZM2K_CONF" "$ZM2K_CONF.zm2k.orig"
	return 0
}

zm2k_conf_set_strategy() {
	tcp=$1
	quic=$2
	mode=$3
	[ -f "$ZM2K_CONF" ] || return 1
	tmp="${ZM2K_CONF}.tmp.$$"
	awk -v tcp="$tcp" -v quic="$quic" -v mode="$mode" '
		BEGIN { dt = 0; dq = 0; dm = 0 }
		/^NFQWS_ARGS=/ {
			if (dt == 0) { print "NFQWS_ARGS=\"" tcp "\""; dt = 1 }
			next
		}
		/^NFQWS_ARGS_QUIC=/ {
			if (dq == 0) {
				if (quic != "") print "NFQWS_ARGS_QUIC=\"" quic "\""
				else print
				dq = 1
			}
			next
		}
		/^NFQWS_EXTRA_ARGS=/ {
			if (dm == 0) {
				if (mode != "") print "NFQWS_EXTRA_ARGS=\"" mode "\""
				else print
				dm = 1
			}
			next
		}
		{ print }
		END {
			if (dt == 0) print "NFQWS_ARGS=\"" tcp "\""
			if (dq == 0 && quic != "") print "NFQWS_ARGS_QUIC=\"" quic "\""
			if (dm == 0 && mode != "") print "NFQWS_EXTRA_ARGS=\"" mode "\""
		}
	' "$ZM2K_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$ZM2K_CONF" || { rm -f "$tmp"; return 1; }
	chmod 644 "$ZM2K_CONF" 2>/dev/null
	return 0
}

# -------------------------------------------------------------- fake *.bin
zm2k_resolve_bin() {
	fname=$1
	[ -z "$fname" ] && return 1

	if [ -f "$ZM2K_DIR/bins.map" ]; then
		p=$(grep -F "$fname|" "$ZM2K_DIR/bins.map" 2>/dev/null | head -n 1 | cut -d'|' -f2)
		if [ -n "$p" ] && [ -f "$p" ]; then
			printf '%s\n' "$p"
			return 0
		fi
	fi

	for d in "$ZM2K_ETC" "$ZM2K_ETC/bin" "$ZM2K_ETC/fake" \
		/opt/share/zapret/bin /opt/share/zapret/files/fake \
		/opt/zapret/bin /opt/zapret/files/fake /opt/etc/zapret; do
		if [ -f "$d/$fname" ]; then
			printf '%s\n' "$d/$fname"
			return 0
		fi
	done

	case "$fname" in
		tls_clienthello_*.bin)
			for f in "$ZM2K_ETC"/tls_clienthello*.bin "$ZM2K_ETC"/fake/tls_clienthello*.bin; do
				[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
			done
			;;
		quic_initial_*.bin)
			for f in "$ZM2K_ETC"/quic_initial*.bin "$ZM2K_ETC"/fake/quic_initial*.bin; do
				[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
			done
			;;
		stun.bin|stun2.bin)
			for f in "$ZM2K_ETC"/stun*.bin; do
				[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
			done
			;;
		ACTIVE_DISCORD_UDP.bin)
			for f in "$ZM2K_ETC"/discord*.bin "$ZM2K_ETC"/ACTIVE_DISCORD*.bin; do
				[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
			done
			;;
	esac
	return 1
}

# Build a name|path map for every fake *.bin used by flowseal.
zm2k_build_binmap() {
	mapfile=$1
	: > "$mapfile"
	fs_dir=$(zm2k_flowseal_dir) || return 0
	names=$(grep -ho '%BIN%[^" ]*' "$fs_dir"/*.bat 2>/dev/null |
		sed 's/^%BIN%//' | sort -u)
	for n in $names; do
		p=$(zm2k_resolve_bin "$n") || continue
		printf '%s|%s\n' "$n" "$p" >> "$mapfile"
	done
	return 0
}

# Turn a raw flowseal rule into nfqws arguments in one awk pass.
# kind: tcp | quic ; mapfile: output of zm2k_build_binmap
zm2k_clean_rule() {
	raw=$1
	kind=$2
	mapfile=$3
	awk -v raw="$raw" -v kind="$kind" -v mapfile="$mapfile" '
		BEGIN {
			if (mapfile != "") {
				while ((getline line < mapfile) > 0) {
					p = index(line, "|")
					if (p > 0) binmap[substr(line, 1, p - 1)] = substr(line, p + 1)
				}
				close(mapfile)
			}
			n = split(raw, a, " ")
			out = ""
			for (i = 1; i <= n; i++) {
				tok = a[i]
				gsub(/"/, "", tok)
				if (tok == "" || tok == "^" || tok == "--new") continue
				if (tok ~ /^--hostlist=/ || tok ~ /^--hostlist-domains=/ ||
					tok ~ /^--hostlist-exclude=/ || tok ~ /^--hostlist-exclude-domains=/) continue
				if (tok ~ /^--ipset=/ || tok ~ /^--ipset-exclude=/) continue
				if (tok ~ /^--wf-/) continue
				if (kind == "tcp") {
					if (tok ~ /^--filter-tcp=/ || tok ~ /^--filter-l3=/ ||
						tok ~ /^--filter-l4=/ || tok ~ /^--filter-udp=/ ||
						tok ~ /^--filter-l7=/) continue
				} else {
					if (tok ~ /^--filter-tcp=/ || tok ~ /^--filter-l3=/ ||
						tok ~ /^--filter-l4=/) continue
				}
				if (tok ~ /%BIN%/) {
					name = tok
					sub(/.*%BIN%/, "", name)
					sub(/[^A-Za-z0-9._-].*/, "", name)
					if (!(name in binmap)) continue
					sub(/%BIN%[^ ]*/, binmap[name], tok)
				}
				if (tok ~ /%LISTS%/ || tok ~ /%GameFilter/) continue
				gsub(/\^/, "", tok)
				out = (out == "") ? tok : out " " tok
			}
			print out
		}
	'
}

# Return "tcp<TAB>quic" for one flowseal .bat file.
zm2k_flowseal_pair() {
	awk -f "$ZM2K_DIR/flowseal.awk" "$1" 2>/dev/null
}

zm2k_slug() {
	printf '%s' "$1" | tr 'A-Z' 'a-z' |
		sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
}

zm2k_flowseal_dir() {
	for d in "$ZM2K_FLOWSEAL" /opt/etc/nfqws/flowseal /opt/share/zapret/flowseal; do
		if [ -d "$d" ]; then
			printf '%s\n' "$d"
			return 0
		fi
	done
	return 1
}

# ------------------------------------------------------------ candidate list
# Output: id|source|name|tcp_args|quic_args|is_current
zm2k_list_candidates() {
	cur_tcp=$(zm2k_conf_get NFQWS_ARGS)
	cur_quic=$(zm2k_conf_get NFQWS_ARGS_QUIC)
	seen_tcp="/tmp/zm2k_seen_tcp.$$"
	seen_ids="/tmp/zm2k_seen_ids.$$"
	tmp_bv="/tmp/zm2k_bv.$$"
	binmap="/tmp/zm2k_binmap.$$"
	: > "$seen_tcp"
	: > "$seen_ids"
	: > "$tmp_bv"
	zm2k_build_binmap "$binmap"
	matched=0
	bv_idx=0

	if [ -f "$ZM2K_CONF" ]; then
		grep '^#NFQWS_ARGS=' "$ZM2K_CONF" 2>/dev/null |
			sed 's/^#NFQWS_ARGS=//' > "$tmp_bv"
	fi

	while IFS= read -r raw; do
		raw=$(printf '%s' "$raw" | sed 's/^"//; s/"$//')
		tcp=$(zm2k_clean_rule "$raw" tcp "$binmap")
		[ -z "$tcp" ] && continue
		grep -Fxq "$tcp" "$seen_tcp" 2>/dev/null && continue
		printf '%s\n' "$tcp" >> "$seen_tcp"
		bv_idx=$((bv_idx + 1))
		ds=$(printf '%s' "$tcp" | sed -n 's/.*--dpi-desync=\([^ ]*\).*/\1/p')
		fool=$(printf '%s' "$tcp" | sed -n 's/.*--dpi-desync-fooling=\([^ ]*\).*/\1/p')
		[ -z "$ds" ] && ds="strategy"
		name="Bol-van · $ds"
		[ -n "$fool" ] && name="$name · $fool"
		cur=0
		if [ "$tcp" = "$cur_tcp" ]; then
			cur=1
			matched=1
		fi
		printf 'bv%d|Bol-van|%s|%s||%s\n' "$bv_idx" "$name" "$tcp" "$cur"
	done < "$tmp_bv"

	fs_dir=$(zm2k_flowseal_dir) || fs_dir=""
	if [ -n "$fs_dir" ]; then
		for f in "$fs_dir"/*.bat; do
			[ -f "$f" ] || continue
			base=$(basename "$f" .bat)
			pair=$(zm2k_flowseal_pair "$f")
			tab=$(printf '\t')
			IFS=$tab read -r raw_tcp raw_quic <<EOF
$pair
EOF
			[ -z "$raw_tcp" ] && continue
			tcp=$(zm2k_clean_rule "$raw_tcp" tcp "$binmap")
			[ -z "$tcp" ] && continue
			quic=""
			[ -n "$raw_quic" ] && quic=$(zm2k_clean_rule "$raw_quic" quic "$binmap")
			key="$tcp|$quic"
			grep -Fxq "$key" "$seen_tcp" 2>/dev/null && continue
			printf '%s\n' "$key" >> "$seen_tcp"

			slug=$(zm2k_slug "$base")
			[ -z "$slug" ] && slug="config"
			id="fs-$slug"
			n=2
			while grep -Fxq "$id" "$seen_ids" 2>/dev/null; do
				id="fs-$slug-$n"
				n=$((n + 1))
			done
			printf '%s\n' "$id" >> "$seen_ids"

			name=$(printf '%s' "$base" | sed 's/^general[[:space:]]*//; s/^[[:space:](]*//; s/[[:space:])]*$//')
			[ -z "$name" ] && name="General"
			grep -q 'NOT RECOMMENDED' "$f" 2>/dev/null && name="$name (не реком.)"

			cur=0
			if [ "$tcp" = "$cur_tcp" ]; then
				if [ -z "$quic" ] || [ "$quic" = "$cur_quic" ]; then
					cur=1
					matched=1
				fi
			fi
			printf '%s|Flowseal|%s|%s|%s|%s\n' "$id" "$name" "$tcp" "$quic" "$cur"
		done
	fi

	if [ "$matched" = 0 ] && [ -n "$cur_tcp" ]; then
		printf 'current|Пользователь|Пользовательский (текущий)|%s||1\n' "$cur_tcp"
	fi

	rm -f "$seen_tcp" "$seen_ids" "$tmp_bv" "$binmap"
}

zm2k_candidates_cached() {
	cache="$ZM2K_JOB/candidates.cache"
	stamp="$ZM2K_JOB/candidates.ts"
	mkdir -p "$ZM2K_JOB" 2>/dev/null
	now=$(date +%s)
	age=999999
	if [ -f "$stamp" ]; then
		then_ts=$(cat "$stamp" 2>/dev/null)
		[ -n "$then_ts" ] && age=$((now - then_ts))
	fi
	if [ -f "$cache" ] && [ "$age" -lt 1800 ]; then
		cat "$cache"
		return 0
	fi
	tmp="$cache.tmp.$$"
	if zm2k_list_candidates > "$tmp"; then
		mv -f "$tmp" "$cache"
		printf '%s\n' "$now" > "$stamp"
	fi
	cat "$cache" 2>/dev/null
}

zm2k_candidates_invalidate() {
	rm -f "$ZM2K_JOB/candidates.cache" "$ZM2K_JOB/candidates.ts" 2>/dev/null
}

# Update the "current" marker in the cached list without regenerating it.
zm2k_candidates_mark_current() {
	cache="$ZM2K_JOB/candidates.cache"
	[ -f "$cache" ] || return 0
	mark_t=$1
	mark_q=$2
	tmp="$cache.tmp.$$"
	awk -F'|' -v t="$mark_t" -v q="$mark_q" '
		BEGIN { OFS = "|" }
		{
			cur = ($4 == t && ($5 == "" || $5 == q)) ? 1 : 0
			$6 = cur
			print
		}
	' "$cache" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache"
}

zm2k_current_info() {
	cur_tcp=$(zm2k_conf_get NFQWS_ARGS)
	cur_quic=$(zm2k_conf_get NFQWS_ARGS_QUIC)
	line=$(zm2k_candidates_cached | awk -F'|' -v t="$cur_tcp" -v q="$cur_quic" \
		'$4 == t && ($5 == "" || $5 == q) { print; exit }')
	if [ -n "$line" ]; then
		printf '%s\n' "$line"
		return 0
	fi
	printf 'current|Пользователь|Пользовательский (текущий)|%s||1\n' "$cur_tcp"
}

# --------------------------------------------------------------- apply config
zm2k_apply_values() {
	id=$1
	src=$2
	name=$3
	tcp=$4
	quic=$5
	mode=$6
	[ -f "$ZM2K_CONF" ] || return 1
	[ -z "$tcp" ] && return 1
	case "$mode" in
		all) modeval='$MODE_ALL' ;;
		list) modeval='$MODE_LIST' ;;
		*) modeval='' ;;
	esac

	zm2k_conf_backup_once
	cp -f "$ZM2K_CONF" "${ZM2K_CONF}.zm2k.bak" 2>/dev/null

	zm2k_conf_set_strategy "$tcp" "$quic" "$modeval" || return 1

	tmp="${ZM2K_CONF}.tmp.$$"
	{
		grep -v '^# ZM2K_APPLIED=' "$ZM2K_CONF"
		printf '# ZM2K_APPLIED=%s|%s|%s|%s\n' "$id" "$src" "$name" "$(date '+%Y-%m-%d %H:%M:%S')"
	} > "$tmp" && mv -f "$tmp" "$ZM2K_CONF"
	chmod 644 "$ZM2K_CONF" 2>/dev/null
	zm2k_candidates_mark_current "$tcp" "$quic"

	if zm2k_restart; then
		return 0
	fi

	[ -f "${ZM2K_CONF}.zm2k.bak" ] && cp -f "${ZM2K_CONF}.zm2k.bak" "$ZM2K_CONF"
	zm2k_restart >/dev/null 2>&1
	return 2
}

zm2k_apply_candidate() {
	id=$1
	mode=$2
	line=$(zm2k_candidates_cached | awk -F'|' -v id="$id" '$1 == id { print; exit }')
	[ -z "$line" ] && return 1
	oldifs=$IFS
	IFS='|'
	set -- $line
	IFS=$oldifs
	zm2k_apply_values "$1" "$2" "$3" "$4" "$5" "$mode"
}

zm2k_restore_original() {
	[ -f "$ZM2K_CONF.zm2k.orig" ] || return 1
	cp -f "$ZM2K_CONF.zm2k.orig" "$ZM2K_CONF"
	chmod 644 "$ZM2K_CONF" 2>/dev/null
	# Restoring is rare (end of autotest); drop the cache so it is rebuilt.
	zm2k_candidates_invalidate
	zm2k_restart
}

# ------------------------------------------------------------------- testing
zm2k_test_sites() {
	s_outfile=$1
	[ -f "$ZM2K_SITES" ] || return 1
	: > "$s_outfile"
	s_total=0
	while IFS='|' read -r s_name s_url s_weight; do
		case "$s_name" in ''|'#'*) continue ;; esac
		[ -z "$s_url" ] && continue
		s_total=$((s_total + 1))
	done < "$ZM2K_SITES"
	printf 'TEST|start|%s\n' "$s_total" >> "$s_outfile"
	s_started=$(date +%s)
	s_pids=""
	while IFS='|' read -r s_name s_url s_weight; do
		case "$s_name" in ''|'#'*) continue ;; esac
		[ -z "$s_url" ] && continue
		[ -z "$s_weight" ] && s_weight=1
		(
			zm2k_test_one "$s_name" "$s_url" "$s_weight" >> "$s_outfile"
		) &
		s_pids="$s_pids $!"
	done < "$ZM2K_SITES"
	for p in $s_pids; do
		wait "$p" 2>/dev/null || true
	done
	s_ended=$(date +%s)
	printf 'TEST|end|%s\n' "$((s_ended - s_started))" >> "$s_outfile"
	return 0
}

zm2k_test_one() {
	name=$1
	url=$2
	weight=$3
	scheme=${url%%://*}
	domain=${url#*://}
	domain=${domain%%/*}
	domain=${domain%%:*}
	port=443
	[ "$scheme" = "http" ] && port=80

	resolve=""
	if command -v dig >/dev/null 2>&1; then
		ip=$(dig +short +time=2 +tries=1 A "$domain" 2>/dev/null |
			grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
		[ -n "$ip" ] && resolve="--resolve $domain:$port:$ip"
	fi

	errfile=$(mktemp /tmp/zm2k_curl.XXXXXX 2>/dev/null) || errfile=""
	[ -z "$errfile" ] && errfile="/tmp/zm2k_curl.$$.${name##*/}"
	if res=$(curl -4 -L -sS -o /dev/null \
		--connect-timeout 4 --max-time 8 \
		-A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' \
		$resolve -w '%{http_code}|%{time_total}|%{size_download}' "$url" 2>"$errfile"); then
		rc=0
	else
		rc=$?
	fi
	code=$(printf '%s' "$res" | cut -d'|' -f1)
	tsec=$(printf '%s' "$res" | cut -d'|' -f2)
	size=$(printf '%s' "$res" | cut -d'|' -f3)
	[ -z "$code" ] && code=000
	[ -z "$tsec" ] && tsec=0
	[ -z "$size" ] && size=0
	ms=$(awk -v t="$tsec" 'BEGIN { printf "%d", t * 1000 }')

	ok=0
	if [ "$rc" = 0 ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ] 2>/dev/null; then
		ok=1
	fi
	err=$(tr '\n' ' ' < "$errfile" 2>/dev/null | tr '|' '/' | cut -c1-160)
	rm -f "$errfile"
	printf 'SITE|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$ok" "$code" "$ms" "$size" "$weight" "$err"
}

zm2k_score_file() {
	file=$1
	awk -F'|' '
		$1 == "SITE" {
			total++
			if ($3 == 1) { passed++; score += $7; ms += $5 }
		}
		END {
			if (total == 0) total = 1
			avg = passed ? int(ms / passed) : 0
			printf "%d|%d|%d|%d\n", score, passed, total, avg
		}
	' "$file" 2>/dev/null
}
