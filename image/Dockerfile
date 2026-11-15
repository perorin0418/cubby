FROM docker.io/library/debian:bookworm-slim

# イメージの版。setup-host.sh はこの値が期待と違うイメージを作り直す（作りが変わったときに上げる）。
LABEL cubby.image-version="3"

# 利用者のユーザーはイメージに作らない。コンテナの起動時に ctr-entrypoint が
# ホストのログインユーザー（同じ名前・UID・GID・ホームのパス）を登録する。
# ホスト鍵はイメージに含めない（ホストから読み取り専用でマウントする）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server netcat-openbsd git ca-certificates curl bash tini \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd

COPY ctr-sshd.conf /etc/ssh/sshd_config.d/ctr.conf
COPY ctr-entrypoint.sh /usr/local/bin/ctr-entrypoint
RUN chmod 755 /usr/local/bin/ctr-entrypoint

# tini を PID 1 にして、孤児になったプロセス（ゾンビ）を回収させる。
# ホスト側の podman --init（catatonit）の有無に依存しないよう、イメージに含める。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ctr-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
