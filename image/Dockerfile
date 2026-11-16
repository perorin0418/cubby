# ベースイメージは setup-host.sh がホストの OS に合わせて選ぶ（--build-arg BASE_IMAGE=...）。
#   Fedora → registry.fedoraproject.org/fedora:<版>、Debian → debian:<版>-slim、Ubuntu → ubuntu:<版>、
#   RHEL 系 → almalinux:<版>、その他 → debian:stable-slim。ホストの config.env の CTR_BASE_IMAGE で固定もできる。
# パッケージは apt（Debian・Ubuntu）か dnf（Fedora・RHEL 系）を見て入れる。それ以外のツールは
# OS に依存しない公式のバイナリで入れる（amd64・arm64）。
ARG BASE_IMAGE=docker.io/library/debian:stable-slim
FROM ${BASE_IMAGE}

# このディレクトリ（image/）の中身を変えて push すると、各ホストが自動で取得してイメージを作り直す
# （中身とベースイメージのハッシュを、イメージのラベル cubby.image-hash と比べる）。すぐ反映するなら `cubby update`。
# 古いイメージのコンテナは、次の接続のとき（誰もつないでいなければ）自動で作り直される。
# USER 行やユーザーの作成は書かないこと（起動時にホストのユーザーを登録する ctr-entrypoint と食い違うため）。
#
# 利用者のユーザーはイメージに作らない。コンテナの起動時に ctr-entrypoint が
# ホストのログインユーザー（同じ名前・UID・GID・ホームのパス）を登録し、sudo を許可する。
# ホスト鍵はイメージに含めない（ホストから読み取り専用でマウントする）。
# 開発ツールは、ビルドした時点の最新版を入れる。版を上げたいときは `cubby update <id> --rebuild`。

# OS のパッケージ（sshd・sudo・nc・git・Python・jq など）。
# 最後に、コンテナでは loginuid を書けないので、pam_loginuid の失敗でログインが止まらないようにする。
RUN set -eu; \
    if command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        openssh-server netcat-openbsd git ca-certificates curl bash sudo \
        gnupg jq unzip xz-utils less procps libatomic1 tar gzip \
        python3 python3-pip python3-venv; \
      rm -rf /var/lib/apt/lists/*; \
      mkdir -p /run/sshd; \
    elif command -v dnf >/dev/null 2>&1; then \
      dnf install -y --setopt=install_weak_deps=False \
        openssh-server nmap-ncat git-core ca-certificates curl bash sudo \
        gnupg2 jq unzip xz less procps-ng libatomic tar gzip findutils shadow-utils hostname \
        python3 python3-pip; \
      dnf clean all; \
      rm -rf /var/cache/dnf; \
    else \
      echo "unsupported base image (needs apt-get or dnf)" >&2; exit 1; \
    fi; \
    rm -f /etc/ssh/ssh_host_*; \
    if [ -f /etc/pam.d/sshd ]; then sed -i 's/^\(session\s\+\)required\(\s\+pam_loginuid\.so\)/\1optional\2/' /etc/pam.d/sshd; fi

# tini（PID 1 で孤児になったプロセスを回収する。ホストの podman --init に依存しない）
RUN set -eu; case "$(uname -m)" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) exit 1 ;; esac; \
    curl -fsSL "https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-$a" -o /usr/local/bin/tini; \
    chmod 755 /usr/local/bin/tini

# Docker CLI（docker・docker compose・docker buildx）の公式の静的バイナリ。デーモンは入れない。
# ホストの Podman の API ソケットが /var/run/docker.sock にマウントされ、そこに対して使う。
RUN set -eu; case "$(uname -m)" in x86_64) m=x86_64; a=amd64 ;; aarch64) m=aarch64; a=arm64 ;; *) exit 1 ;; esac; \
    v=$(curl -fsSL "https://download.docker.com/linux/static/stable/$m/" | grep -o 'docker-[0-9][0-9.]*\.tgz' | sort -uV | tail -n 1); \
    curl -fsSL "https://download.docker.com/linux/static/stable/$m/$v" | tar -xz -C /tmp; \
    mv /tmp/docker/docker /usr/local/bin/docker; rm -rf /tmp/docker; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$m" -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    bv=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | jq -r .tag_name); \
    curl -fsSL "https://github.com/docker/buildx/releases/download/$bv/buildx-$bv.linux-$a" -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod 755 /usr/local/lib/docker/cli-plugins/*

# Go（最新の安定版）
RUN set -eu; case "$(uname -m)" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) exit 1 ;; esac; \
    v=$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1); \
    curl -fsSL "https://go.dev/dl/$v.linux-$a.tar.gz" | tar -xz -C /usr/local; \
    ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/

# Node.js（最新の LTS。npm・npx を含む）
RUN set -eu; case "$(uname -m)" in x86_64) a=x64 ;; aarch64) a=arm64 ;; *) exit 1 ;; esac; \
    v=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version'); \
    curl -fsSL "https://nodejs.org/dist/$v/node-$v-linux-$a.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE

# Java（Eclipse Temurin 21 LTS）
RUN set -eu; case "$(uname -m)" in x86_64) a=x64 ;; aarch64) a=aarch64 ;; *) exit 1 ;; esac; \
    mkdir -p /opt/java; \
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/$a/jdk/hotspot/normal/eclipse" \
      | tar -xz -C /opt/java --strip-components=1; \
    for b in /opt/java/bin/*; do ln -s "$b" /usr/local/bin/; done

# yq（mikefarah/yq）・kubectl・helm
RUN set -eu; case "$(uname -m)" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) exit 1 ;; esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$a" -o /usr/local/bin/yq; \
    v=$(curl -fsSL https://dl.k8s.io/release/stable.txt); \
    curl -fsSL "https://dl.k8s.io/release/$v/bin/linux/$a/kubectl" -o /usr/local/bin/kubectl; \
    hv=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name); \
    curl -fsSL "https://get.helm.sh/helm-$hv-linux-$a.tar.gz" | tar -xz -C /tmp; \
    mv "/tmp/linux-$a/helm" /usr/local/bin/helm; rm -rf "/tmp/linux-$a"; \
    chmod 755 /usr/local/bin/yq /usr/local/bin/kubectl /usr/local/bin/helm

# AWS CLI v2
RUN set -eu; m=$(uname -m); \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$m.zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp; /tmp/aws/install; rm -rf /tmp/aws /tmp/awscli.zip

# 環境変数。go install / pip install --user で入れたコマンドを PATH に入れる。
# docker build・docker compose build は、Podman が実装している従来のビルド（DOCKER_BUILDKIT=0）を使う
# （buildx の既定の builder は Podman の上では作ったイメージがホストのイメージ一覧に入らないため）。
# SSH のセッションには sshd の SetEnv（ctr-sshd.conf）でも渡す。
RUN printf '%s\n' 'export PATH="$HOME/go/bin:$HOME/.local/bin:$PATH"' \
      'export JAVA_HOME=/opt/java DOCKER_BUILDKIT=0 COMPOSE_BAKE=false' > /etc/profile.d/cubby-tools.sh

COPY ctr-sshd.conf /etc/ssh/sshd_config.d/ctr.conf
COPY ctr-entrypoint.sh /usr/local/bin/ctr-entrypoint
RUN chmod 755 /usr/local/bin/ctr-entrypoint

ENTRYPOINT ["/usr/local/bin/tini", "--", "/usr/local/bin/ctr-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
