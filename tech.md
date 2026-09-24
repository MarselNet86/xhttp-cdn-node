# tech.md — ядро проекта cdn-deploy

**Версия: v2**

Единственный источник истины. Меняется только append-only и только тимлидом (mars). Каждое изменение контракта (`.env`, контракты модулей, целевая конфигурация, exit-коды) бампает версию.

## Changelog

- **v2** — xhttp-конфиги вынесены в `remnawave/` как отдельные версионируемые файлы для ручного копирования в панель (скрипт xray на ноде не пишет). Добавлен модуль `lib/remnawave.sh` (рендер шаблонов из `.env` в `out/remnawave/` + печать инструкций). Контракт `.env` не изменён: рендер использует уже существующие `CDN_DOMAIN`, `XHTTP_PATH`, `XHTTP_PORT`.
- **v1** — исходное ядро. Зафиксированы дефолтные решения:
  - целевая ОС: Ubuntu 22.04 / 24.04 (первичная), Debian 12 (вторичная);
  - нода: xray работает в docker-контейнере `remnawave-node`, конфиг пушится панелью Remnawave, скрипт его НЕ трогает;
  - выпуск сертификатов: DNS-01 через Cloudflare API (первичный режим), HTTP-01 webroot (фолбэк для vless+hy2);
  - формат подписки для чекера: base64-список URI (первичный), sing-box / xray-json (фолбэк);
  - целевые значения тюнинга против 503 (раздел «Целевая конфигурация») заморожены как контракт шаблонов.

Переопределение любого пункта: бамп версии + строка в changelog.

---

## 1. Проект

**Что делает.** Разворачивает CDN-фронтинг обвязку на VPN-ноде одной командой: ставит и конфигурирует nginx как reverse proxy перед локальным xhttp-портом xray, выпускает и продлевает TLS-сертификаты для vless / hysteria2 / cdn, применяет сетевой тюнинг ядра и nginx против 503 под нагрузкой. Отдельно: чекер доступности всех серверов из подписки Remnawave.

**Для кого.** Соло-оператор VPN-сервиса на связке Remnawave panel + node. Оператор клонирует репозиторий и запускает скрипт: скрипт сам опрашивает параметры и выполняет всю установку.

**Цель.**
- `git clone && ./deploy.sh` : интерактивный опрос параметров, затем полная идемпотентная установка.
- `./check.sh <sub-url>` : проверка CDN, vless, hysteria2 и остальных серверов подписки.

**Что скрипт НЕ делает.** Не пишет и не перезаписывает конфиг xray на ноде (это зона панели Remnawave). Не управляет edge-сертификатом CDN на стороне Timeweb (его выпускает и продлевает Timeweb). Скрипт готовит origin-сторону: nginx, сертификаты origin, тюнинг, реновейшн.

---

## 2. Стек

- **Язык:** bash 4+ (ассоциативные массивы). POSIX-совместимость где не мешает читаемости.
- **Рантайм-зависимости (системные, доустанавливаются скриптом):** `nginx`, `certbot` + `python3-certbot-dns-cloudflare`, `curl`, `jq`, `openssl`, `coreutils`. Для чекера: `xray` (уже присутствует на ноде).
- **Подстановка в шаблонах:** `envsubst` (пакет `gettext-base`).
- **Тесты:** `bats-core` (юнит), `shellcheck` (линт).
- **Целевая ОС:** Ubuntu 22.04 / 24.04. Вторичная: Debian 12. Различия дистрибутивов инкапсулируются в `lib/common.sh` (детект + пакетный менеджер).

---

## 3. Архитектура

### Поток трафика (то, что настраивает скрипт)

```
Клиент --VLESS+xHTTP(TLS,443)--> Timeweb CDN edge --HTTPS--> origin nginx :8444 --HTTP--> xray 127.0.0.1:4443 (xhttp packet-up)
Клиент --VLESS Reality(TCP,443)------------------------------------------------> xray :443 (steal www.swiss.com)
Клиент --Hysteria2(UDP,443)---------------------------------------------------> xray :443 (реальный TLS-серт hy2-домена)
```

TLS для CDN-плеча терминируется на origin nginx (:8444). Xray за nginx работает по HTTP без TLS. Reality не использует LE-серт (крадёт TLS цели). Hysteria2 использует реальный LE-серт своего домена.

### Границы ответственности

| Компонент | Кто владеет | Скрипт |
|---|---|---|
| origin nginx (reverse proxy :8444) | скрипт | создаёт, тюнит, релоадит |
| origin TLS-серты (vless, hy2, cdn) | скрипт | выпускает + реновейшн-хук |
| сетевой тюнинг ядра / лимиты | скрипт | применяет |
| xray config на ноде | панель Remnawave | не трогает |
| edge-серт CDN | Timeweb | не трогает |
| xhttp-инбаунд (сервер) + `extra` хоста (клиент) | версионируются в `remnawave/`, оператор копирует в панель вручную | рендерит заполненные версии из `.env` в `out/remnawave/`, печатает инструкции |

### Структура репозитория

```
cdn-deploy/
├── tech.md                      # это ядро
├── CLAUDE.md                    # авто-подгрузка ядра в сессию
├── README.md                    # запуск для оператора
├── .env.example                 # контракт конфигурации (см. раздел 4)
├── deploy.sh                    # энтрипоинт установки
├── check.sh                     # энтрипоинт чекера (standalone)
├── lib/
│   ├── common.sh                # логгер, гарды, детект ОС, валидаторы, env-загрузка
│   ├── prompt.sh                # интерактивный сбор + валидация ввода -> .env
│   ├── certs.sh                 # выпуск сертификатов + deploy-hook реновейшна
│   ├── nginx.sh                 # рендер шаблонов + nginx -t + reload
│   ├── sysctl.sh                # сетевой тюнинг ядра + лимиты nofile
│   ├── remnawave.sh             # рендер xhttp-конфигов из .env в out/ + инструкции по ручному вводу
│   └── validate.sh              # послойная проверка после установки
├── remnawave/                   # конфиги для РУЧНОГО ввода в панель (xray на ноде управляется панелью)
│   ├── README.md                # что куда в панели + синхронизация + тюнинг-заметки
│   ├── inbound-xhttp-cdn.json.tmpl   # серверный VLESS-XHTTP-CDN инбаунд (тюненные буферы)
│   └── host-xhttp-extra.json         # клиентский extra-блок хоста (чистый xmux)
├── templates/
│   ├── nginx.conf.tmpl          # main-конфиг (events/http тюнинг)
│   ├── site-8444.conf.tmpl      # server-блок CDN-плеча (upstream + location)
│   ├── acme-http.conf.tmpl      # временный :80 server для HTTP-01 фолбэка
│   └── sysctl-99-cdn.conf       # статичный (envsubst не нужен)
└── tests/
    ├── prompt.bats
    ├── certs.bats
    ├── check.bats
    └── fixtures/                # примеры подписок для парсер-тестов
```

`deploy.sh` — тонкий оркестратор: source `lib/*.sh`, порядок вызовов, ничего доменного внутри. Вся логика в модулях.

---

## 4. Контракт `.env` (замороженный)

`prompt.sh` собирает эти переменные и пишет `.env`. Остальные модули читают `.env` через `env::load`. Порядок опроса = порядок таблицы. Значения без дефолта спрашиваются всегда.

| Переменная | Обязательна | Дефолт | Валидация | Назначение |
|---|---|---|---|---|
| `VLESS_DOMAIN` | да | — | FQDN, пропуск запрещён | серт для origin nginx :8444 + домен прямого подключения vless |
| `HY2_DOMAIN` | да | — | FQDN, пропуск запрещён | реальный серт инбаунда hysteria2 |
| `CDN_DOMAIN` | да | — | FQDN, пропуск запрещён | `server_name` origin + host xhttp + цель чекера |
| `ORIGIN_IP` | да | автодетект `curl -4 ifconfig.me`, подтверждение | IPv4 | источник для CDN-ресурса, sanity в валидации |
| `XHTTP_PORT` | нет | `4443` | port 1-65535 | локальный порт xray xhttp inbound |
| `XHTTP_PATH` | нет | `/api/v2.jpg/` | начинается с `/`, заканчивается `/` | путь xhttp, синхронен с сервером и клиентом |
| `NGINX_TLS_PORT` | нет | `8444` | port | порт origin nginx для edge CDN |
| `UUID` | нет | генерация `cat /proc/sys/kernel/random/uuid` | UUIDv4 | id клиента vless |
| `CERT_MODE` | нет | `dns-cloudflare` | `dns-cloudflare` \| `http-01` | режим выпуска сертификатов |
| `CF_API_TOKEN` | если `CERT_MODE=dns-cloudflare` | — | непустой | токен Cloudflare scope `Zone:DNS:Edit` на зону |
| `LE_EMAIL` | нет | пусто (`--register-unsafely-without-email`) | email или пусто | контакт Let's Encrypt |
| `NODE_RELOAD_CMD` | нет | `docker restart remnawave-node` | непустая команда | перезапуск ноды в deploy-hook для подхвата серта hy2 |
| `ISSUE_CDN_ORIGIN_CERT` | нет | `true` | `true` \| `false` | выпускать ли origin-серт для CDN-домена (иначе :8444 переиспользует серт vless) |

Правила:
- три домена (`VLESS_DOMAIN`, `HY2_DOMAIN`, `CDN_DOMAIN`) обязательны и не пропускаются: пустой ввод повторяет вопрос.
- при `CERT_MODE=http-01` CDN-домен через HTTP-01 не валидируется (CNAME на CDN): в этом режиме `ISSUE_CDN_ORIGIN_CERT` форсится в `false`, origin :8444 берёт серт vless, cdn-серт остаётся на стороне Timeweb.
- повторный запуск: существующий `.env` подхватывается, значения предлагаются как дефолты.

---

## 5. Контракты модулей

Соглашение об именовании: `module::function`. Все модули начинаются с `set -euo pipefail`. Ни один модуль не пишет в stdout ничего кроме данных, предназначенных пользователю; логи идут через логгер в stderr.

### lib/common.sh (базовый, source-ится первым)

- `log::info MSG` / `log::warn MSG` / `log::error MSG` — в stderr, с префиксом уровня.
- `log::die CODE MSG` — `log::error` + `exit CODE`.
- `require::root` — exit 4 если не root.
- `require::cmd NAME` — exit 3 если команды нет.
- `require::distro` — детект ОС, exit 5 если не поддерживается, экспорт `PKG_INSTALL`.
- `env::load PATH` — загрузка `.env`.
- `env::require VAR...` — exit 2 если переменная пуста.
- `is::fqdn S` / `is::ipv4 S` / `is::port S` — возвращают 0/1.
- `confirm PROMPT` — интерактивный yes/no, возвращает 0/1.

### lib/prompt.sh

- `prompt::collect` — интерактивный опрос по контракту раздела 4, валидация каждого поля, генерация UUID, автодетект IP, запись `.env` (chmod 600). Идемпотентно: читает существующий `.env` как дефолты.

### lib/certs.sh

- `certs::issue` — выпуск для трёх доменов согласно `CERT_MODE`. Идемпотентно: пропуск домена, если валидный серт существует и до истечения > 30 дней. Exit 6 при провале.
- `certs::install_renew_hook` — пишет `/etc/letsencrypt/renewal-hooks/deploy/cdn-deploy.sh`: `nginx -s reload` + `NODE_RELOAD_CMD`. chmod 755.

### lib/nginx.sh

- `nginx::render` — `envsubst` шаблонов из `templates/` в `/etc/nginx/`, симлинк в `sites-enabled`, удаление `sites-enabled/default`, `nginx -t`, reload. Exit 7 при провале `nginx -t` (конфиг не применяется, старый остаётся живым).

### lib/sysctl.sh

- `sysctl::apply` — копирует `templates/sysctl-99-cdn.conf` в `/etc/sysctl.d/`, `sysctl --system`, выставляет `nofile` лимиты (systemd drop-in для nginx + `/etc/security/limits.d/`).

### lib/remnawave.sh

- `remnawave::emit` — `envsubst` шаблона `remnawave/inbound-xhttp-cdn.json.tmpl` в `out/remnawave/inbound-xhttp-cdn.json` (подстановка `CDN_DOMAIN`, `XHTTP_PATH`, `XHTTP_PORT`), копия `remnawave/host-xhttp-extra.json` в `out/remnawave/`. Печатает пути и инструкцию: какой файл в какое поле панели вставить (см. `remnawave/README.md`). Валидирует результат `jq -e . >/dev/null` (синтаксис JSON). Ничего в систему не пишет и на ноду не пушит: вывод только для ручного копирования.

### lib/validate.sh

- `validate::layers` — послойная проверка снизу вверх: (1) xray слушает `127.0.0.1:XHTTP_PORT`; (2) `curl` origin `/cdn-check` -> 204; (3) `curl` origin `XHTTP_PATH`test -> 400 с падинг-хедером; (4) через CDN `/cdn-check` -> 204 и серт `subject` = домен. Exit 8 при провале, с указанием слоя.

### check.sh (standalone)

- `check::fetch SUB_URL` — забор подписки, base64-декод, парсинг URI в записи `proto|addr|port|sni|host|path|params`. Фолбэк на sing-box / xray-json.
- `check::probe_fast REC` — L7-классификация: для xhttp/cdn `curl` по пути и разбор кода (204 / 400+падинг = ок; 504 = origin недостижим; 451 = легальная блокировка; 503 = перегруз); для reality/hy2 TLS/UDP-реачабилити.
- `check::probe_tunnel REC` — генерит минимальный xray-конфиг с этим сервером как outbound + локальный socks на эфемерном порту, поднимает xray, `curl --socks5` до `http://www.gstatic.com/generate_204`, таймаут, классификация (204 = туннель несёт трафик), замер латентности, тир-даун.
- `check::report` — таблица (имя, протокол, эндпоинт, результат, латентность), ненулевой exit при любом FAIL.

---

## 6. Целевая конфигурация (контракт шаблонов, замороженный)

Шаблоны обязаны воспроизводить эти значения. Они выведены из диагностики 503 и эталонного рабочего конфига Timeweb.

### nginx main (`nginx.conf.tmpl`, events/http)

```nginx
worker_processes auto;
worker_rlimit_nofile 65535;
events { worker_connections 16384; multi_accept on; }
```

### nginx upstream + server (`site-8444.conf.tmpl`)

```nginx
upstream xray_xhttp {
    server 127.0.0.1:${XHTTP_PORT};
    keepalive 512;
    keepalive_requests 100000;
    keepalive_timeout 300s;
}
# listen ${NGINX_TLS_PORT} ssl backlog=4096;
# location = /cdn-check  -> add_header X-CDN-Origin ok; return 204;
# location XHTTP_PATH     -> proxy_pass http://xray_xhttp; buffering off; read/send timeout 3600s; Connection "";
# location /              -> заглушка-selfsteal или return 403
```

### sysctl (`sysctl-99-cdn.conf`)

```ini
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

### xhttp-конфиги (файлы в `remnawave/`, оператор копирует в панель вручную)

Полные блоки закреплены как файлы, не печатаются в stdout. Скрипт (`remnawave::emit`) рендерит заполненные версии в `out/remnawave/`.

- **`remnawave/host-xhttp-extra.json` (клиент, поле `extra` хоста):** `xmux` только `{ "hKeepAlivePeriod": 15, "hMaxReusableSecs": "1800-3000" }`, без `maxConcurrency`, `hMaxRequestTimes`, `cMaxReuseTimes` (амплифицируют нагрузку соединениями). `scMaxEachPostBytes: 60000`.
- **`remnawave/inbound-xhttp-cdn.json.tmpl` (сервер, инбаунд на ноде):** `scMaxBufferedPosts: 256` (было 64), `scMaxEachPostBytes: 60000` (было 6000), `serverMaxHeaderBytes: 32768`. Плейсхолдеры `${CDN_DOMAIN}`, `${XHTTP_PATH}`, `${XHTTP_PORT}`.

Инварианты (детали в `remnawave/README.md`): обфускационные поля (`seqKey`, `xPaddingKey`, `xPaddingHeader`, `xPadding*`, `sessionID*`, `uplink*`, `serverMaxHeaderBytes`) синхронны один-в-один между инбаундом и хостом. `scMaxEachPostBytes` — CDN-чувствительный knob: поднимать осторожно, откатывать первым при обрывах через CDN; клиент не больше серверного лимита. Порядок внедрения: сначала только `xmux`, затем буферы.

Уникальность DPI-сигнатуры per-нода (рандомизация обфускационных полей) — кандидат в v3, расширяет контракт `.env`, подтвердить у тимлида.

---

## 7. Стратегия тестов

Тесты выводятся из критериев приёмки задачи, не из реализации. Зелёный тест кодирует контракт, а не зеркалит код.

Обязательно на каждый слайс:
- **shellcheck** без ошибок на всех `.sh` (линт-гейт).
- **bats-юниты на чистые функции:** валидаторы (`is::fqdn`, `is::ipv4`, `is::port`), парсер подписки (фикстура -> ожидаемый набор записей), рендер шаблона (env -> ожидаемый вывод).
- **Тест идемпотентности** на каждую операцию, меняющую состояние: прогон дважды с тем же вводом даёт тот же результат, второй прогон не ломает рабочее состояние.
- **Путь ошибки:** невалидный ввод отклоняется с нужным exit-кодом; провал `nginx -t` не применяет конфиг; провал certbot не роняет уже рабочий nginx.
- **`--dry-run`** у `deploy.sh`: печатает планируемые действия без изменения системы, покрывается тестом.

Парсер подписки в чекере — самое ценное на контракт: фикстуры в `tests/fixtures/` (base64, sing-box, xray-json) -> ассерт распарсенных серверов.

---

## 8. Владение инфраструктурой

- **Шаблоны — источник истины для конфигов.** Конфиги на сервере не правятся руками, только через `templates/` + `nginx::render`. Ручная правка на сервере затирается следующим прогоном (это ожидаемо).
- **Идемпотентность обязательна.** Каждая операция проверяет текущее состояние перед действием. Destructive-шаги (удаление `sites-enabled/default`) явно логируются.
- **Сертификаты:** пути `/etc/letsencrypt/live/<DOMAIN>/`. Реновейшн через certbot-таймер + deploy-hook (reload nginx + `NODE_RELOAD_CMD`).
- **`.env.example`** — единственная точка описания конфигурации, синхронна с разделом 4. Реальный `.env` в `.gitignore`, chmod 600 (содержит CF-токен).

---

## 9. Конвенции кода

- `set -euo pipefail` в каждом исполняемом скрипте и модуле.
- Функции в неймспейсе `module::function`. Глобальные переменные из `.env` в UPPER_CASE, локальные через `local`.
- Никаких хардкод-значений: всё в `.env` или дефолтах контракта.
- Кавычки по shellcheck: `"$var"`, `"${arr[@]}"`. Скрипт проходит shellcheck без подавлений (исключения только с инлайн-обоснованием).
- Гард-клозы в начале: root, дистрибутив, зависимости.
- Логи структурированы (info/warn/error) в stderr. Сообщения об ошибках actionable: что произошло и что делать.
- Функция делает одно. Оркестрация в `deploy.sh` / `check.sh`, доменная логика в модулях.

---

## 10. Конвенция коммитов, PR, комментариев

Применяется каждой сессией.

- **Язык всего кода-фейсинга — только английский:** коммиты, заголовки и описания PR, комментарии в коде. (Проза `tech.md` и `README.md` — на русском.)
- **Формат коммита фиксированный, всегда** Conventional Commits: `type(scope): summary`. `type` из закрытого набора `feat|fix|test|refactor|chore|docs`. `summary` в императиве, со строчной, без точки, до ~50 символов. Тело только чтобы объяснить *почему*, не *что*.
- **Сессия коммитит сама по ходу работы**, маленькими логическими коммитами после каждого осмысленного шага. Не сваливать всё одним коммитом в конце. Каждый коммит по возможности проходит shellcheck.
- **Комментарии в коде** кратко и по делу, объясняют *почему*. Закомментированный код в коммит не попадает.
- **stop-slop на всю прозу:** активный залог, императив, конкретика вместо общих фраз, без филлеров, без em-dash в английских текстах.

### Git-идентичность (жёстко)

- Все коммиты от имени: **`mars <marsel.shamsutdinov@icloud.com>`**.
- В репозитории при инициализации: `git config user.name "mars"`, `git config user.email "marsel.shamsutdinov@icloud.com"` (локально).
- **Никаких** упоминаний Claude / ассистента: ни в авторе, ни в `Co-Authored-By`, ни в теле коммита, ни в строках вида «Generated with...». Контрибьютор один: mars.

---

## 11. Definition of Done одной задачи

- shellcheck чистый на затронутых файлах.
- bats-тесты проходят (выведены из критериев приёмки задачи).
- для каждой операции, меняющей состояние, проходит тест идемпотентности.
- `--dry-run` работает, если задача трогала `deploy.sh`.
- закоммичено по конвенции раздела 10 (английский, Conventional Commits, автор mars).

---

## 12. Дорожная карта по стадиям

Каждая стадия = один или несколько сфокусированных коммитов. Фичи не начинаются, пока скелет не готов.

- **Стадия 0 — скелет.** `lib/common.sh` (логгер, гарды, детект ОС, валидаторы, env), `.env.example`, каркас `deploy.sh` с `--dry-run`, `.gitignore`, shellcheck-прогон. Чек: shellcheck зелёный, `deploy.sh --dry-run` печатает план на пустом вводе.
- **Стадия 1 — сбор ввода.** `lib/prompt.sh` + `tests/prompt.bats`. Три обязательных домена, валидация, генерация UUID, автодетект IP, запись `.env` 600.
- **Стадия 2 — сертификаты.** `lib/certs.sh` (DNS-01 Cloudflare + HTTP-01 фолбэк + deploy-hook) + `tests/certs.bats`. Идемпотентность (пропуск валидных сертов).
- **Стадия 3 — nginx.** `lib/nginx.sh` + `templates/nginx.conf.tmpl` + `templates/site-8444.conf.tmpl`. Целевые значения раздела 6, `nginx -t` перед reload, удаление default.
- **Стадия 4 — сетевой тюнинг.** `lib/sysctl.sh` + `templates/sysctl-99-cdn.conf` + лимиты nofile.
- **Стадия 5 — валидация и xhttp-конфиги.** `lib/validate.sh` (послойная проверка) + `lib/remnawave.sh` (`remnawave::emit`: рендер `remnawave/*.tmpl` из `.env` в `out/remnawave/`, JSON-валидация `jq`, печать инструкций по ручному вводу в панель). Файлы `remnawave/inbound-xhttp-cdn.json.tmpl` и `remnawave/host-xhttp-extra.json` уже в репо.
- **Стадия 6 — чекер.** `check.sh` + `tests/check.bats` + фикстуры. Парсер подписки, fast + tunnel тиры, таблица, exit-код.
- **Стадия 7 — доводка.** `README.md` (запуск для оператора), end-to-end прогон на тестовой ноде.
