FROM docker.io/library/debian:bookworm-slim

# このディレクトリ（image/）の中身を変えると、次の `cubby add-host <id>` で各ホストのイメージが
# 自動で作り直される（中身のハッシュをイメージのラベル cubby.image-hash と比べる）。
# 既存のコンテナへの反映は、ホストで `ctr-recreate <名前>`。
# 必要なパッケージは下の apt-get install の行に足す。USER 行やユーザーの作成は書かないこと
# （起動時にホストのユーザーを登録する ctr-entrypoint と食い違うため）。

# 利用者のユーザーはイメージに作らない。コンテナの起動時に ctr-entrypoint が
# ホストのログインユーザー（同じ名前・UID・GID・ホームのパス）を登録し、sudo を許可する。
# ホスト鍵はイメージに含めない（ホストから読み取り専用でマウントする）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server netcat-openbsd git ca-certificates curl bash tini sudo \
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
