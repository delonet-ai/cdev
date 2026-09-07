# Dev-контейнер для запуска Claude Code на OMV.
# Один образ на все проекты; контейнеры плодятся из него (по одному на проект).
FROM node:22-bookworm

# Адрес сервера и пользователь для деплоя. Вынесены в ARG, чтобы кит собирался
# на чужом хосте без правки Dockerfile: --build-arg OMV_HOST=10.0.0.5
ARG OMV_HOST=192.168.0.100
ARG OMV_DEPLOY_USER=deployer

# Версии стороннего софта. "latest" спрашивает у GitHub API последний релиз —
# удобно, но невоспроизводимо и упирается в лимит анонимных запросов (60/час).
# Для повторяемых сборок задавай явный тег: --build-arg YQ_VERSION=v4.44.3
ARG YQ_VERSION=latest
ARG RALPHEX_VERSION=latest
ARG CODEX_VERSION=latest

# Без pipefail в конвейере вида `curl ... | bash` падение curl остаётся незамеченным:
# статус берётся от последней команды, и в образ приезжает молча недоустановленный
# инструмент. Явный bash нужен потому, что у dash такой опции нет.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Базовый dev-тулинг + SSH (сервер для входа с Mac, клиент для выхода на OMV-хост).
# Состав зафиксирован в BASE-KIT.md — там же, почему каждая вещь здесь.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      openssh-server \
      openssh-client \
      ripgrep \
      tmux \
      curl \
      ca-certificates \
      build-essential \
      less \
      vim-tiny \
      kitty-terminfo \
      jq \
      rsync \
      bsdextrautils \
      gnupg \
      unzip \
      zip \
      tree \
      htop \
      procps \
      fd-find \
      shellcheck \
      python3-pip \
      python3-venv \
      postgresql-client \
      sqlite3 \
      redis-tools \
      dnsutils \
      iputils-ping \
      netcat-openbsd \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI и docker CLI — из официальных apt-репозиториев: подписи проверяет сам
# apt, и они обновляются штатным apt-get upgrade, а не ручным перекачиванием.
# docker ставим БЕЗ демона (только клиент + compose): он ходит на сервер по SSH,
# см. DOCKER_HOST ниже.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli.gpg; \
    chmod a+r /etc/apt/keyrings/githubcli.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh docker-ce-cli docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version; docker --version

# yq — разбор compose/yaml. В Debian под этим именем лежит другой инструмент
# (обёртка над jq), поэтому берём бинарь mikefarah/yq с проверкой контрольной суммы.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    tag="$YQ_VERSION"; \
    if [ "$tag" = latest ]; then \
      tag="$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r .tag_name)"; \
    fi; \
    base="https://github.com/mikefarah/yq/releases/download/${tag}"; \
    cd /tmp; \
    curl -fsSL -o yq "${base}/yq_linux_${arch}"; \
    curl -fsSL -o checksums "${base}/checksums"; \
    curl -fsSL -o hashes_order "${base}/checksums_hashes_order"; \
    col="$(grep -n '^SHA-256$' hashes_order | cut -d: -f1)"; \
    expected="$(grep "^yq_linux_${arch} " checksums | awk -v c="$((col + 1))" '{print $c}')"; \
    [ -n "$expected" ]; \
    echo "${expected}  yq" | sha256sum -c -; \
    install -m 0755 yq /usr/local/bin/yq; \
    rm -f yq checksums hashes_order; \
    yq --version

# ralphex — автономное выполнение планов (github.com/umputun/ralphex, MIT).
# Берём готовый .deb из релизов: `go install` потребовал бы тащить в образ весь
# Go-тулчейн. Контрольную сумму проверяем — это сторонний код из интернета.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    tag="$RALPHEX_VERSION"; \
    if [ "$tag" = latest ]; then \
      tag="$(curl -fsSL https://api.github.com/repos/umputun/ralphex/releases/latest | jq -r .tag_name)"; \
    fi; \
    ver="${tag#v}"; \
    base="https://github.com/umputun/ralphex/releases/download/${tag}"; \
    cd /tmp; \
    curl -fsSL -o "ralphex_${ver}_linux_${arch}.deb" "${base}/ralphex_${ver}_linux_${arch}.deb"; \
    curl -fsSL -o checksums.txt "${base}/ralphex_${ver}_checksums.txt"; \
    grep " ralphex_${ver}_linux_${arch}.deb\$" checksums.txt | sha256sum -c -; \
    dpkg -i "ralphex_${ver}_linux_${arch}.deb"; \
    rm -f "ralphex_${ver}_linux_${arch}.deb" checksums.txt; \
    ralphex --version

# codex — внешний ревьюер в цикле ralphex (фаза 3: Claude пишет, codex перечитывает).
# Без него ralphex либо валится на фазе ревью, либо её приходится отключать, и
# автономный цикл остаётся с самопроверкой одной моделью — сигнал заметно слабее.
# Ставим npm-пакетом от root в /usr/local: codex, в отличие от claude, не пытается
# обновлять сам себя, поэтому root-owned каталог ему не мешает.
RUN set -eux; \
    npm install -g "@openai/codex@${CODEX_VERSION}"; \
    npm cache clean --force; \
    codex --version

# Непривилегированный пользователь. Логинимся по SSH как dev, sshd крутится root'ом.
RUN useradd -m -s /bin/bash dev \
    && mkdir -p /var/run/sshd

# Ужесточаем sshd: только ключи, без root, только пользователь dev.
# Пишем в sshd_config.d, а не в хвост sshd_config: у sshd выигрывает ПЕРВОЕ
# вхождение директивы, а Include этого каталога стоит в начале конфига. Дописанное
# в конец молча проиграет любому значению, которое появится в дистрибутивном файле.
RUN mkdir -p /etc/ssh/sshd_config.d \
    && { \
      echo 'PasswordAuthentication no'; \
      echo 'PubkeyAuthentication yes'; \
      echo 'PermitRootLogin no'; \
      echo 'AllowUsers dev'; \
      echo 'X11Forwarding no'; \
    } > /etc/ssh/sshd_config.d/99-claude-dev.conf \
    && chmod 644 /etc/ssh/sshd_config.d/99-claude-dev.conf

# Claude Code — НАТИВНАЯ установка от пользователя dev (в /home/dev/.local, без sudo).
# Так claude сам обновляется (папка пишется dev'ом) и НЕ плодит вторую установку.
# Раньше ставили через `npm install -g` в root-owned /usr/local → claude мигрировал
# на native и возникали "Multiple installations" + "npm global folder isn't writable".
USER dev
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && printf '%s\n' \
      '' \
      '# Токен Claude Code. Дублирует /etc/profile.d/claude-env.sh: тот читают login-шеллы,' \
      '# этот — интерактивные без login (например, панель, открывающая шелл внутри tmux).' \
      '[ -r "$HOME/.claude_env" ] && . "$HOME/.claude_env"' \
      '' \
      '# Интерактивный вход — сразу в /workspace: там код проекта.' \
      '# В $HOME лежат ключи и креды, которым нечего делать в рабочем контексте Claude.' \
      'cd /workspace 2>/dev/null || true' \
      >> /home/dev/.bashrc
USER root

# claude лежит в ~/.local/bin, а туда PATH попадает только у login-шелла: у Debian это
# делает ~/.profile. Значит `ssh dev@контейнер claude ...` и любой неинтерактивный вызов
# упирались в "command not found". Прописываем путь в образ, чтобы бинарь находился
# из любого шелла, а не только из того, куда пользователь зашёл руками.
ENV PATH=/home/dev/.local/bin:$PATH

# Долгоживущий токен Claude (claude setup-token) кладётся в ~/.claude_env при deploy.
# Подхватываем его из /etc/profile.d, а не из ~/.bashrc: у Debian .bashrc в самом
# начале выходит для неинтерактивных шеллов, поэтому `bash -lc` — а это и ralphex, и
# docker exec — переменной бы не увидел. /etc/profile читают все login-шеллы.
RUN printf '%s\n' \
      '# Токен Claude Code: файл засевается claude-dev-ctl, в образе его нет.' \
      '[ -r "$HOME/.claude_env" ] && . "$HOME/.claude_env"' \
      > /etc/profile.d/claude-env.sh \
    && chmod 644 /etc/profile.d/claude-env.sh

# docker CLI без локального демона: все команды идут на OMV-хост по SSH под deployer.
# Значит `docker ps` здесь показывает контейнеры СЕРВЕРА (включая прод) — правила
# обращения с ними описаны в CLAUDE.md, который засевается в каждый контейнер.
ENV DOCKER_HOST=ssh://${OMV_DEPLOY_USER}@${OMV_HOST}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Обёртка над Arcane API — чтобы управлять test/prod-проектами на сервере.
COPY arcane /usr/local/bin/arcane
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/arcane

WORKDIR /workspace
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
