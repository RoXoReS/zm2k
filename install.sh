#!/bin/sh
# zm2k install.sh - install the zm2k web panel on Keenetic/Entware.
#
# What it does:
#   - copies the panel files to /opt/share/www/zm2k
#   - creates the lighttpd site config for port 9092
#   - snapshots nfqws.conf and its running state ONCE, before the first install
#   - keeps a manifest + backups in /opt/etc/zm2k-install for uninstall.sh
#
# It does NOT touch nfqws.conf, iptables, routes or Keenetic settings.
#
# Usage:
#   sh install.sh [-y] [--no-restart] [--web-dir DIR] [--port PORT]
#
# One command from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/RoXoReS/zm2k/main/install.sh | sh
#
# Environment overrides:
#   ZM2K_WEB_DIR, ZM2K_PORT, ZM2K_LIGHTTPD_CONF, ZM2K_ETC, ZM2K_CONF,
#   ZM2K_STATE_DIR, ZM2K_INIT

set -u

PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH
export PATH

SRC_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 1

# GitHub repository for the one-command install:
#   curl -fsSL https://raw.githubusercontent.com/RoXoReS/zm2k/main/install.sh | sh
ZM2K_REPO=${ZM2K_REPO:-RoXoReS/zm2k}
ZM2K_REF=${ZM2K_REF:-main}

WEB_DIR=${ZM2K_WEB_DIR:-/opt/share/www/zm2k}
PORT=${ZM2K_PORT:-9092}
LIGHTTPD_CONF=${ZM2K_LIGHTTPD_CONF:-/opt/etc/lighttpd/conf.d/92-zm2k.conf}
NFQWS_ETC=${ZM2K_ETC:-/opt/etc/nfqws}
NFQWS_CONF=${ZM2K_CONF:-$NFQWS_ETC/nfqws.conf}
STATE_DIR=${ZM2K_STATE_DIR:-/opt/etc/zm2k-install}
BACKUP_DIR=$STATE_DIR/backups

FILES="index.html app.js control.cgi zm2k_lib.sh zm2k_autotest.sh zm2k_rescue.sh flowseal.awk sites.list bins.map README.md"
DIRS="flowseal"

OPKG_REPO_CONF=${ZM2K_OPKG_REPO_CONF:-/opt/etc/opkg/nfqws-keenetic.conf}
NFQWS_PKG=${ZM2K_NFQWS_PKG:-nfqws-keenetic}
NFQWS_REPO_URL=https://nfqws.github.io/nfqws-keenetic/all

ASSUME_YES=0
NO_RESTART=0
WITH_NFQWS=0
NO_NFQWS=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'ВНИМАНИЕ: %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

download_file() {
	url=$1
	out=$2
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time 180 -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		return 1
	fi
}

# One-command mode: install.sh was piped from GitHub or downloaded alone, so the
# panel files are not next to it. Download the repository archive, show the URL,
# extract it and run the real installer from there.
bootstrap() {
	say "== zm2k: установка одной командой =="
	if [ -n "${ZM2K_TARBALL_URL:-}" ]; then
		urls=$ZM2K_TARBALL_URL
	else
		case "$ZM2K_REPO" in
			""|OWNER/REPO)
				die "репозиторий не указан: задай ZM2K_REPO=owner/repo"
				;;
			*/*/*)
				die "ZM2K_REPO должен быть в виде owner/repo, получено: $ZM2K_REPO"
				;;
			*/*) : ;;
			*)
				die "ZM2K_REPO должен быть в виде owner/repo, получено: $ZM2K_REPO"
				;;
		esac
		urls="https://github.com/$ZM2K_REPO/archive/refs/heads/$ZM2K_REF.tar.gz
https://codeload.github.com/$ZM2K_REPO/tar.gz/$ZM2K_REF"
	fi

	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		if command -v opkg >/dev/null 2>&1; then
			say "curl не найден — устанавливаю curl и ca-certificates..."
			opkg update >/dev/null 2>&1 || true
			opkg install ca-certificates curl >/dev/null 2>&1 || true
		fi
	fi
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
		|| die "нужен curl или wget (opkg install curl ca-certificates)"

	tmp=/tmp/zm2k-install.$$
	rm -rf "$tmp"
	mkdir -p "$tmp/src" || die "не удалось создать $tmp"
	trap 'rm -rf "$tmp"' 0
	trap 'rm -rf "$tmp"; exit 1' 1 2 15

	ok=0
	for u in $urls; do
		[ -n "$u" ] || continue
		say "Скачиваю: $u"
		if download_file "$u" "$tmp/repo.tar.gz" && [ -s "$tmp/repo.tar.gz" ]; then
			ok=1
			break
		fi
		warn "не удалось скачать: $u"
	done
	[ "$ok" = 1 ] || die "не удалось скачать архив репозитория"

	say "Распаковываю..."
	if ! tar -xzf "$tmp/repo.tar.gz" -C "$tmp/src" 2>/dev/null; then
		rm -rf "$tmp/src"
		mkdir -p "$tmp/src"
		gzip -dc "$tmp/repo.tar.gz" 2>/dev/null | tar -xf - -C "$tmp/src" 2>/dev/null \
			|| die "не удалось распаковать архив"
	fi

	src=""
	if [ -f "$tmp/src/install.sh" ]; then
		src=$tmp/src
	else
		for d in "$tmp/src"/*; do
			[ -d "$d" ] || continue
			if [ -f "$d/install.sh" ]; then
				src=$d
				break
			fi
		done
	fi
	[ -n "$src" ] || die "в архиве репозитория нет install.sh"

	say "Запускаю установщик..."
	ZM2K_BOOTSTRAPPED=1 sh "$src/install.sh" -y "$@"
}

if [ "${ZM2K_BOOTSTRAPPED:-0}" != 1 ] \
	&& { [ ! -f "$SRC_DIR/index.html" ] || [ ! -f "$SRC_DIR/zm2k_lib.sh" ] || [ ! -d "$SRC_DIR/flowseal" ]; }; then
	bootstrap "$@"
	exit $?
fi

usage() {
	cat <<'EOF'
Установка панели zm2k.

  sh install.sh [опции]

Опции:
  -y, --yes          не спрашивать подтверждение
  --with-nfqws       установить nfqws-keenetic с GitHub, если пакет ещё
                     не установлен
  --no-nfqws         не устанавливать nfqws-keenetic
  --no-restart       не перезапускать lighttpd
  --web-dir DIR      каталог панели (по умолчанию /opt/share/www/zm2k)
  --port PORT        порт lighttpd (по умолчанию 9092)
  -h, --help         эта справка

Без --with-nfqws/--no-nfqws установщик спросит, ставить ли nfqws-keenetic.
С -y отсутствующий nfqws-keenetic ставится автоматически.

Переменные окружения: ZM2K_WEB_DIR, ZM2K_PORT, ZM2K_LIGHTTPD_CONF,
ZM2K_ETC, ZM2K_CONF, ZM2K_STATE_DIR, ZM2K_INIT.
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
	if [ -n "${ZM2K_INIT:-}" ] && [ -x "$ZM2K_INIT" ]; then
		printf '%s\n' "$ZM2K_INIT"
		return 0
	fi
	for f in /opt/etc/init.d/S51nfqws /opt/etc/init.d/S51nfqws2; do
		[ -x "$f" ] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

pkg_installed() {
	command -v opkg >/dev/null 2>&1 || return 1
	opkg list-installed 2>/dev/null | awk -v p="$1" '$1 == p { found = 1 } END { exit !found }'
}

nfqws_installed() {
	# Any nfqws package from opkg (nfqws-keenetic, nfqws2-keenetic, ...).
	if command -v opkg >/dev/null 2>&1; then
		opkg list-installed 2>/dev/null \
			| awk '$1 ~ /^nfqws/ { found = 1 } END { exit !found }' && return 0
	fi
	# Binary in PATH or in the usual Entware locations.
	command -v nfqws >/dev/null 2>&1 && return 0
	command -v nfqws2 >/dev/null 2>&1 && return 0
	for f in /opt/bin/nfqws /opt/sbin/nfqws /opt/usr/bin/nfqws /opt/usr/sbin/nfqws \
		/opt/bin/nfqws2 /opt/sbin/nfqws2 /opt/usr/bin/nfqws2 /opt/usr/sbin/nfqws2; do
		[ -x "$f" ] && return 0
	done
	# Init script.
	for f in /opt/etc/init.d/S51nfqws /opt/etc/init.d/S51nfqws2; do
		[ -x "$f" ] && return 0
	done
	return 1
}

fetch_latest_nfqws_url() {
	json=$1
	download_file \
		"https://api.github.com/repos/nfqws/nfqws-keenetic/releases/latest" \
		"$json" || return 1
	tr ',' '\n' < "$json" \
		| sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*_all_entware\.ipk\)".*/\1/p' \
		| head -n 1
}

install_nfqws() {
	say ""
	say "Установка $NFQWS_PKG с GitHub..."
	command -v opkg >/dev/null 2>&1 || die "opkg не найден — это точно Entware?"

	# Dependencies for HTTPS downloads and package install.
	opkg update >/dev/null 2>&1 || warn "opkg update завершился с ошибкой"
	opkg install ca-certificates wget-ssl >/dev/null 2>&1 \
		|| warn "не удалось установить ca-certificates/wget-ssl"
	opkg remove wget-nossl >/dev/null 2>&1 || true

	json=/tmp/zm2k-nfqws-release-$$.json
	ipk=/tmp/zm2k-nfqws-$$.ipk
	url=""

	# One request to the GitHub API, then one download of the universal Entware package.
	url=$(fetch_latest_nfqws_url "$json" || true)
	rm -f "$json"

	if [ -n "$url" ]; then
		say "Пакет: $url"
		if download_file "$url" "$ipk"; then
			if opkg install "$ipk"; then
				rm -f "$ipk"
				add_nfqws_repo
				say "$NFQWS_PKG установлен."
				return 0
			fi
			warn "opkg install не смог установить скачанный пакет"
		else
			warn "не удалось скачать пакет с GitHub"
		fi
	else
		warn "не удалось получить ссылку на последний релиз GitHub"
	fi
	rm -f "$ipk"

	# Fallback: official opkg repository.
	say "Пробую официальный opkg-репозиторий..."
	add_nfqws_repo
	opkg update >/dev/null 2>&1 || die "opkg update не удался"
	opkg install "$NFQWS_PKG" || die "не удалось установить $NFQWS_PKG"
	say "$NFQWS_PKG установлен."
}

add_nfqws_repo() {
	mkdir -p "$(dirname "$OPKG_REPO_CONF")" 2>/dev/null || return 0
	if [ ! -f "$OPKG_REPO_CONF" ]; then
		printf 'src/gz nfqws-keenetic %s\n' "$NFQWS_REPO_URL" > "$OPKG_REPO_CONF" \
			|| { warn "не удалось записать $OPKG_REPO_CONF"; return 0; }
		printf '1\n' > "$STATE_DIR/nfqws.repo.added"
		say "Добавлен репозиторий для обновлений: $OPKG_REPO_CONF"
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		-y|--yes) ASSUME_YES=1 ;;
		--with-nfqws) WITH_NFQWS=1 ;;
		--no-nfqws) NO_NFQWS=1 ;;
		--no-restart) NO_RESTART=1 ;;
		--web-dir)
			shift
			[ $# -gt 0 ] || die "после --web-dir нужен каталог"
			WEB_DIR=$1
			;;
		--port)
			shift
			[ $# -gt 0 ] || die "после --port нужен номер порта"
			PORT=$1
			;;
		-h|--help) usage; exit 0 ;;
		*) die "неизвестная опция: $1 (см. --help)" ;;
	esac
	shift
done

[ "$WITH_NFQWS" = 1 ] && [ "$NO_NFQWS" = 1 ] && die "нельзя одновременно --with-nfqws и --no-nfqws"

[ "${ZM2K_ALLOW_NONROOT:-0}" = 1 ] || [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || die "запусти от root: ssh root@<IP-роутера>"

if [ "${ZM2K_SKIP_OPT_CHECK:-0}" != 1 ] && [ ! -d /opt ]; then
	die "каталог /opt не найден — сначала установи Entware"
fi

say "== zm2k installer =="
say "Каталог панели: $WEB_DIR"
say "Порт: $PORT"
say ""

# Source files.
for f in $FILES; do
	[ -f "$SRC_DIR/$f" ] || die "в каталоге установщика нет файла $f"
done
for d in $DIRS; do
	[ -d "$SRC_DIR/$d" ] || die "в каталоге установщика нет каталога $d"
done

# Dependencies (warn only).
missing=""
for c in awk sed grep curl nohup; do
	command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
[ -n "$missing" ] && warn "не найдены:$missing — установи через opkg (например: opkg install curl)"

# Refuse to silently move an existing installation to another directory.
mkdir -p "$STATE_DIR" "$BACKUP_DIR" || die "не удалось создать $STATE_DIR"
if [ -f "$STATE_DIR/state.conf" ]; then
	old_web=$(sed -n 's/^WEB_DIR=//p' "$STATE_DIR/state.conf" | head -n 1)
	if [ -n "$old_web" ] && [ "$old_web" != "$WEB_DIR" ]; then
		die "панель уже установлена в $old_web; используй --web-dir $old_web или сначала запусти uninstall.sh"
	fi
fi

ts=$(date +%Y%m%d-%H%M%S)

# Remember the original locations for uninstall.sh.
if [ ! -f "$STATE_DIR/state.conf" ]; then
	{
		printf 'WEB_DIR=%s\n' "$WEB_DIR"
		printf 'PORT=%s\n' "$PORT"
		printf 'LIGHTTPD_CONF=%s\n' "$LIGHTTPD_CONF"
		printf 'NFQWS_ETC=%s\n' "$NFQWS_ETC"
		printf 'NFQWS_CONF=%s\n' "$NFQWS_CONF"
		printf 'OPKG_REPO_CONF=%s\n' "$OPKG_REPO_CONF"
		printf 'NFQWS_PKG=%s\n' "$NFQWS_PKG"
	} > "$STATE_DIR/state.conf" || die "не удалось записать $STATE_DIR/state.conf"
fi

# Remember whether nfqws and its opkg repo existed before we touched them.
if [ ! -f "$STATE_DIR/nfqws.pkg.snapshot.done" ]; then
	if nfqws_installed; then
		printf '1\n' > "$STATE_DIR/nfqws.pkg.was_installed"
	else
		printf '0\n' > "$STATE_DIR/nfqws.pkg.was_installed"
	fi
	if [ -f "$OPKG_REPO_CONF" ]; then
		printf '1\n' > "$STATE_DIR/nfqws.repo.existed"
	else
		printf '0\n' > "$STATE_DIR/nfqws.repo.existed"
	fi
	: > "$STATE_DIR/nfqws.pkg.snapshot.done"
fi

# Snapshot the previous lighttpd site file and whether the web dir existed.
if [ ! -f "$STATE_DIR/lighttpd.conf.snapshot.done" ]; then
	if [ -f "$LIGHTTPD_CONF" ]; then
		cp -f "$LIGHTTPD_CONF" "$STATE_DIR/lighttpd.conf.preinstall" || die "не удалось сохранить $LIGHTTPD_CONF"
		printf '1\n' > "$STATE_DIR/lighttpd.conf.existed"
	else
		printf '0\n' > "$STATE_DIR/lighttpd.conf.existed"
	fi
	: > "$STATE_DIR/lighttpd.conf.snapshot.done"
fi
if [ ! -f "$STATE_DIR/webdir.existed" ]; then
	if [ -d "$WEB_DIR" ]; then
		printf '1\n' > "$STATE_DIR/webdir.existed"
	else
		printf '0\n' > "$STATE_DIR/webdir.existed"
	fi
fi

# Backup an existing panel before overwriting it.
if [ -d "$WEB_DIR" ]; then
	if tar -czf "$BACKUP_DIR/webdir-before-$ts.tar.gz" -C "$(dirname "$WEB_DIR")" "$(basename "$WEB_DIR")" 2>/dev/null; then
		say "Резервная копия старой панели: $BACKUP_DIR/webdir-before-$ts.tar.gz"
	else
		warn "не удалось сохранить резервную копию $WEB_DIR"
	fi
fi

confirm "Установить панель в $WEB_DIR?" || { say "Отменено."; exit 0; }

# Optionally install nfqws from GitHub. Skip if it is already present.
need_nfqws=0
if [ "$NO_NFQWS" = 1 ]; then
	say "nfqws не трогаю (--no-nfqws)."
elif nfqws_installed; then
	say "nfqws уже установлен — скачивание пропущено."
elif [ "$WITH_NFQWS" = 1 ] || [ "$ASSUME_YES" = 1 ]; then
	need_nfqws=1
elif [ -t 0 ]; then
	printf 'nfqws не установлен. Установить с GitHub? [Y/n]: '
	read -r ans || ans=""
	case "$ans" in
		n|N|no|NO) need_nfqws=0 ;;
		*) need_nfqws=1 ;;
	esac
fi

if [ "$need_nfqws" = 1 ]; then
	install_nfqws
elif ! nfqws_installed; then
	warn "nfqws не найден — панель сможет только читать статус."
	warn "Установи вручную: opkg install $NFQWS_PKG"
	warn "Репозиторий: $NFQWS_REPO_URL"
fi

# Snapshot nfqws.conf and its running state after the optional nfqws install,
# so "uninstall.sh --panel-only" restores exactly the pre-panel state.
if [ ! -f "$STATE_DIR/nfqws.snapshot.done" ]; then
	if [ -f "$NFQWS_CONF" ]; then
		cp -f "$NFQWS_CONF" "$STATE_DIR/nfqws.conf.preinstall" || die "не удалось сохранить снимок nfqws.conf"
		printf '1\n' > "$STATE_DIR/nfqws.conf.existed"
	else
		printf '0\n' > "$STATE_DIR/nfqws.conf.existed"
	fi
	if pidof nfqws >/dev/null 2>&1; then
		printf '1\n' > "$STATE_DIR/nfqws.was_running"
	else
		printf '0\n' > "$STATE_DIR/nfqws.was_running"
	fi
	init=$(find_init || true)
	[ -n "$init" ] && printf '%s\n' "$init" > "$STATE_DIR/nfqws.init"
	: > "$STATE_DIR/nfqws.snapshot.done"
	say "Снимок nfqws.conf: $STATE_DIR/nfqws.conf.preinstall"
fi

mkdir -p "$WEB_DIR" || die "не удалось создать $WEB_DIR"
for f in $FILES; do
	cp -f "$SRC_DIR/$f" "$WEB_DIR/$f" || die "не удалось скопировать $f"
done
for d in $DIRS; do
	rm -rf "$WEB_DIR/$d"
	cp -R "$SRC_DIR/$d" "$WEB_DIR/$d" || die "не удалось скопировать каталог $d"
done
chmod +x "$WEB_DIR/control.cgi" "$WEB_DIR"/*.sh 2>/dev/null || true

# Manifest for uninstall.sh.
{
	for f in $FILES; do printf '%s\n' "$f"; done
	for d in $DIRS; do printf '%s/\n' "$d"; done
} > "$STATE_DIR/manifest" || die "не удалось записать manifest"

# lighttpd site config.
mkdir -p "$(dirname "$LIGHTTPD_CONF")" || die "не удалось создать каталог для $LIGHTTPD_CONF"
{
	printf '$SERVER["socket"] == ":%s" {\n' "$PORT"
	printf '    server.document-root = "%s/"\n' "$WEB_DIR"
	printf '    server.modules += ( "mod_cgi" )\n'
	printf '    cgi.assign = ( ".cgi" => "/bin/sh" )\n'
	printf '    index-file.names = ( "index.html" )\n'
	printf '}\n'
} > "$LIGHTTPD_CONF" || die "не удалось записать $LIGHTTPD_CONF"

LIGHTTPD_MAIN=/opt/etc/lighttpd/lighttpd.conf
if [ -f "$LIGHTTPD_MAIN" ] && ! grep -q 'conf\.d' "$LIGHTTPD_MAIN"; then
	warn "в $LIGHTTPD_MAIN нет include conf.d/*.conf"
	warn 'добавь строку: include "conf.d/*.conf"'
fi

# Keep the uninstaller on the router, outside the public web root.
if [ -f "$SRC_DIR/uninstall.sh" ]; then
	cp -f "$SRC_DIR/uninstall.sh" "$STATE_DIR/uninstall.sh" 2>/dev/null || true
	chmod +x "$STATE_DIR/uninstall.sh" 2>/dev/null || true
fi

restart_lighttpd() {
	[ "$NO_RESTART" = 1 ] && { say "Перезапуск lighttpd пропущен (--no-restart)."; return 0; }
	if [ -x /opt/etc/init.d/S80lighttpd ]; then
		if /opt/etc/init.d/S80lighttpd restart >/dev/null 2>&1; then
			say "lighttpd перезапущен"
			return 0
		fi
		warn "S80lighttpd restart завершился с ошибкой"
		return 1
	fi
	if pidof lighttpd >/dev/null 2>&1 && command -v killall >/dev/null 2>&1; then
		if killall -HUP lighttpd 2>/dev/null; then
			say "lighttpd перезагружен (HUP)"
			return 0
		fi
	fi
	warn "не удалось перезапустить lighttpd — сделай это вручную"
	return 1
}
restart_lighttpd || true

say ""
say "Готово."
say "Панель: http://<IP-роутера>:$PORT/"
say "Файлы:  $WEB_DIR"
say "Снимок nfqws.conf: $STATE_DIR/nfqws.conf.preinstall"
say "Удаление: sh $STATE_DIR/uninstall.sh"
say ""
say "Если панель отдаёт 403 — проверь cgi.assign в lighttpd.conf."
