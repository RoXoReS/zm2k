# zm2k — панель управления zapret для Keenetic

Веб-панель для роутера Keenetic с Entware: показывает состояние zapret, собирает
готовые стратегии из Flowseal (`.bat`) и Bol-van (`#NFQWS_ARGS=` в `nfqws.conf`),
позволяет применить конфиг одной кнопкой, проверить доступность сайтов и запустить
автоподбор лучшей стратегии.

Работает на BusyBox `sh`, без Node.js, Python и внешних CDN. Интерфейс — один
`index.html` + `app.js`, backend — CGI на `sh`.

## Что входит

| Файл | Назначение |
|---|---|
| `index.html`, `app.js` | интерфейс панели |
| `control.cgi` | CGI-backend (текстовый протокол) |
| `zm2k_lib.sh` | общая логика: конфиг, кандидаты, тесты, lock |
| `zm2k_autotest.sh` | фоновый автоподбор конфигурации |
| `zm2k_rescue.sh` | аварийное восстановление по SSH |
| `install.sh` | установщик панели + опционально `nfqws-keenetic`; умеет ставиться одной командой с GitHub |
| `uninstall.sh` | удаление панели или панели вместе с `nfqws-keenetic` |
| `flowseal.awk` | разбор Flowseal `.bat` |
| `flowseal/` | пресеты Flowseal |
| `sites.list` | список проверяемых сайтов и веса |
| `bins.map` | сопоставление fake-файлов Flowseal с файлами роутера |
| `92-zm2k.conf` | пример конфига lighttpd на порт 9092 |

## Требования

- Keenetic/Netcraze с Entware.
- `lighttpd` с `mod_cgi`.
- `nfqws-keenetic` (пакет zapret для Keenetic).
- `curl` (для проверки сайтов), `awk`, `sed`, `grep`.
- Права на запись в `/opt/etc/nfqws` и на запуск `/opt/etc/init.d/S51nfqws`
  у пользователя, от которого работает lighttpd/CGI. На большинстве роутеров
  lighttpd запускается от root; если нет — панель сможет читать статус, но
  применение конфига и перезапуск не сработают.

## Установка одной командой

Выполни на роутере:

```sh
curl -fsSL https://raw.githubusercontent.com/RoXoReS/zm2k/main/install.sh | sh
```

`install.sh` выведет, что скачивает, заберёт архив репозитория с GitHub,
распакует его в `/tmp` и запустится оттуда в неинтерактивном режиме (`-y`).
Если `nfqws` ещё не установлен, он будет поставлен с GitHub. Если уже
установлен — скачивание пропускается.

Если используешь форк, задай репозиторий через `ZM2K_REPO`:

```sh
curl -fsSL https://raw.githubusercontent.com/RoXoReS/zm2k/main/install.sh \
  | ZM2K_REPO=owner/repo sh
```

Аргументы установщика передаются после `sh -s --`:

```sh
curl -fsSL .../install.sh | sh -s -- --no-nfqws
curl -fsSL .../install.sh | sh -s -- --port 9092
curl -fsSL .../install.sh | sh -s -- --web-dir /opt/share/www/zm2k
```

Ветка по умолчанию — `main`, другая задаётся через `ZM2K_REF`:

```sh
curl -fsSL .../install.sh | ZM2K_REF=master sh
```

Для интерактивной установки скачай файл и запусти его:

```sh
curl -fsSL https://raw.githubusercontent.com/RoXoReS/zm2k/main/install.sh -o /tmp/install.sh
sh /tmp/install.sh
```

## Установка из локальной копии

Скопируй репозиторий на роутер и запусти установщик:

```sh
cd /tmp/zm2k
sh install.sh
```

`install.sh`:

1. проверяет `/opt` и зависимости;
2. ставит `nfqws-keenetic` с GitHub (или из официального opkg-репозитория),
   если пакета ещё нет;
3. сохраняет снимок `nfqws.conf`, состояние службы и старую конфигурацию
   lighttpd в `/opt/etc/zm2k-install/`;
4. копирует панель в `/opt/share/www/zm2k`;
5. создаёт `/opt/etc/lighttpd/conf.d/92-zm2k.conf`;
6. перезапускает lighttpd.

Опции:

```sh
sh install.sh --with-nfqws     # поставить nfqws-keenetic, если его нет
sh install.sh --no-nfqws       # не трогать nfqws-keenetic
sh install.sh -y               # без вопросов (nfqws ставится, если отсутствует)
sh install.sh --web-dir DIR    # другой каталог панели
sh install.sh --port 9092      # другой порт
```

Без `--with-nfqws`/`--no-nfqws` установщик спросит, ставить ли `nfqws-keenetic`.

### Установка nfqws-keenetic вручную

Если ставишь zapret отдельно:

```sh
opkg update
opkg install ca-certificates wget-ssl
opkg remove wget-nossl

mkdir -p /opt/etc/opkg
echo "src/gz nfqws-keenetic https://nfqws.github.io/nfqws-keenetic/all" \
  > /opt/etc/opkg/nfqws-keenetic.conf

opkg update
opkg install nfqws-keenetic
```

Обновление и удаление пакета:

```sh
opkg update && opkg upgrade nfqws-keenetic
opkg remove --autoremove nfqws-keenetic
```

## Удаление

Интерактивное меню:

```sh
sh /opt/etc/zm2k-install/uninstall.sh
```

Варианты:

1. **Только веб-панель** — удаляет панель и сайт lighttpd, `nfqws-keenetic`
   оставляет, а `nfqws.conf` возвращает к снимку, сделанному при установке.
2. **Панель и nfqws-keenetic** — удаляет панель, пакет `nfqws-keenetic`
   (`opkg remove --autoremove`), его конфиг, init-скрипт и остатки файлов.
   Перед удалением создаётся архив в `/tmp/zm2k-nfqws-backup-*.tar.gz`.
3. **Отмена**.

Неинтерактивно:

```sh
sh uninstall.sh --panel-only -y
sh uninstall.sh --all -y
```

Полезные опции:

```sh
sh uninstall.sh --no-restart    # не перезапускать lighttpd/nfqws
sh uninstall.sh --purge-state   # удалить и служебный каталог с бэкапами
```

Служебный каталог `/opt/etc/zm2k-install/` хранит:

- `nfqws.conf.preinstall` — конфиг до установки панели;
- `nfqws.was_running` — была ли служба запущена;
- `manifest` — список установленных файлов;
- `backups/` — архивы панели и прежних конфигов;
- `uninstall.sh` — копию деинсталлятора.

## Установка вручную (без install.sh)

```sh
mkdir -p /opt/share/www/zm2k
cp index.html app.js control.cgi zm2k_lib.sh zm2k_autotest.sh zm2k_rescue.sh \
   flowseal.awk sites.list bins.map /opt/share/www/zm2k/
cp -r flowseal /opt/share/www/zm2k/
chmod +x /opt/share/www/zm2k/control.cgi /opt/share/www/zm2k/*.sh
```

Подключи сайт lighttpd. Скопируй `92-zm2k.conf` в каталог, который включён в
`lighttpd.conf` (обычно `/opt/etc/lighttpd/conf.d/`):

```sh
cp 92-zm2k.conf /opt/etc/lighttpd/conf.d/92-zm2k.conf
/opt/etc/init.d/S80lighttpd restart
```

Проверь, что в `lighttpd.conf` есть:

```conf
server.modules += ( "mod_cgi" )
cgi.assign = ( ".cgi" => "/bin/sh" )
```

Открой панель: `http://<IP-роутера>:9092/`.

> `92-zm2k.conf` слушает `:9092` на всех интерфейсах. Если роутер смотрит в
> интернет, ограничь доступ firewall-ом или привяжи сокет к LAN-адресу.
> У панели нет собственной авторизации.

## Пути по умолчанию

Их можно переопределить переменными окружения перед запуском CGI:

| Переменная | По умолчанию |
|---|---|
| `ZM2K_ETC` | `/opt/etc/nfqws` |
| `ZM2K_CONF` | `/opt/etc/nfqws/nfqws.conf` |
| `ZM2K_JOB` | `/tmp/zm2k_job` |
| `ZM2K_LOCK` | `/tmp/zm2k.lock` |
| `ZM2K_SITES` | `<каталог панели>/sites.list` |
| `ZM2K_FLOWSEAL` | `<каталог панели>/flowseal` |
| `ZM2K_INIT` | `/opt/etc/init.d/S51nfqws` (автопоиск) |

## Как пользоваться

1. **Статус** — запущен ли zapret, какой конфиг активен, режим (`MODE_ALL` /
   `MODE_LIST`).
2. **Конфигурации** — список кандидатов:
   - `Flowseal` — лучшие TCP/QUIC-правила из `.bat`;
   - `Bol-van` — закомментированные `#NFQWS_ARGS=`;
   - `Свои` — текущий конфиг.
   Кнопки: «Применить», «Применить и проверить», «Проверить сайты».
3. **Проверка сайтов** — параллельный `curl` по `sites.list`, результат по
   каждому сайту и общий балл.
4. **Автоподбор** — перебирает выбранные конфиги, тестирует сайты, выбирает
   лучший по сумме весов. В конце возвращает исходный конфиг или применяет
   лучший (галочка «Применить лучший»).
5. **Списки и файлы** — просмотр/редактирование `.list` и `.conf`.
6. **Логи** — последние строки журнала.

## Безопасность и восстановление

### Режим «только чтение» (необязательно)

По умолчанию панель полностью рабочая: применение конфигов, автоподбор и
сохранение файлов доступны, но каждое изменение требует нажатия кнопки и
подтверждения.

Если нужно временно запретить любые изменения (например, показать панель
кому-то или проверить чтение), включи:

```sh
export ZM2K_READONLY=1
```

Тогда применение, перезапуск, сохранение и автоподбор вернут `READONLY|...`,
а в шапке появится бейдж «Только чтение». Выключить обратно: `ZM2K_READONLY=0`.

### Что панель трогает, а что нет

**Пишет только:**

- `nfqws.conf` — при нажатии «Применить» / «Вернуть исходный», атомарно, с
  резервными копиями `.zm2k.orig` и `.zm2k.bak`;
- `.bak` рядом с файлом — при сохранении через редактор списков;
- `/tmp/zm2k_job`, `/tmp/zm2k.lock` — служебные файлы автоподбора.

**Не трогает:** iptables/nftables, маршруты, DNS, интерфейсы, конфиг Keenetic,
другие службы. Сетевые интерфейсы только читаются через `ip`/`ndmc`.

Перед первым применением панель создаёт резервные копии:

- `nfqws.conf.zm2k.orig` — самый первый исходный конфиг;
- `nfqws.conf.zm2k.bak` — конфиг перед последним применением.

Автоподбор держит свою копию в `/tmp/zm2k_job/backup.conf` и восстанавливает её
при отмене, ошибке или завершении, если не выбрано «применить лучший».

### Если пропал интернет

Панель доступна по LAN даже без интернета. Нажми **«Вернуть исходный»** или
выполни по SSH:

```sh
/opt/share/www/zm2k/zm2k_rescue.sh
```

Скрипт:

1. останавливает фоновый автоподбор;
2. восстанавливает `nfqws.conf` из `.zm2k.orig` / `.zm2k.bak` / backup автоподбора;
3. перезапускает zapret, а если не получается — останавливает его, чтобы
   обычный интернет работал без обхода DPI.

Ручной вариант:

```sh
# остановить автоподбор
kill "$(cat /tmp/zm2k.lock/pid 2>/dev/null)" 2>/dev/null
rm -rf /tmp/zm2k.lock

# вернуть конфиг
cp -f /opt/etc/nfqws/nfqws.conf.zm2k.orig /opt/etc/nfqws/nfqws.conf

# перезапустить
/opt/etc/init.d/S51nfqws restart
```

Если zapret не стартует, останови его — интернет без обхода DPI должен
восстановиться:

```sh
/opt/etc/init.d/S51nfqws stop
```

### Важно

- Применение конфига и автоподбор **перезапускают zapret** — связь может
  прерваться на несколько секунд.
- Не выключай питание во время применения: конфиг пишется через временный файл
  и атомарный `mv`, но автоподбор лучше не прерывать без необходимости.
- Автоподбор временно переключает стратегии. Если интернет критичен в этот
  момент, запускай его вручную и не закрывай вкладку до завершения.
- Панель не имеет авторизации. Не публикуй порт 9092 в интернет.

## Настройка

### Список сайтов

`sites.list`, формат:

```
# имя|url|вес
YouTube|https://www.youtube.com/|3
Discord|https://discord.com/|3
```

Вес влияет на выбор лучшего конфига. Проверка считается успешной при HTTP-коде
`200–499`; используется `curl` с таймаутами 4 с на соединение и 8 с на запрос.

### Fake-файлы Flowseal

Flowseal использует `%BIN%имя.bin`. Панель сначала ищет точный файл в
`/opt/etc/nfqws`, `/opt/etc/nfqws/bin`, `/opt/etc/nfqws/fake`,
`/opt/share/zapret/...`, затем — в `bins.map`. Если файла нет, правило с ним
отбрасывается.

`bins.map`:

```
flowseal_name.bin|/opt/etc/nfqws/реальный_файл.bin
```

### Кэш кандидатов

Список кандидатов кэшируется на 30 минут в `/tmp/zm2k_job/candidates.cache`.
Кнопка «Обновить» в блоке конфигураций пересобирает его принудительно.

## Диагностика

| Симптом | Что проверить |
|---|---|
| `403 Forbidden` | `control.cgi` не исполняемый или `cgi.assign` не настроен |
| `curl: not found` | установи `curl` в Entware (`opkg install curl`) |
| «flowseal не найден» | каталог `flowseal` не скопирован в `/opt/share/www/zm2k/` |
| Пустой список конфигов | нет `.bat` и нет `#NFQWS_ARGS=` в `nfqws.conf` |
| Применение возвращает ошибку | lighttpd/CGI не может писать в `/opt/etc/nfqws` или запускать init-скрипт |
| Автоподбор «dead» | процесс убит; запусти `zm2k_rescue.sh` и проверь лог `/tmp/zm2k_job/log` |

Проверка синтаксиса на роутере:

```sh
sh -n /opt/share/www/zm2k/control.cgi
sh -n /opt/share/www/zm2k/zm2k_lib.sh
sh -n /opt/share/www/zm2k/zm2k_autotest.sh
sh -n /opt/share/www/zm2k/zm2k_rescue.sh
```
