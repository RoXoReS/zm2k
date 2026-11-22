#!/bin/sh
# zm2k_autotest.sh - background worker: try every candidate, test sites, pick best.
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH

ZM2K_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$ZM2K_DIR/zm2k_lib.sh"

JOB=$ZM2K_JOB
mkdir -p "$JOB/sites" 2>/dev/null

set_state() { printf '%s\n' "$*" > "$JOB/state"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$JOB/log"; }

restored=0
cleanup() {
	if [ "$restored" = 0 ]; then
		restored=1
		if [ -f "$JOB/backup.conf" ]; then
			cp -f "$JOB/backup.conf" "$ZM2K_CONF" 2>/dev/null
			zm2k_restart >/dev/null 2>&1
		fi
	fi
	zm2k_lock_release
}
on_signal() {
	cancelled=1
	exit 143
}
trap cleanup 0
trap on_signal INT TERM

: > "$JOB/log"
: > "$JOB/results"
printf '%s\n' "$$" > "$JOB/pid"
set_state "running|0|0|init|||"

if [ ! -f "$ZM2K_CONF" ]; then
	set_state "error|0|0|no-conf|||"
	printf 'DONE|||||||0|0\n' > "$JOB/done"
	log "Не найден $ZM2K_CONF"
	restored=1
	exit 1
fi

cp -f "$ZM2K_CONF" "$JOB/backup.conf" 2>/dev/null
zm2k_conf_backup_once

zm2k_candidates_cached > "$JOB/all.candidates"
if [ -s "$JOB/ids" ]; then
	: > "$JOB/candidates"
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		id=${line%%|*}
		if grep -qx "$id" "$JOB/ids" 2>/dev/null; then
			printf '%s\n' "$line" >> "$JOB/candidates"
		fi
	done < "$JOB/all.candidates"
else
	cp -f "$JOB/all.candidates" "$JOB/candidates"
fi

total=$(grep -c . "$JOB/candidates" 2>/dev/null)
[ -z "$total" ] && total=0

if [ "$total" -eq 0 ]; then
	set_state "error|0|0|no-candidates|||"
	printf 'DONE|||||||0|0\n' > "$JOB/done"
	log "Нет конфигураций для проверки"
	restored=1
	exit 1
fi

log "Старт подбора: $total конфигураций"
idx=0
best_score=-1
best_passed=-1
best_avg=999999
best_id=""
best_name=""
best_src=""
cancelled=0

while IFS='|' read -r id src name tcp quic cur; do
	[ -z "$id" ] && continue
	[ -f "$JOB/cancel" ] && { cancelled=1; break; }

	idx=$((idx + 1))
	set_state "running|$idx|$total|apply|$id|$src|$name"
	log "[$idx/$total] применяю: $name ($src)"

	if zm2k_apply_values "$id" "$src" "$name" "$tcp" "$quic" all; then
		:
	else
		printf 'RESULT|%s|%s|%s|0|0|0|0|FAIL\n' "$id" "$src" "$name" >> "$JOB/results"
		log "[$idx/$total] не запустилось: $name"
		continue
	fi

	sleep 1
	[ -f "$JOB/cancel" ] && { cancelled=1; break; }

	sitefile="$JOB/sites/$id"
	: > "$sitefile"
	set_state "running|$idx|$total|test|$id|$src|$name"
	log "[$idx/$total] проверяю сайты: $name"

	zm2k_test_sites "$sitefile"

	summary=$(zm2k_score_file "$sitefile")
	score=$(printf '%s' "$summary" | cut -d'|' -f1)
	passed=$(printf '%s' "$summary" | cut -d'|' -f2)
	stotal=$(printf '%s' "$summary" | cut -d'|' -f3)
	avg=$(printf '%s' "$summary" | cut -d'|' -f4)
	[ -z "$score" ] && score=0
	[ -z "$passed" ] && passed=0
	[ -z "$stotal" ] && stotal=0
	[ -z "$avg" ] && avg=0

	status=FAIL
	[ "$passed" -gt 0 ] 2>/dev/null && status=PARTIAL
	[ "$passed" = "$stotal" ] 2>/dev/null && status=OK

	printf 'RESULT|%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$id" "$src" "$name" "$score" "$passed" "$stotal" "$avg" "$status" >> "$JOB/results"
	log "[$idx/$total] $name -> $passed/$stotal, score $score, ${avg}ms"

	if [ "$score" -gt "$best_score" ] 2>/dev/null ||
		{ [ "$score" -eq "$best_score" ] 2>/dev/null && [ "$passed" -gt "$best_passed" ] 2>/dev/null; } ||
		{ [ "$score" -eq "$best_score" ] 2>/dev/null && [ "$passed" -eq "$best_passed" ] 2>/dev/null && [ "$avg" -lt "$best_avg" ] 2>/dev/null; }; then
		best_score=$score
		best_passed=$passed
		best_avg=$avg
		best_id=$id
		best_name=$name
		best_src=$src
	fi
done < "$JOB/candidates"

applied=0
if [ "$cancelled" = 1 ]; then
	set_state "running|$idx|$total|restore|||"
	log "Отмена, возвращаю исходный конфиг"
	cp -f "$JOB/backup.conf" "$ZM2K_CONF" 2>/dev/null
	zm2k_restart >/dev/null 2>&1
	restored=1
elif [ -f "$JOB/apply_best" ] && [ -n "$best_id" ]; then
	set_state "running|$idx|$total|apply-best|$best_id|$best_src|$best_name"
	log "Применяю лучший конфиг: $best_name"
	final_mode=$(cat "$JOB/final_mode" 2>/dev/null)
	[ -z "$final_mode" ] && final_mode=all
	if zm2k_apply_candidate "$best_id" "$final_mode"; then
		applied=1
		restored=1
	else
		log "Не удалось применить лучший, возвращаю исходный"
		cp -f "$JOB/backup.conf" "$ZM2K_CONF" 2>/dev/null
		zm2k_restart >/dev/null 2>&1
		restored=1
	fi
else
	set_state "running|$idx|$total|restore|||"
	log "Возвращаю исходный конфиг"
	cp -f "$JOB/backup.conf" "$ZM2K_CONF" 2>/dev/null
	zm2k_restart >/dev/null 2>&1
	restored=1
fi

printf 'DONE|%s|%s|%s|%s|%s|%s|%s|%s\n' \
	"$best_id" "$best_score" "$best_passed" "$best_avg" "$best_name" "$best_src" "$applied" "$cancelled" > "$JOB/done"
set_state "done|$idx|$total|$([ "$cancelled" = 1 ] && echo cancelled || echo finished)|$best_id|$best_src|$best_name"
log "Готово. Лучший: ${best_name:-нет}"
