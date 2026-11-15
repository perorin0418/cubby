FROM debian:bookworm-slim

# dev の UID/GID は元リポジトリ（CTR_REPO）の所有者に合わせる。
#   docker build --build-arg DEV_UID=$(stat -c %u /srv/project/.git) \
#                --build-arg DEV_GID=$(stat -c %g /srv/project/.git) -t ctr-dev:latest image/
ARG DEV_UID=1000
ARG DEV_GID=1000

# ホスト鍵はイメージに含めない（ホストから読み取り専用でマウントする）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server netcat-openbsd git ca-certificates curl bash \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd \
 && groupadd -g "${DEV_GID}" dev \
 && useradd -m -u "${DEV_UID}" -g dev -s /bin/bash dev

COPY ctr-sshd.conf /etc/ssh/sshd_config.d/ctr.conf

CMD ["/usr/sbin/sshd", "-D", "-e"]
