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
| `claude-credentials.json` | креды Claude, чтобы не логиниться в каждом контейнере |
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

---

## Обновление существующих контейнеров

```bash
ssh omv claude-dev-ctl retrofit dev-myproj
```

`retrofit` обновляет правила, ключи, токены и настройки. Новые инструменты из образа
приезжают только в **новые** контейнеры: существующий получит их после пересоздания
(`rm` без `--purge` + `deploy` — тома с кодом и логином переживут).

---

## Проверка (end-to-end)

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
