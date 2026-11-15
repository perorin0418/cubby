#!/bin/sh
# host/setup-host.sh [--id ID] [--repo PATH] [--worktrees PATH] [--pubkeys FILE|-] [--rebuild]
#
# リモートホストの準備。ログインユーザーで実行する（sudo 不要・rootless Podman）。
# 通常は手元の `client/cubby add-host` から自動で呼ばれる。何度実行しても同じ結果になる。
#
#   ~/.config/cubby/config.env          なければ作る（既存の値は変えない）
#   ~/.config/cubby/hostkeys/           全コンテナ共通のホスト鍵。なければ作る（上書きしない）
#   ~/.config/cubby/authorized_keys/dev 渡された公開鍵のうち未登録の行だけ追記する
#   worktree の置き場                    なければ作る
#   ~/.local/bin/ctr-*                  スクリプトを設置する
#   イメージ                             なければビルドする（--rebuild で作り直す）
#   linger                              有効でなければ有効化を試みる
#
# 最後に標準出力へ 1 行だけ「CUBBY_HOSTKEY <ホスト公開鍵>」を出す（手元が known_hosts に登録する）。
# それ以外の出力はすべて標準エラー出力へ出す。
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
log()  { printf 'setup-host: %s\n' "$*" >&2; }
warn() { printf 'setup-host: WARNING: %s\n' "$*" >&2; }
die()  { printf 'setup-host: ERROR: %s\n' "$*" >&2; exit 1; }

id_arg= repo_arg= wt_arg= pubkeys= rebuild=0
while [ $# -gt 0 ]; do
  case "$1" in
    --id)        id_arg=$2; shift 2 ;;
    --repo)      repo_arg=$2; shift 2 ;;
    --worktrees) wt_arg=$2; shift 2 ;;
    --pubkeys)   pubkeys=$2; shift 2 ;;
    --rebuild)   rebuild=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

for c in podman git flock ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || die "$c is not installed"
done

CONF=${CTR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cubby/config.env}
CONF_DIR=$(dirname "$CONF")
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

# 設定ファイル（既存の値は変えない。食い違いは警告する）
if [ ! -e "$CONF" ]; then
  sed -e "s|^CTR_HOST_ID=.*|CTR_HOST_ID=${id_arg}|" \
      -e "s|^CTR_REPO=.*|CTR_REPO=${repo_arg:-/srv/project}|" \
      -e "s|^CTR_WT_ROOT=.*|CTR_WT_ROOT=${wt_arg:-/srv/worktrees}|" \
      "$here/config.env.example" > "$CONF"
  log "created $CONF"
fi
# shellcheck disable=SC1090
. "$CONF"
REPO=${CTR_REPO:-/srv/project}
WT_ROOT=${CTR_WT_ROOT:-/srv/worktrees}
IMAGE=${CTR_IMAGE:-localhost/ctr-dev:latest}
HOSTKEYS=${CTR_HOSTKEYS:-$CONF_DIR/hostkeys}
AUTHKEYS=${CTR_AUTHKEYS:-$CONF_DIR/authorized_keys}
BIN_DIR=${CTR_BIN_DIR:-$HOME/.local/bin}
keep() { [ -z "$2" ] || [ "$2" = "$3" ] || warn "$CONF keeps $1=$3 (requested $2); edit it by hand to change"; }
keep CTR_HOST_ID "$id_arg" "${CTR_HOST_ID:-}"
keep CTR_REPO "$repo_arg" "$REPO"
keep CTR_WT_ROOT "$wt_arg" "$WT_ROOT"

# 元リポジトリ
[ -d "$REPO/.git" ] || die "$REPO/.git not found (clone the repository first, or pass --repo)"
[ -w "$REPO/.git" ] || die "$REPO/.git is not writable by $(id -un)"
[ "$(stat -c %u "$REPO/.git")" = "$(id -u)" ] \
  || warn "$REPO/.git is not owned by $(id -un); the container user dev (uid $(id -u)) may fail to write"

# ホスト鍵（rootless なのでログインユーザー所有。既にあれば作り直さない）
mkdir -p "$HOSTKEYS" "$AUTHKEYS"
chmod 700 "$HOSTKEYS"
chmod 755 "$AUTHKEYS"
key="$HOSTKEYS/ssh_host_ed25519_key"
if [ ! -e "$key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "cubby-${CTR_HOST_ID:-$(hostname)}" -f "$key" </dev/null
  log "generated host key $key"
fi
chmod 600 "$key"
chmod 644 "$key.pub"

# authorized_keys（未登録の行だけ追記する。既存の行は消さない）
ak="$AUTHKEYS/dev"
touch "$ak"
chmod 644 "$ak"
if [ -n "$pubkeys" ]; then
  if [ "$pubkeys" = - ]; then src=/dev/stdin; else src=$pubkeys; fi
  added=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    case "$line" in
      ''|'#'*) continue ;;
      ssh-*|ecdsa-*|sk-*) ;;
      *) warn "skipped a line that does not look like a public key"; continue ;;
    esac
    if ! grep -qxF -- "$line" "$ak"; then
      printf '%s\n' "$line" >> "$ak"
      added=$((added + 1))
    fi
  done < "$src"
  log "authorized_keys: $added key(s) added to $ak"
fi
[ -s "$ak" ] || warn "$ak is empty; nobody can log in to the containers yet"

# worktree の置き場
if [ ! -d "$WT_ROOT" ]; then
  mkdir -p "$WT_ROOT" 2>/dev/null \
    || die "cannot create $WT_ROOT; ask an admin: sudo install -d -o $(id -un) $WT_ROOT"
  log "created $WT_ROOT"
fi
[ -w "$WT_ROOT" ] || die "$WT_ROOT is not writable by $(id -un)"

# スクリプト
mkdir -p "$BIN_DIR"
for f in ctr-connect ctr-list ctr-remove; do
  cp "$here/bin/$f" "$BIN_DIR/$f.tmp" && chmod 755 "$BIN_DIR/$f.tmp" && mv -f "$BIN_DIR/$f.tmp" "$BIN_DIR/$f"
done
log "installed ctr-connect ctr-list ctr-remove to $BIN_DIR"

# rootless Podman の確認
[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ] \
  || warn "podman is not running rootless; this setup assumes rootless Podman"
grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
  || warn "no /etc/subuid entry for $(id -un); rootless containers with --userns=keep-id will fail"

# イメージ（dev の UID/GID はログインユーザーと同じにする。--userns=keep-id で対応づけるため）
if [ "$rebuild" = 1 ] || ! podman image exists "$IMAGE"; then
  log "building image $IMAGE (uid $(id -u), gid $(id -g)) ..."
  podman build -q --build-arg DEV_UID="$(id -u)" --build-arg DEV_GID="$(id -g)" \
    -t "$IMAGE" "$here/image" >&2
  log "built $IMAGE"
fi

# linger: 無効だと SSH が切れたときにユーザーのプロセス（コンテナと Claude Code 本体）が止まる。
if command -v loginctl >/dev/null 2>&1; then
  if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
    if loginctl enable-linger "$(id -un)" 2>/dev/null; then
      log "enabled linger for $(id -un)"
    else
      warn "linger is off; ask an admin: sudo loginctl enable-linger $(id -un)"
    fi
  fi
else
  warn "loginctl not found; make sure user processes survive SSH logout"
fi

log "done (host id: ${CTR_HOST_ID:-unset})"
printf 'CUBBY_HOSTKEY %s\n' "$(cut -d' ' -f1,2 "$key.pub")"
