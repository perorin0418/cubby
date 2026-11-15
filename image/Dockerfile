FROM docker.io/library/debian:bookworm-slim

# dev の UID/GID はリモートホストのログインユーザーと同じにする（rootless Podman の
# --userns=keep-id で対応づけるため）。通常は host/setup-host.sh が自動でビルドする。
#   podman build --build-arg DEV_UID=$(id -u) --build-arg DEV_GID=$(id -g) -t localhost/ctr-dev:latest image/
ARG DEV_UID=1000
ARG DEV_GID=1000

# ホスト鍵はイメージに含めない（ホストから読み取り専用でマウントする）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server netcat-openbsd git ca-certificates curl bash tini \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd \
 && groupadd -g "${DEV_GID}" dev \
 && useradd -m -u "${DEV_UID}" -g dev -s /bin/bash dev

COPY ctr-sshd.conf /etc/ssh/sshd_config.d/ctr.conf

# tini を PID 1 にして、孤児になったプロセス（ゾンビ）を回収させる。
# ホスト側の podman --init（catatonit）の有無に依存しないよう、イメージに含める。
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
