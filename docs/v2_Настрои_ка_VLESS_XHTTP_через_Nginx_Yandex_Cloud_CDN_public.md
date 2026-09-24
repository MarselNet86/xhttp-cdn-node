
Архитектура: `Клиент → Yandex Cloud CDN → Nginx (443, TLS) → Xray (127.0.0.1:8003, XHTTP, без TLS)`

Один сервер (без отдельной exit/relay-ноды). Xray сам выходит в интернет через `freedom`.

> **Ключевой вывод всей настройки:** Shadowsocks-2022 и обычный WebSocket плохо/не работают через CDN (WS требует отдельного включения через тикет в поддержку Яндекса). Рабочий вариант — **VLESS + XHTTP в режиме `packet-up` с `uplinkHTTPMethod: "GET"`**. POST/OPTIONS как uplink-метод НЕ поддерживаются Xray-core — только `POST` (default), `PUT`, `GET` (для packet-up). CDN ничего специально включать не нужно: GET и так в списке разрешённых методов по умолчанию — это подтвердилось на практике и с Yandex Cloud CDN, и с VK Cloud/MegaFon CDN.

> **v2: главное новое знание.** Даже при идеально настроенном сервере CDN-провайдер может блокировать домен целиком по внешним причинам (см. раздел 6.5) — это не чинится конфигом. План должен с самого начала включать быструю смену домена как штатную процедуру, а не как аварийный план Б.

---

## 0. Что подготовить заранее

| Значение | Пример | Где взять |
|---|---|---|
| Домен origin | `your-domain.example` | уже есть |
| Домен для CDN | `cdn.your-domain.example` | поддомен, привязывается в панели CDN |
| IP сервера | `203.0.113.10` | `curl -4 ifconfig.me` |
| UUID клиента | `00000000-0000-0000-0000-000000000000` | `cat /proc/sys/kernel/random/uuid` |
| Путь XHTTP | `/your-path` | любой, главное — совпадает везде |
| Xray-сервис | нативный systemd **или** 3x-ui | см. раздел 3 — оба варианта рабочие, разница только в том, кто пишет `config.json` |

---

## 1. DNS

```
your-domain.example        A      203.0.113.10
cdn.your-domain.example    CNAME  <выдаст CDN после создания/привязки ресурса>
```

Сертификат для origin (`your-domain.example`) выпускается любым способом (certbot standalone/webroot, acme.sh, вручную) — **важно фактически знать, куда он лёг** (`ls -la`), а не предполагать по шаблону. В этой настройке сертификат физически оказался в нестандартном месте (`/root/cert/your-domain.example/`), а не в стандартном certbot-пути (`/etc/letsencrypt/live/...`) — всегда сверяйте пути в `ssl_certificate`/`ssl_certificate_key` с реальным расположением файлов, иначе получите `cannot load certificate: No such file or directory`.

Для `cdn.your-domain.example` сертификат отдельно выпускается в **Yandex Certificate Manager** (см. раздел 4) — это второй, независимый от origin сертификат.

---

## 2. Nginx (origin-сервер)

TLS терминируется **только здесь**. Xray за ним работает по обычному HTTP, без TLS.

`/etc/nginx/sites-available/your-domain.example`:

```nginx
server {
    listen 443 ssl http2;
    server_name your-domain.example cdn.your-domain.example;

    ssl_certificate     /root/cert/your-domain.example/fullchain.pem;
    ssl_certificate_key /root/cert/your-domain.example/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 0;
    client_header_buffer_size 64k;
    large_client_header_buffers 8 128k;

    location = /cdn-check {
        add_header X-CDN-Origin "ok" always;
        add_header X-Origin-Method $request_method always;
        return 204;
    }

    location /your-path {
        proxy_pass http://127.0.0.1:8003;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_pass_request_headers on;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        return 403;
    }
}
```

```bash
ln -sfn /etc/nginx/sites-available/your-domain.example /etc/nginx/sites-enabled/your-domain.example
rm -f /etc/nginx/sites-enabled/default   # см. пункт ниже — обязательно
nginx -t
systemctl reload nginx
```

### Что изменилось в v2 и почему (реальные баги из практики)

- ❌ **Убрана строка `proxy_method $xhttp_proxy_method;`.** Такой переменной в чистом nginx не существует — она появляется только если где-то объявлен `map`-блок, вычисляющий её. Без него nginx либо падает на "unknown variable", либо (незаметнее и хуже) переменная становится пустой строкой, и на бэкенд улетает пустой HTTP-метод вместо `GET` — весь xhttp packet-up ломается молча. Просто не используйте эту директиву: без неё nginx проксирует метод как есть.
- ❌ **Убраны `http2_max_field_size` / `http2_max_header_size`.** Обе директивы устарели, nginx выдаёт warning и просит использовать `large_client_header_buffers` (она уже есть в конфиге и покрывает ту же задачу).
- ✅ **Добавлен `location = /cdn-check`.** Это не опция, а обязательный диагностический эндпоинт — единственный надёжный способ отличить "проблема в CDN" от "проблема в xhttp-парсинге конкретного пути". Голый xhttp-путь (`/your-path/...`) без сгенерированного клиентом session-id всегда даёт `400`, что маскирует реальные проблемы уровня TLS/CDN/маршрутизации. `/cdn-check` — простой `204` с кастомными заголовками, который либо проходит целиком, либо нет — без шума xhttp-протокола.
- ✅ **Обязательно удалить `sites-enabled/default`.** Дефолтный сайт nginx может перехватывать запросы без корректного SNI или мешать при multi-domain конфигурации (несколько `server_name` на одном 443) — убирайте сразу при установке, не только когда что-то не работает.
- **`listen 443 ssl http2;` vs `listen 443 ssl; http2 on;`** — на практике оба варианта отработали без warning'ов после удаления `http2_max_*`-директив. Разница синтаксиса между версиями nginx не оказалась критичной в этой связке — используйте любой, привязанный к вашей версии nginx (`nginx -v`).

---

## 3. Xray

Работает одинаково что через **3x-ui** (Custom inbound / JSON-редактирование), что через **нативный systemd-сервис** — разница только в том, кто физически пишет `/usr/local/etc/xray/config.json` (панель или вы руками). Логика конфига идентична.

```json
{
  "log": {
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 8003,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "ТВОЙ_UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/your-path",
          "mode": "packet-up",
          "uplinkHTTPMethod": "GET",
          "xPaddingKey": "dc",
          "xPaddingHeader": "X-Cache",
          "xPaddingMethod": "tokenish",
          "xPaddingObfsMode": true,
          "xPaddingPlacement": "queryInHeader"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
```

Проверка и рестарт:

```bash
systemctl restart xray   # или через кнопку в 3x-ui
ss -lntp | grep ':8003'  # должен слушать именно 127.0.0.1:8003, не 0.0.0.0
```

### Частые ошибки конфига (реально встреченные, не гипотетические)

- ❌ `"security": "tls"` внутри Xray-инбаунда, когда TLS уже терминирован на Nginx — Xray ждёт TLS-хендшейк, получает голый HTTP → `Client sent an HTTP request to an HTTPS server`.
- ❌ `"listen": "0.0.0.0"` или пустая строка — порт торчит наружу без TLS, дыра в безопасности и лёгкий фингерпринт для DPI. Всегда `"listen": "127.0.0.1"`, если TLS на Nginx.
- ❌ `"uplinkHTTPMethod": "OPTIONS"` — не существует такого варианта в Xray-core. Только `POST` (default), `PUT`, `GET` (для packet-up). OPTIONS даёт стабильный `400` на каждый uplink-запрос.
- ❌ Голый `curl /your-path` без session-id в пути — не валидный тест. XHTTP ожидает путь `/your-path/<session-id>`, который генерирует клиент. `400`/`404` на голый curl — это нормально, используйте `/cdn-check` для реальной проверки маршрута.

### Если всё же нужен TLS прямо в Xray (без Nginx впереди) — реальные грабли

Если архитектура меняется на `Клиент → CDN → Xray (TLS напрямую)`, без Nginx:

```json
"streamSettings": {
  "network": "xhttp",
  "security": "tls",
  "tlsSettings": {
    "certificates": [
      { "certificateFile": "/etc/xray-certs/fullchain.pem", "keyFile": "/etc/xray-certs/privkey.pem" }
    ],
    "minVersion": "1.2", "maxVersion": "1.3", "alpn": ["h2", "http/1.1"]
  },
  "xhttpSettings": { "...": "как выше" }
}
```

⚠️ **Обязательно скопируйте сертификаты в нейтральную директорию** (например `/etc/xray-certs/`), а не оставляйте в `/root/...`. Xray-сервис обычно работает от `User=nobody`, и даже если права на сам файл сертификата открыты (`644`), процесс всё равно не сможет до него достучаться, если родительская директория `/root` имеет `0700` — линуксовые права требуют `x` на каждую директорию по пути, а не только на конечный файл. Ошибка в логе в этом случае — `open /root/cert/.../fullchain.pem: permission denied`, что легко спутать с "неверный путь", хотя путь верный.

---

## 4. Yandex Cloud CDN

1. **Cloud CDN → Создать ресурс**
2. Источник: тип "Сервер", домен источника — `your-domain.example`
3. Протокол запросов к источнику: **HTTPS**
4. Доменное имя (клиентское): `cdn.your-domain.example`
5. Заголовок Host к источнику: **своё значение** → `your-domain.example`
6. Разрешённые методы: `GET, HEAD, OPTIONS` (дефолт — достаточно)
7. Кеширование — выключить полностью
8. Сертификат: **Yandex Certificate Manager**, выпустить отдельный Let's Encrypt-сертификат на `cdn.your-domain.example` через DNS-валидацию
9. **Важно (баг, реально встреченный): выпуск сертификата ≠ его применение.** После того как сертификат в Certificate Manager получил статус `ISSUED`, зайдите в настройки самого CDN-ресурса и **явно выберите этот сертификат** в поле SSL-сертификата. Без этого шага эдж продолжает отдавать общий wildcard-сертификат `*.yccdn.cloud.yandex.net`, а не ваш — клиент будет получать ошибку проверки хоста, при этом сам ресурс формально "рабочий".
10. После смены сертификата — пропагация по эдж-нодам может занимать от нескольких минут до ~30. Признак, что сертификат ещё не подхватился: в `curl -v` в поле `subject` виден `*.yccdn.cloud.yandex.net` вместо вашего домена.
11. После проверки — включить "Перенаправление клиентов: с HTTP на HTTPS"

**WebSocket отдельно включать не нужно** — весь смысл перехода на XHTTP в том, чтобы раскурить это требование.

---

## 5. Клиентская ссылка (Happ / v2rayNG / NekoBox)

```
vless://ТВОЙ_UUID@cdn.your-domain.example:443?encryption=none&extra=%7B%22mode%22%3A%22packet-up%22%2C%22uplinkHTTPMethod%22%3A%22GET%22%2C%22xPaddingKey%22%3A%22dc%22%2C%22xPaddingHeader%22%3A%22X-Cache%22%2C%22xPaddingMethod%22%3A%22tokenish%22%2C%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingPlacement%22%3A%22queryInHeader%22%7D&host=cdn.your-domain.example&mode=packet-up&path=%2Fyour-path&security=tls&sni=cdn.your-domain.example&type=xhttp&fp=chrome#Yandex-CDN-XHTTP
```

Резервный вариант — подключение напрямую к origin, минуя CDN:

```
vless://ТВОЙ_UUID@your-domain.example:443?encryption=none&extra=%7B%22mode%22%3A%22packet-up%22%2C%22uplinkHTTPMethod%22%3A%22GET%22%2C%22xPaddingKey%22%3A%22dc%22%2C%22xPaddingHeader%22%3A%22X-Cache%22%2C%22xPaddingMethod%22%3A%22tokenish%22%2C%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingPlacement%22%3A%22queryInHeader%22%7D&host=your-domain.example&mode=packet-up&path=%2Fyour-path&security=tls&sni=your-domain.example&type=xhttp&fp=chrome#Direct-Origin-XHTTP
```

⚠️ При прямом подключении клиент видит реальный IP сервера.

Важно: `extra`/JSON-настройки должны быть синхронны между сервером и клиентом — `mode`, `uplinkHTTPMethod`, `xPaddingKey` и т.д. должны совпадать один в один.

⚠️ **Про имя `xPaddingHeader: "X-Cache"`** — это стандартное имя, которое CDN-провайдеры сами используют для индикации HIT/MISS кеша. На практике конфликта не обнаружено (туннель заработал), но это рискованный выбор на будущее — если начнутся необъяснимые обрывы именно через CDN (а не напрямую), первое, что стоит проверить — смена имени на `X-Session-Data` синхронно на сервере и в клиенте.

---

## 6. Диагностика по слоям

Проверяй строго по порядку — снизу вверх.

### Слой 1 — жив ли Xray

```bash
ss -lntp | grep ':8003'
journalctl -u xray -n 50 --no-pager
```

### Слой 2 — Nginx → Xray, без CDN

```bash
curl -v https://your-domain.example/cdn-check
curl -v https://your-domain.example/your-path/test
```
`/cdn-check` → должен быть `204` с кастомными заголовками. `/your-path/test` → `400` с заголовком `x-cache: ?dc=...` — это нормальный ответ, означающий, что Xray получил запрос и вернул падинг.

### Слой 3 — реальное подключение клиента, live-лог

```bash
journalctl -u xray -f
```
Подключись клиентом в этот момент. Ищи `GET /your-path/<session-id>` с кодом `200` — значит сессия реально открылась (не просто TLS-хендшейк).

### Слой 4 — через CDN

```bash
curl -v https://cdn.your-domain.example/cdn-check
curl -v https://cdn.your-domain.example/your-path/test
```
Смотри внимательно на TLS-сертификат в выводе — `subject` должен быть вашим доменом, а не generic-сертификатом CDN (см. раздел 4, пункт 9). `504` = CDN не достучался до origin. `451` = см. раздел 6.5, это отдельная история, не техническая проблема конфига.

### Слой 5 — реальная сеть/маршрутизация

```bash
curl -o /dev/null -w "Connect: %{time_connect}s TTFB: %{time_starttransfer}s Total: %{time_total}s\n" https://your-domain.example/ -k --max-time 15
mtr -rw -c 50 your-domain.example
ping -c 30 your-domain.example
```

Признаки вмешательства провайдера/DPI, а не проблемы сервера: потери пакетов на промежуточных (не первом/последнем) хопах; хаотичный пинг на одном адресе; другие протоколы на этом же сервере тоже просели; тест с другой сети даёт другой результат.

### Слой 6 — CDN anti-abuse (throttling)

Резкий обрыв после всплеска трафика (много новых `/your-path/<uuid>` подряд) — возможен защитный throttling. Проверка: Cloud CDN → ресурс → Метрики → график 5xx-ответов.

---

## 6.5 НОВОЕ: Легальная блокировка домена CDN-провайдером (451)

Это реальный сценарий, встреченный на практике, и он принципиально отличается от всех технических слоёв выше — **тут нечего чинить в конфиге**.

### Как распознать

```bash
curl -v https://cdn.ВАШ_ДОМЕН/cdn-check
```

Если получаете `HTTP/2 451` (не `400`, не `504`, а именно `451`) — это **`451 Unavailable For Legal Reasons`**, официальный HTTP-код (RFC 7725) для блокировки по юридическим/регуляторным причинам, а не техническая ошибка.

Ключевой диагностический признак: сравните ответ на **нейтральный путь** (`/cdn-check`, не похожий на VPN-трафик) и на **xhttp-путь** (`/your-path/...`):

- Если `451` **на обоих** путях — блокировка **по домену целиком**.
- Если `451` **только** на xhttp-подобном пути — блокировка по паттерну/сигнатуре трафика.

### Почему это происходит (в контексте российских CDN)

Российские CDN-провайдеры (в этой практике встречено на VK Cloud/MegaFon CDN) юридически обязаны исполнять требования регулятора на своей инфраструктуре. Есть два разных механизма:

1. **Официальный реестр запрещённых сайтов** — публичный, проверяется на `eais.rkn.gov.ru` / `reestr.rublacklist.net`. Исторически обновлялся операторами ежедневно.
2. **Блокировка через ТСПУ** (технические средства противодействия угрозам, оборудование глубокого анализа пакетов в сетях операторов) — непубличная, может применяться напрямую и практически мгновенно, без записи в реестре и без предсказуемого "окна ожидания". Именно этот механизм наиболее вероятен для внезапной блокировки свежепривязанного поддомена.

**Практический вывод:** ждать, что "реестр обновится и всё заработает", в большинстве случаев бессмысленно — если сработал ТСПУ-детект, это не про реестр вообще.

### Что делать

1. Проверить домен в `eais.rkn.gov.ru` и `reestr.rublacklist.net` — если он там официально, смена поддомена не поможет, нужен новый домен целиком.
2. Если официально домен не значится — вероятна сигнатурная блокировка по паттерну/провайдеру. Рабочий способ раскура, подтверждённый на практике: **сменить сам домен** (включая CDN-поддомен) на не связанный по имени/истории с предыдущим — например, на случайно выглядящее имя на совершенно другом домене верхнего уровня, а не просто другой поддомен той же зоны.
3. **Держите под рукой готовую процедуру быстрой смены домена** (см. чек-лист ниже) — это оказалось быстрее и надёжнее, чем разбираться, какой конкретно механизм сработал.
4. Учтите: смена CDN-провайдера **внутри российской юрисдикции** (Yandex ↔ VK ↔ MegaFon) не гарантирует решения — все они одинаково обязаны исполнять одни и те же регуляторные требования на своей инфраструктуре. Устойчивое решение — CDN вне российской юрисдикции, если для вас это приемлемо и не противоречит целям использования.

### Чек-лист быстрой смены домена (проверенная процедура)

```bash
# 1. DNS нового домена должен смотреть прямо на origin (для standalone-выпуска)
dig +short НОВЫЙ_ДОМЕН
curl -4 ifconfig.me   # должны совпадать

# 2. Certbot (если ещё не установлен)
apt update && apt install -y certbot

# 3. Выпуск сертификата (standalone требует временной остановки nginx на 80/443)
systemctl stop nginx
certbot certonly --standalone -d НОВЫЙ_ДОМЕН \
  --agree-tos --register-unsafely-without-email --non-interactive
systemctl start nginx

# 4. Новый server-блок nginx — копия рабочего, только домен и пути к сертификату другие
# (см. раздел 2, ssl_certificate → /etc/letsencrypt/live/НОВЫЙ_ДОМЕН/...)

ln -sfn /etc/nginx/sites-available/НОВЫЙ_ДОМЕН /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 5. Тест напрямую на origin по новому домену
curl -v https://НОВЫЙ_ДОМЕН/cdn-check
curl -v https://НОВЫЙ_ДОМЕН/your-path/test
```

Дальше — привязать этот же домен к CDN-ресурсу (см. раздел 4) и повторить тесты уже через CDN.

Старый домен можно не удалять сразу — он продолжит числиться в `sites-enabled` как запасной, конфликтов на одном 443 через SNI нет.

---

## 7. Чек-лист безопасности

- [ ] Порт 8003 закрыт наружу (`listen: 127.0.0.1` в Xray, не открыт в файрволе)
- [ ] TLS только на Nginx, `security: none` в Xray (если используется штатная архитектура из разделов 2-3)
- [ ] На origin разрешены только нужные входящие порты: SSH, 80 (сертификаты), 443 (CDN/клиенты)
- [ ] Certbot настроен на автопродление + reload nginx после продления (`/etc/letsencrypt/renewal-hooks/deploy/`)
- [ ] `sites-enabled/default` удалён
- [ ] Реальные пути к сертификатам в конфиге nginx сверены с `ls -la`, а не взяты по шаблону/памяти
- [ ] Если сертификаты лежат вне стандартного certbot-пути (например, в `/root/...`) — владелец/права проверены (`root:root`, `644`/`600`), доступ у nginx (root-процесс) есть
- [ ] Certificate Manager CDN: сертификат не только `ISSUED`, но и явно выбран в настройках ресурса
- [ ] Домен и CDN-поддомен проверены на присутствие в `eais.rkn.gov.ru`/`reestr.rublacklist.net` перед серьёзным использованием
- [ ] Готова процедура быстрой смены домена (раздел 6.5) на случай легальной блокировки

---

## 8. Приложение: краткий журнал реальных инцидентов этой настройки

Для будущей отладки — что конкретно ломалось и как было опознано:

| Симптом | Диагноз | Как опознали |
|---|---|---|
| `400 Bad Request` на голый curl без session-id | Норма, не баг | Сверка с ожидаемым поведением XHTTP packet-up |
| `cannot load certificate: No such file or directory` (nginx) | Путь к сертификату не совпадает с реальным расположением файла | `ls -la` по реальному пути вместо пути "по шаблону" |
| `infra/conf: Failed to build TLS config` (Xray) без деталей | Неполный лог; развёрнутая причина — `permission denied` на чтение сертификата | `journalctl -u xray -n 60` целиком, не только последние строки |
| `permission denied` при чтении сертификата, хотя права на файл `644` | Родительская директория (`/root`, `0700`) блокирует traversal для непривилегированного юзера сервиса | Проверка прав не только на файл, но и на все директории по пути (`ls -ld`) |
| `The plain HTTP request was sent to HTTPS port` | Тест бил `http://` в порт, слушающий только TLS | Смена теста на `https://` |
| `HTTP/2 stream 1 reset by server (PROTOCOL_ERROR)` / `unexpected eof` через CDN | Дедикейтед сертификат в CDN ещё не выпущен/не привязан к ресурсу, эдж не готов принимать домен | Сверка `subject` сертификата в `curl -v`: был generic wildcard CDN, а не свой домен |
| `403 Forbidden` на корень `/` | Ожидаемое поведение — намеренный `location / { return 403; }` в конфиге, не баг | Сверка с самим конфигом nginx |
| `451 Unavailable For Legal Reasons` на всех путях через один конкретный CDN-провайдер, при этом origin напрямую отвечает нормально | Легальная блокировка домена на уровне CDN/оператора (см. раздел 6.5) | Тест нейтрального пути `/cdn-check` через CDN давал тот же `451`, что и xhttp-путь — значит блокировка по домену, не по конфигу |
