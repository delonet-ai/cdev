#!/usr/bin/env bash
# Запускается root'ом при старте контейнера:
#  1) держит host-ключи SSH на томе, чтобы Mac не ругался "host key changed" после пересоздания;
#  2) чинит владельца/права на /home/dev/.ssh;
#  3) запускает sshd в foreground (PID 1).
set -euo pipefail

SSH_DIR=/home/dev/.ssh
HOSTKEY_DIR="$SSH_DIR/host_keys"

mkdir -p "$HOSTKEY_DIR"

# Генерим стабильные host-ключи один раз, дальше они живут на томе.
if [ ! -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -f "$HOSTKEY_DIR/ssh_host_ed25519_key" -N "" < /dev/null
fi
if [ ! -f "$HOSTKEY_DIR/ssh_host_rsa_key" ]; then
  ssh-keygen -t rsa -b 4096 -f "$HOSTKEY_DIR/ssh_host_rsa_key" -N "" < /dev/null
fi

# Права на ssh-каталог dev-пользователя (том может прийти с чужим владельцем).
chown -R dev:dev "$SSH_DIR"
chmod 700 "$SSH_DIR"

# host-ключи держим под root: sshd работает root'ом и требует корректного владельца.
chown -R root:root "$HOSTKEY_DIR"
chmod 700 "$HOSTKEY_DIR"
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key

# .claude монтируется томом от root — отдаём dev, иначе Claude Code не сохранит логин.
CLAUDE_DIR=/home/dev/.claude
mkdir -p "$CLAUDE_DIR"
if [ "$(stat -c %U "$CLAUDE_DIR")" != "dev" ]; then
  chown -R dev:dev "$CLAUDE_DIR"
fi
chmod 700 "$CLAUDE_DIR"

# ~/.codex монтируется томом от root — отдаём dev, иначе codex не сохранит
# обновлённый токен и ревью в ralphex начнёт падать на протухшей авторизации.
CODEX_DIR=/home/dev/.codex
mkdir -p "$CODEX_DIR"
if [ "$(stat -c %U "$CODEX_DIR")" != "dev" ]; then
  chown -R dev:dev "$CODEX_DIR"
fi
chmod 700 "$CODEX_DIR"

# /workspace тоже приходит томом от root — без этого dev не может ни склонировать
# репозиторий, ни принять файлы по scp/rsync. Меняем владельца только у самой
# папки (без -R): на свежем томе она пуста, а на большом репозитории -R был бы дорог.
WS_DIR=/workspace
mkdir -p "$WS_DIR"
if [ "$(stat -c %U "$WS_DIR")" != "dev" ]; then
  chown dev:dev "$WS_DIR"
fi
if [ -f "$SSH_DIR/authorized_keys" ]; then
  chmod 600 "$SSH_DIR/authorized_keys"
else
  echo "WARNING: $SSH_DIR/authorized_keys отсутствует — с Mac зайти не получится." >&2
  echo "         Положи туда публичный ключ Mac (см. README, шаг 3)." >&2
fi

exec /usr/sbin/sshd -D -e \
  -o "HostKey=$HOSTKEY_DIR/ssh_host_ed25519_key" \
  -o "HostKey=$HOSTKEY_DIR/ssh_host_rsa_key"
