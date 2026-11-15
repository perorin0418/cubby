FROM docker.io/library/debian:bookworm-slim

# このディレクトリ（image/）の中身を変えて push すると、各ホストが自動で取得してイメージを作り直す
# （中身のハッシュをイメージのラベル cubby.image-hash と比べる）。すぐ反映するなら `cubby update`。
# 既存のコンテナへの反映は、ホストで `ctr-recreate <名前>`。
# USER 行やユーザーの作成は書かないこと（起動時にホストのユーザーを登録する ctr-entrypoint と食い違うため）。
#
# 利用者のユーザーはイメージに作らない。コンテナの起動時に ctr-entrypoint が
# ホストのログインユーザー（同じ名前・UID・GID・ホームのパス）を登録し、sudo を許可する。
# ホスト鍵はイメージに含めない（ホストから読み取り専用でマウントする）。
#
# 開発ツールは、ビルドした時点の最新版を入れる（Go・Node.js LTS・Java 21 LTS・yq・kubectl・helm・AWS CLI）。
# 版を上げたいときは `cubby update <id> --rebuild` で作り直す。amd64 と arm64 に対応する。

# 基本のコマンドと、Debian のパッケージで入れるもの（Python・jq など）
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server netcat-openbsd git ca-certificates curl bash tini sudo \
      gnupg jq unzip xz-utils less procps libatomic1 \
      python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd

# Docker CLI（docker・docker compose・docker buildx）。デーモンは入れない。
# ホストの Podman の API ソケットが /var/run/docker.sock にマウントされ、そこに対して使う。
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# Go（最新の安定版）
RUN set -eu; arch=$(dpkg --print-architecture); \
    v=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1); \
    curl -fsSL "https://go.dev/dl/$v.linux-$arch.tar.gz" | tar -xz -C /usr/local; \
    ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/

# Node.js（最新の LTS。npm・npx を含む）
RUN set -eu; case "$(dpkg --print-architecture)" in amd64) a=x64 ;; arm64) a=arm64 ;; *) exit 1 ;; esac; \
    v=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version'); \
    curl -fsSL "https://nodejs.org/dist/$v/node-$v-linux-$a.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE

# Java（Eclipse Temurin 21 LTS）
RUN set -eu; case "$(dpkg --print-architecture)" in amd64) a=x64 ;; arm64) a=aarch64 ;; *) exit 1 ;; esac; \
    mkdir -p /opt/java; \
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/$a/jdk/hotspot/normal/eclipse" \
      | tar -xz -C /opt/java --strip-components=1; \
    for b in /opt/java/bin/*; do ln -s "$b" /usr/local/bin/; done; \
    echo 'JAVA_HOME=/opt/java' >> /etc/environment

# yq（mikefarah/yq）
RUN set -eu; arch=$(dpkg --print-architecture); \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$arch" -o /usr/local/bin/yq; \
    chmod 755 /usr/local/bin/yq

# kubectl（最新の stable）
RUN set -eu; arch=$(dpkg --print-architecture); \
    v=$(curl -fsSL https://dl.k8s.io/release/stable.txt); \
    curl -fsSL "https://dl.k8s.io/release/$v/bin/linux/$arch/kubectl" -o /usr/local/bin/kubectl; \
    chmod 755 /usr/local/bin/kubectl

# helm（最新）
RUN set -eu; arch=$(dpkg --print-architecture); \
    v=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name); \
    curl -fsSL "https://get.helm.sh/helm-$v-linux-$arch.tar.gz" | tar -xz -C /tmp; \
    mv "/tmp/linux-$arch/helm" /usr/local/bin/helm; rm -rf "/tmp/linux-$arch"

# AWS CLI v2
RUN set -eu; case "$(dpkg --print-architecture)" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) exit 1 ;; esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$a.zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp; /tmp/aws/install; rm -rf /tmp/aws /tmp/awscli.zip

# go install / pip install --user で入れたコマンドを PATH に入れる。
# docker build・docker compose build は、Podman が実装している従来のビルド（DOCKER_BUILDKIT=0）を使う
# （buildx の既定の builder は Podman の上では作ったイメージがホストのイメージ一覧に入らないため）。
# /etc/environment は SSH のログイン（コマンド実行も含む）で読まれる。
RUN printf '%s\n' 'export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"' \
      'export DOCKER_BUILDKIT=0 COMPOSE_BAKE=false' > /etc/profile.d/cubby-tools.sh \
 && printf '%s\n' 'DOCKER_BUILDKIT=0' 'COMPOSE_BAKE=false' >> /etc/environment

COPY ctr-sshd.conf /etc/ssh/sshd_config.d/ctr.conf
COPY ctr-entrypoint.sh /usr/local/bin/ctr-entrypoint
RUN chmod 755 /usr/local/bin/ctr-entrypoint

# tini を PID 1 にして、孤児になったプロセス（ゾンビ）を回収させる。
# ホスト側の podman --init（catatonit）の有無に依存しないよう、イメージに含める。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ctr-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
