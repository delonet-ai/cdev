# cdev — панель dev-контейнеров Claude Code (TUI)

Лёгкая терминальная панель на Mac для управления dev-контейнерами на OMV.

```
Mac:  cdev  ──ssh omv──▶  /usr/local/bin/claude-dev-ctl  ──▶ docker compose / Arcane
```

Тонкий клиент на fzf. Вся логика и секреты (ключи, креды, Arcane-токен) — на хосте, на Mac ничего не хранится.

## Запуск

```bash
cdev
```

## Горячие клавиши

| Клавиша | Действие |
|---|---|
| `↑`/`↓` | выбрать контейнер |
| `Enter` | подключиться (ssh + `tmux new -A -s work`) |
| `Ctrl-N` | развернуть новый контейнер (спросит имя и порт) |
| `Ctrl-U` | залить папку/файл с Mac в `/workspace` (rsync) |
| `Ctrl-D` | удалить (спросит: только контейнер / вместе с томами) |
| `Ctrl-T` | показать токены в превью (best-effort из транскриптов) |
| `Ctrl-R` | обновить список |
| `Esc` | выход |

Справа — живое превью: статус, агенты (процессы `claude` + CPU), git-проекты в `/workspace` (ветка, изменения, ↑коммиты), авторизация codex, ресурсы, строка SSH.

Метка `▶` рядом с числом агентов в списке = агент грузит CPU (работает).

## Компоненты

| Файл | Где | Назначение |
|---|---|---|
| `cdev` | Mac (`/opt/homebrew/bin/cdev` → сюда) | fzf-обёртка |
| `claude-dev-ctl` | OMV (`/usr/local/bin/`) | list / doctor / inspect / port / deploy / rm / retrofit / save-*-creds |

`claude-dev-ctl` напрямую:
```bash
ssh omv claude-dev-ctl list
ssh omv claude-dev-ctl doctor                       # всё ли на месте: хост + все контейнеры
ssh omv claude-dev-ctl doctor dev-projectA          # только один контейнер
ssh omv claude-dev-ctl inspect dev-projectA --tokens
ssh omv claude-dev-ctl deploy myproj 2202
ssh omv claude-dev-ctl rm dev-myproj [--purge]
ssh omv claude-dev-ctl retrofit dev-projectA        # обновить правила, ключи, токены
ssh omv claude-dev-ctl retrofit dev-projectA --force # ещё и настройки/креды codex и ralphex
ssh omv claude-dev-ctl save-creds dev-projectA      # мастер-креды Claude с этого контейнера
ssh omv claude-dev-ctl save-codex-auth dev-projectA # мастер-креды codex (после codex login)
```

`deploy` пишет compose-файл в каталог проектов Arcane и поднимает стек через
`docker compose`: контейнер управляется штатным инструментом и при этом виден в UI.
Каталог определяется автоматически (`docker volume inspect arcane_arcane-data`),
переопределяется переменной `ARCANE_PROJECTS_DIR`.

## Как определяются dev-контейнеры

По label `claude.dev.managed=true` (ставится при `deploy`) или по имени `dev-*`.

## Установка на другом Mac

1. `brew install fzf` (или бинарник с github releases в `~/.local/bin`).
2. Настроить ssh-алиас `omv` в `~/.ssh/config` (ключ доступа к хосту).
3. Скопировать `cdev`, `chmod +x`, положить в PATH.
4. Сохранить публичный ключ Mac на хост для будущих `deploy`:
   `ssh omv 'cat > /root/claude-dev-build/mac_authorized_key' < ~/.ssh/id_ed25519.pub`
