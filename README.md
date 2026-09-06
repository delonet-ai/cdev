# cdev — Claude Code в dev-контейнерах на домашнем сервере

Кит для запуска агентов Claude Code в изолированных контейнерах на сервере
(OMV + Docker + [Arcane](https://github.com/getarcaneapp/arcane)). Сессия живёт на
сервере — к ней подключаешься с любого устройства в LAN, ноутбук не привязан.

**Модель работы:** UI на Mac (терминальная панель `cdev`, VS Code Remote-SSH или просто
`ssh`) подключается к контейнеру, где Claude Code работает рядом с кодом. UI локальный,
агент и файлы — в контейнере. Сессия в `tmux` переживает отключение Mac.

```
Mac (cdev / VS Code) ── ssh :22NN ──▶ dev-контейнер (sshd + claude + codex + ralphex)
                                            │
                                            ├── ssh omv ──────▶ OMV-хост (deployer)
                                            ├── docker ───────▶ тот же хост (DOCKER_HOST=ssh://)
                                            └── arcane ───────▶ Arcane API (проекты/стеки)
```

Prod и test живут **на хосте**, их тома в dev-контейнер не смонтированы. Агент может
до них дотянуться — осознанно, через `docker` / `ssh omv` / `arcane` — но не может
случайно наступить на них файловой операцией.

---

## Что внутри контейнера

Node 22, Python 3.11, git + `gh`, ripgrep/fd/jq/yq, docker CLI (смотрит на хост по SSH),
psql/sqlite3/redis-cli, shellcheck, tmux — и три агентских инструмента:

| Инструмент | Роль |
|---|---|
| `claude` | Claude Code — основной исполнитель |
| `ralphex` | автономное выполнение планов из `docs/plans/` |
| `codex` | внешний ревьюер: перечитывает то, что написал Claude |

Полный состав и обоснование каждой позиции — в [BASE-KIT.md](BASE-KIT.md).

---

## Файлы

| Файл | Назначение |
|------|------------|
| `Dockerfile` | образ `omv/claude-dev` |
| `entrypoint.sh` | стабильные host-ключи SSH, права на тома, запуск sshd |
| `arcane` | обёртка над Arcane API (в образе: `/usr/local/bin/arcane`) |
| `docker-compose.yml` | шаблон стека одного проекта |
| `tui/cdev` | терминальная панель на Mac |
| `tui/claude-dev-ctl` | управляющий скрипт на хосте |
| `CLAUDE.md.template` | правила, которые получает Claude в каждом контейнере |
| `codex-config.toml.template` | настройки codex как ревьюера |
| `ralphex-config.template` | настройки автономного цикла |
| `ssh_config.example` | блок для `~/.ssh/config` на Mac |
| `BASE-KIT.md` | состав контейнера и что засевается при создании |

---

## Установка

### 1. Собрать образ на хосте

```bash
scp Dockerfile entrypoint.sh arcane CLAUDE.md.template \
    codex-config.toml.template ralphex-config.template \
    omv:/root/claude-dev-build/
ssh omv 'cd /root/claude-dev-build && docker build -t omv/claude-dev:latest .'
```

Адрес сервера зашит дефолтом `192.168.0.100`. Другой хост — через build-arg:

```bash
docker build --build-arg OMV_HOST=10.0.0.5 -t omv/claude-dev:latest .
```

Версии `yq`, `ralphex` и `codex` по умолчанию берутся последние. Для воспроизводимой
сборки задавай теги явно: `--build-arg RALPHEX_VERSION=v0.9.0`.

### 2. Управляющий скрипт и ключи на хосте

```bash
scp tui/claude-dev-ctl omv:/usr/local/bin/claude-dev-ctl
ssh omv chmod +x /usr/local/bin/claude-dev-ctl
```

В `/root/claude-dev-build/` должны лежать (в git их нет и быть не должно):

| Файл | Что это |
|---|---|
| `mac_authorized_key` | публичный ключ Mac — вход в контейнеры |
| `keys/id_dev_to_omv` | приватный ключ контейнера на хост (пользователь `deployer`) |
| `keys/id_github` | ключ для `git clone/push` |
| `claude-credentials.json` | токен Claude, чтобы не логиниться в каждом контейнере |
| `claude-account.json` | опознание аккаунта Claude — вторая половина логина |
| `codex-auth.json` | креды codex (`~/.codex/auth.json`) |
| `arcane_container_token` | API-ключ Arcane (UI → Settings → API keys) |

Пользователь `deployer` на хосте — не root, но в группе `docker`:

```bash
sudo useradd -m -s /bin/bash deployer
sudo usermod -aG docker deployer
sudo install -d -m 700 -o deployer -g deployer /home/deployer/.ssh
sudo tee -a /home/deployer/.ssh/authorized_keys < keys/id_dev_to_omv.pub
sudo chown deployer:deployer /home/deployer/.ssh/authorized_keys
sudo chmod 600 /home/deployer/.ssh/authorized_keys
```

> Членство в группе `docker` равносильно root на хосте — это осознанный размен ради
> деплоя из контейнера. Ключ `id_dev_to_omv` соответственно и охраняй.

### 3. Панель на Mac

```bash
brew install fzf
install -m 755 tui/cdev /opt/homebrew/bin/cdev
ssh omv 'cat > /root/claude-dev-build/mac_authorized_key' < ~/.ssh/id_ed25519.pub
```

Нужен рабочий ssh-алиас `omv` в `~/.ssh/config` (см. `ssh_config.example`).

### 4. Первый контейнер

```bash
cdev              # Ctrl-N → имя проекта и порт
# или напрямую:
ssh omv claude-dev-ctl deploy myproj 2203
```

`deploy` кладёт compose-файл в каталог проектов Arcane и поднимает стек обычным
`docker compose` — контейнер и управляется штатно, и виден в UI Arcane. Туда же
засеваются ключи, креды Claude и codex, `CLAUDE.md` и скиллы.

Дальше — `Enter` в панели: `ssh` + `tmux new -A -s work` в `/workspace`.

---

## Авторизация Claude

Новый контейнер стартует уже залогиненным — логин переносится с хоста. Обновить мастер
после релогина:

```bash
ssh omv claude-dev-ctl save-creds dev-myproj
ssh omv claude-dev-ctl retrofit dev-другой
```

Логин — это **два** файла, и одного мало: токен в `~/.claude/.credentials.json` и
опознание аккаунта в `~/.claude.json`. Без второго Claude открывает вход, хотя валидный
токен лежит рядом, — и выглядит это как «креды не сработали». `save-creds` снимает обе
половины разом, `doctor` проверяет обе; опознание подмешивается в `~/.claude.json`, не
трогая остального — `machineID` и доверенные каталоги там про конкретную машину.

> Лимит одновременных сессий Max/Pro никуда не девается: один аккаунт на несколько
> контейнеров означает несколько сессий под ним.

---

## Авторизация codex

`codex` — внешний ревьюер в цикле `ralphex`. Он авторизуется отдельно от Claude,
подпиской ChatGPT:

```bash
ssh omv-dev-myproj        # или Enter в панели cdev
codex login               # откроет URL device-flow

# сохранить креды на хост и разложить по остальным контейнерам:
exit
ssh omv claude-dev-ctl save-codex-auth dev-myproj
ssh omv claude-dev-ctl retrofit dev-другой
```

`cdev` показывает состояние авторизации в превью (`Ревьюер: codex авторизован`) —
удобно проверить до того, как запускать ночной автономный прогон.

Без авторизации `ralphex` спотыкается на фазе внешнего ревью. Отключать её (`codex_enabled
= false` в `~/.config/ralphex/config`) можно, но тогда код проверяет та же модель, что его
писала, — сигнал заметно слабее.

### Про песочницу ревьюера

По умолчанию кит ставит `codex_sandbox = danger-full-access`. Чтобы подтвердить
замечание, ревьюеру нужно запустить тесты, а под `read-only` он может только читать диф —
и ревью вырождается в вычитку. Настоящая граница здесь не песочница, а сам контейнер: в
нём и так работает Claude Code с `--dangerously-skip-permissions`.

Чем это **не** ограничено, стоит держать в голове: в контейнере лежат ssh-ключ на хост и
`DOCKER_HOST`, смотрящий на прод. Их держат правила в `CLAUDE.md`, а не настройка codex.
Хочешь строже — поставь `read-only` и будь готов, что часть замечаний останется
непроверенными гипотезами.

---

## Обновление существующих контейнеров

```bash
ssh omv claude-dev-ctl retrofit dev-myproj
ssh omv claude-dev-ctl retrofit dev-myproj --force   # ещё и настройки codex/ralphex
```

`retrofit` обновляет правила, ключи и токены. Настройки codex и ralphex и его креды он
намеренно **не** трогает: в настройках живут решения пользователя (доверенные каталоги,
песочница), а токен в контейнере обновляется сам и бывает свежее мастера на хосте.
Перезаписать осознанно — флагом `--force`.

Новые инструменты из образа приезжают только в **новые** контейнеры: существующий
получит их после пересоздания (`rm` без `--purge` + `deploy` — тома с кодом, логином и
авторизацией codex переживут).

---

## Пересоздание контейнера

Через UI Arcane пересобрать контейнер **нельзя, пока он не стал проектом Arcane**.
Контейнеры, оставшиеся от Portainer, — сироты: их compose-файл жил в томе Portainer и
исчез вместе с ним, так что ни Arcane, ни `docker compose` про них ничего не знают.
Первое пересоздание делает `claude-dev-ctl`, дальше проект появляется в Arcane и
кнопки в UI (и `arcane redeploy`) начинают работать.

```bash
ssh omv 'claude-dev-ctl rm dev-myproj && claude-dev-ctl deploy myproj 2222'
```

`rm` без `--purge` тома не трогает, `deploy` переиспользует их по именам
(`dev-myproj_myproj-code` и далее): код, логин Claude, авторизация codex, настройки
ralphex и ключи на месте. Перед удалением `rm` снимает ещё и `~/.claude.json` в
`/root/claude-dev-build/state/` — этот файл лежит в `$HOME`, куда не смонтирован ни один
том, а в нём отметка «этому каталогу доверяю»; `deploy` кладёт его обратно, иначе Claude
при первом запуске снова спросит про папку.

> **Контейнеры, созданные до этого кита**, держат `~/.codex` и `~/.config` в слое
> контейнера, а не в томе, — там авторизация codex и настройки ralphex, и они пропадут.
> Сначала сними их:
>
> ```bash
> ssh omv claude-dev-ctl save-codex-auth dev-myproj
> ssh omv 'docker cp dev-myproj:/home/dev/.config /root/claude-dev-build/backup-dev-myproj-config'
> ```

При первом пересоздании compose может написать `Volume "…" exists but doesn't match
configuration in compose file. Recreate (data will be lost)?` — это про метку
`config-hash`, которую проставил прежний менеджер стеков. `claude-dev-ctl` отвечает
«нет» за тебя (закрытый stdin), данные остаются на месте. Если запускаешь `docker
compose` руками — не ответь на этот вопрос «y».

Дальше проект `dev-myproj` виден в Arcane, и обычный цикл — уже через него:

```bash
arcane projects              # из dev-контейнера
arcane redeploy dev-myproj   # или кнопка Redeploy в UI
```

> Новый образ подхватывается именно на этом шаге: `docker compose up` берёт
> `omv/claude-dev:latest`, поэтому сначала пересобери образ, потом пересоздавай.

---

## Проверка

```bash
ssh omv claude-dev-ctl doctor              # хост + все контейнеры
ssh omv claude-dev-ctl doctor dev-myproj   # один контейнер
```

`doctor` отвечает на вопрос «всё ли на месте, чтобы работать»: на хосте — образ, ключи,
мастер-логины (с датами: логин, который не обновлялся месяц, помечается проблемой),
токен Arcane, шаблоны, каталог проектов; в контейнере — инструменты, оба логина,
настройки и связность наружу (`ssh omv`, docker до сервера, Arcane API, ключ GitHub).
Ненулевой код возврата при любой находке — можно вешать в cron перед ночным прогоном.

Проверок связности тут больше, чем кажется нужным, ровно потому, что контейнер выглядит
здоровым до первой команды наружу: логины на месте, а `git push` упирается в `publickey
denied` или `docker ps` — в `Host key verification failed`.

Секреты через вывод не проходят: из файлов логина печатаются только тип подписки, срок
токена и дата обновления.

### Ручная проверка (end-to-end)

1. **Живучесть:** `ssh omv-dev-myproj`, `tmux new -A -s work`, `claude`, закрыть крышку
   Mac, зайти снова — сессия и контекст на месте.
2. **Персист авторизации:** `docker restart dev-myproj` → `claude` и `codex` залогинены.
3. **Изоляция:** `docker inspect dev-myproj` — среди Mounts нет томов prod/test.
4. **Доступ к серверу:** из контейнера `ssh omv docker ps` показывает контейнеры,
   `arcane projects` — проекты.
5. **Ревью:** `codex --version` внутри контейнера и `ralphex` на тестовом плане доходит
   до фазы external review без ошибок авторизации.

---

## Безопасность

- `dev` — не root; sshd только по ключам, пароли и root-вход выключены (`AllowUsers dev`).
  Настройки лежат в `/etc/ssh/sshd_config.d/`, а не в хвосте `sshd_config`: у sshd
  выигрывает первое вхождение директивы, и дописанное в конец молча проигрывает.
- На хосте отдельный `deployer`, не root (но в группе `docker` — см. оговорку выше).
- Тома dev не пересекаются с томами prod/test.
- Наружу в интернет ничего не открыто (только LAN). Работать вне дома — через
  Tailscale/WireGuard, а не пробросом портов на роутере.
- Приватные ключи и креды — только на хосте и в томах, вне git (см. `.gitignore`).
- Интерактивный вход стартует в `/workspace`, а не в `$HOME`: в домашнем каталоге лежат
  ключи и токены, которым нечего делать в рабочем контексте агента.

---

## Лицензия

MIT — см. [LICENSE](LICENSE).
