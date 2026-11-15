#!/bin/sh
# host/setup-host.sh [--id ID] [--repo PATH] [--repo-url URL] [--worktrees PATH] [--pubkeys FILE|-] [--rebuild]
#
# リモートホストの準備。ログインユーザーで実行する（sudo 不要・rootless Podman）。
# 通常は手元の `client/cubby add-host` から自動で呼ばれる。何度実行しても同じ結果になる。
# root が要る準備（パッケージ・subuid・linger・ディレクトリ）は host/bootstrap-root.sh が先に済ませる。
#
#   元リポジトリ                         なければ --repo-url から clone する
#   ~/.config/cubby/config.env          なければ作る（既存の値は変えない）
#   ~/.config/cubby/hostkeys/           全コンテナ共通のホスト鍵。なければ作る（上書きしない）
#   ~/.config/cubby/authorized_keys/dev 渡された公開鍵のうち未登録の行だけ追記する
#   worktree の置き場                    なければ作る
#   ~/.local/bin/ctr-*                  スクリプトを設置する
#   イメージ                             なければビルドする（--rebuild で作り直す）
#   動作確認                             rootless でコンテナが起動できるか確かめる
#   GPU                                 GPU 付きのコンテナが起動できるか確かめ、結果を
#                                       ~/.config/cubby/detected.env に書く（--gpu off で無効）
#
# 最後に標準出力へ「CUBBY_GPU yes|no [情報]」と「CUBBY_HOSTKEY <ホスト公開鍵>」を出す
# （手元が known_hosts に登録し、GPU の有無を表示する）。
# それ以外の出力はすべて標準エラー出力へ出す。
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
log()  { printf 'setup-host: %s\n' "$*" >&2; }
warn() { printf 'setup-host: WARNING: %s\n' "$*" >&2; }
die()  { printf 'setup-host: ERROR: %s\n' "$*" >&2; exit 1; }

id_arg= repo_arg= repo_url= wt_arg= pubkeys= rebuild=0 gpu_mode=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)       gpu_mode=$2; shift 2 ;;
    --id)        id_arg=$2; shift 2 ;;
    --repo)      repo_arg=$2; shift 2 ;;
    --repo-url)  repo_url=$2; shift 2 ;;
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

# 元リポジトリ（なければ clone する。ssh の URL は手元から転送された ssh-agent で認証する）
if [ ! -d "$REPO/.git" ]; then
  [ -n "$repo_url" ] || die "$REPO/.git not found; pass --repo-url to clone it, or --repo to use another path"
  if [ -d "$REPO" ] && [ -n "$(ls -A "$REPO" 2>/dev/null)" ]; then
    die "$REPO exists and is not empty, but is not a git repository"
  fi
  log "cloning $repo_url into $REPO"
  GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
    git clone -q "$repo_url" "$REPO" </dev/null >&2 || die "git clone failed"
fi
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

# bootstrap-root.sh が subuid/subgid を足したときは、podman に読み直させる
if [ -e "$CONF_DIR/.needs-migrate" ]; then
  podman system migrate >&2 && rm -f "$CONF_DIR/.needs-migrate"
  log "ran podman system migrate"
fi

# イメージ（dev の UID/GID はログインユーザーと同じにする。--userns=keep-id で対応づけるため）
if [ "$rebuild" = 1 ] || ! podman image exists "$IMAGE"; then
  log "building image $IMAGE (uid $(id -u), gid $(id -g)) ..."
  podman build -q --build-arg DEV_UID="$(id -u)" --build-arg DEV_GID="$(id -g)" \
    -t "$IMAGE" "$here/image" >&2
  log "built $IMAGE"
fi

# rootless でコンテナが動くか（ctr-connect と同じ指定で）確かめる
if ! out=$(podman run --rm --userns=keep-id --user root --security-opt label=disable \
            --uts=private --network=private "$IMAGE" id -un dev 2>&1 </dev/null); then
  printf '%s\n' "$out" >&2
  die "cannot run a rootless container (check /etc/subuid, /etc/subgid, and user namespaces / AppArmor)"
fi
log "rootless container check passed"

# linger（bootstrap-root.sh が有効化する。無効だと SSH が切れたときにコンテナが止まる）
if command -v loginctl >/dev/null 2>&1 && [ -d /run/systemd/system ]    && [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
  warn "linger is off for $(id -un); containers stop when the last SSH session ends"
fi

# GPU: ctr-connect と同じ指定で GPU 付きのコンテナが起動できるか確かめ、detected.env に書く
# （CTR_GPU_ARGS を config.env で変えた場合、例えば AMD の --device /dev/kfd --device /dev/dri
#   では、nvidia-smi の代わりに true で起動だけを確かめる）
gpu_avail=no gpu_info=
if [ "$gpu_mode" != off ]; then
  if [ -n "${CTR_GPU_ARGS:-}" ]; then
    gargs=$CTR_GPU_ARGS; gtest=true
  else
    gargs='--device nvidia.com/gpu=all'; gtest='nvidia-smi -L'
  fi
  if [ -n "${CTR_GPU_ARGS:-}" ] || { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }; then
    # shellcheck disable=SC2086
    if gout=$(podman run --rm --userns=keep-id --user root --security-opt label=disable \
                --uts=private --network=private $gargs "$IMAGE" $gtest 2>&1 </dev/null); then
      gpu_avail=yes
      n=$(printf '%s\n' "$gout" | grep -c '^GPU [0-9]' || true)
      [ "$n" -gt 0 ] && gpu_info="$n GPU: $(printf '%s\n' "$gout" | sed -n 's/^GPU 0: \([^(]*\).*/\1/p' | sed 's/ *$//')"
      log "GPU containers available${gpu_info:+ ($gpu_info)}"
    else
      printf '%s\n' "$gout" | tail -n 5 >&2
      warn "the NVIDIA driver works on the host, but a GPU container does not start; GPU containers are disabled"
    fi
  else
    log "no usable GPU on this host (gpu-* connections are disabled)"
  fi
fi
{
  echo "# written by setup-host.sh (cubby). Do not edit; override in config.env instead."
  echo "CTR_GPU_AVAILABLE=$gpu_avail"
  echo "CTR_GPU_INFO='$(printf '%s' "$gpu_info" | tr -d "'")'"
} > "$CONF_DIR/detected.env"

log "done (host id: ${CTR_HOST_ID:-unset})"
printf 'CUBBY_GPU %s %s\n' "$gpu_avail" "$gpu_info"
printf 'CUBBY_HOSTKEY %s\n' "$(cut -d' ' -f1,2 "$key.pub")"
