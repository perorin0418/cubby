#!/bin/sh
# host/setup-host.sh <公開鍵ファイル> [ログインユーザー]
#
# リモートホストの準備（何度実行しても同じ結果になる。既存の鍵は上書きしない）:
#   - /etc/ctr/config.env           : なければ config.env.example を置く
#   - 全コンテナ共通のホスト鍵      : なければ作る（root 所有・600）
#   - authorized_keys（dev 用）     : 指定の公開鍵のうち未登録の行だけ追記（root 所有・644）
#   - worktree の置き場             : ログインユーザー所有で作る
#   - ctr-* スクリプト              : CTR_BIN_DIR（既定 /usr/local/bin）に設置
#
# sudo が必要。CTR_BIN_DIR=~/bin のように変えた場合は、ProxyCommand で絶対パスを使うこと。
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)

pubkey=${1:-}
login_user=${2:-$(id -un)}
[ -n "$pubkey" ] && [ -r "$pubkey" ] || {
  echo "usage: $0 <public-key-file> [login-user]" >&2; exit 2; }

SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=

# 設定ファイル（既存は残す）
$SUDO install -d -m 755 -o root -g root /etc/ctr
if [ ! -e /etc/ctr/config.env ]; then
  $SUDO install -m 644 -o root -g root "$here/config.env.example" /etc/ctr/config.env
  echo "installed /etc/ctr/config.env (edit it if the defaults do not fit)"
fi
# shellcheck disable=SC1091
. /etc/ctr/config.env
WT_ROOT=${CTR_WT_ROOT:-/srv/worktrees}
HOSTKEYS=${CTR_HOSTKEYS:-/etc/ctr/hostkeys}
AUTHKEYS=${CTR_AUTHKEYS:-/etc/ctr/authorized_keys}
BIN_DIR=${CTR_BIN_DIR:-/usr/local/bin}

# ホスト鍵（既にあれば作り直さない）
$SUDO install -d -m 755 -o root -g root "$HOSTKEYS" "$AUTHKEYS"
key="$HOSTKEYS/ssh_host_ed25519_key"
if ! $SUDO test -e "$key"; then
  $SUDO ssh-keygen -q -t ed25519 -N '' -C ctr-dev-containers -f "$key"
  echo "generated host key $key"
fi
$SUDO chown root:root "$key" "$key.pub"
$SUDO chmod 600 "$key"
$SUDO chmod 644 "$key.pub"

# authorized_keys（未登録の行だけ追記する。既存の行は消さない）
ak="$AUTHKEYS/dev"
$SUDO touch "$ak"
added=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  if ! $SUDO grep -qxF -- "$line" "$ak"; then
    printf '%s\n' "$line" | $SUDO tee -a "$ak" >/dev/null
    added=$((added + 1))
  fi
done < "$pubkey"
$SUDO chown root:root "$ak"
$SUDO chmod 644 "$ak"
echo "authorized_keys: $added key(s) added to $ak"

# worktree の置き場
if [ ! -d "$WT_ROOT" ]; then
  $SUDO install -d -m 755 -o "$login_user" "$WT_ROOT"
  echo "created $WT_ROOT (owner $login_user)"
fi

# スクリプト
$SUDO install -d "$BIN_DIR"
for f in ctr-connect ctr-list ctr-remove; do
  $SUDO install -m 755 "$here/bin/$f" "$BIN_DIR/$f"
done
echo "installed ctr-connect ctr-list ctr-remove to $BIN_DIR"

echo
echo "host key fingerprint (clients will see this as 'dev-containers'):"
ssh-keygen -lf "$key.pub"
