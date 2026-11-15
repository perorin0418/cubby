#!/bin/sh
# host/setup-host.sh [--id ID] [--work-root PATH] [--pubkeys FILE|-] [--rebuild] [--gpu auto|off]
#                    [--mount SPEC]... [--unmount PATH]...
#
# リモートホストの準備。ログインユーザーで実行する（sudo 不要・rootless Podman）。
# 通常は手元の `client/cubby add-host` から自動で呼ばれる。何度実行しても同じ結果になる。
# root が要る準備（パッケージ・subuid・linger・必要ならディレクトリ）は host/bootstrap-root.sh が先に済ませる。
#
#   ~/.config/cubby/config.env          なければ作る（既存の値は変えない）
#   ~/.config/cubby/hostkeys/           全コンテナ共通のホスト鍵。なければ作る（上書きしない）
#   ~/.config/cubby/authorized_keys/<ユーザー名> 渡された公開鍵のうち未登録の行だけ追記する
#   作業ディレクトリの置き場             なければ作る（既定 ~/cubby/work）
#   ~/.local/bin/ctr-*                  スクリプトを設置する
#   ~/.config/cubby/mounts              --mount / --unmount を反映する
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

id_arg= work_arg= pubkeys= rebuild=0 gpu_mode=auto
add_mounts= del_mounts=
nl='
'
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)       gpu_mode=$2; shift 2 ;;
    --mount)     add_mounts="$add_mounts$2$nl"; shift 2 ;;
    --unmount)   del_mounts="$del_mounts$2$nl"; shift 2 ;;
    --id)        id_arg=$2; shift 2 ;;
    --work-root) work_arg=$2; shift 2 ;;
    --pubkeys)   pubkeys=$2; shift 2 ;;
    --rebuild)   rebuild=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

for c in podman flock ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || die "$c is not installed"
done

CONF=${CTR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cubby/config.env}
CONF_DIR=$(dirname "$CONF")
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

# 設定ファイル（既存の値は変えない。食い違いは警告する）
if [ ! -e "$CONF" ]; then
  sed -e "s|^CTR_HOST_ID=.*|CTR_HOST_ID=${id_arg}|" \
      -e "s|^CTR_WORK_ROOT=.*|CTR_WORK_ROOT=${work_arg:-$HOME/cubby/work}|" \
      "$here/config.env.example" > "$CONF"
  log "created $CONF"
fi
# shellcheck disable=SC1090
. "$CONF"
WORK_ROOT=${CTR_WORK_ROOT:-$HOME/cubby/work}
IMAGE=${CTR_IMAGE:-localhost/ctr-dev:latest}
HOSTKEYS=${CTR_HOSTKEYS:-$CONF_DIR/hostkeys}
AUTHKEYS=${CTR_AUTHKEYS:-$CONF_DIR/authorized_keys}
BIN_DIR=${CTR_BIN_DIR:-$HOME/.local/bin}
keep() { [ -z "$2" ] || [ "$2" = "$3" ] || warn "$CONF keeps $1=$3 (requested $2); edit it by hand to change"; }
keep CTR_HOST_ID "$id_arg" "${CTR_HOST_ID:-}"
keep CTR_WORK_ROOT "$work_arg" "$WORK_ROOT"

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

# authorized_keys（未登録の行だけ追記する。既存の行は消さない）。
# コンテナにはホストのユーザー名でログインするので、ファイル名もユーザー名（sshd の %u）。
ak="$AUTHKEYS/$(id -un)"
if [ -f "$AUTHKEYS/dev" ] && [ ! -e "$ak" ]; then
  # 旧版（コンテナ内のユーザーが dev だった）の登録を引き継ぐ
  mv "$AUTHKEYS/dev" "$ak"
  log "moved $AUTHKEYS/dev to $ak (container user is now $(id -un))"
fi
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

# 作業ディレクトリの置き場（各コンテナの作業ディレクトリ <置き場>/<名前> はここに作られる）
if [ ! -d "$WORK_ROOT" ]; then
  mkdir -p "$WORK_ROOT" 2>/dev/null \
    || die "cannot create $WORK_ROOT; ask an admin: sudo install -d -o $(id -un) $WORK_ROOT"
  log "created $WORK_ROOT"
fi
[ -w "$WORK_ROOT" ] || die "$WORK_ROOT is not writable by $(id -un)"

# スクリプト
mkdir -p "$BIN_DIR"
for f in ctr-connect ctr-list ctr-remove ctr-recreate ctr-common.sh; do
  mode=755; case "$f" in *.sh) mode=644 ;; esac
  cp "$here/bin/$f" "$BIN_DIR/$f.tmp" && chmod "$mode" "$BIN_DIR/$f.tmp" && mv -f "$BIN_DIR/$f.tmp" "$BIN_DIR/$f"
done
log "installed ctr-connect ctr-list ctr-remove ctr-recreate to $BIN_DIR"

# 追加マウント（~/.config/cubby/mounts）。--mount は同じホストのパスの行を置き換えて追記、
# --unmount はそのホストのパスの行を消す。手で書いた他の行やコメントは残す。
# shellcheck source=bin/ctr-common.sh
. "$here/bin/ctr-common.sh"
MOUNTS=${CTR_MOUNTS_FILE:-$CONF_DIR/mounts}
if [ ! -e "$MOUNTS" ]; then
  cat > "$MOUNTS" <<'EOF'
# cubby: このホストの全コンテナに毎回マウントするディレクトリ（1 行に 1 つ）
#   ホストのパス[:コンテナ内のパス][:ro|rw]     省略時はホストと同じパス、rw
# 例:
#   /data/datasets:/datasets:ro
#   /scratch
# 変更を既存のコンテナに反映するには: ctr-recreate <名前>
EOF
fi
# ホストのパスが一致する行（コメント以外）を消す
drop_mount_line() {
  awk -v src="$1" '
    { l = $0; sub(/^[ \t]+/, "", l) }
    l !~ /^#/ && l != "" { split(l, f, ":"); if (f[1] == src) next }
    { print }' "$MOUNTS" > "$MOUNTS.tmp" && mv -f "$MOUNTS.tmp" "$MOUNTS"
}
printf '%s' "$del_mounts" | while IFS= read -r m; do
  [ -n "$m" ] || continue
  drop_mount_line "${m%%:*}"
  log "mounts: removed $m"
done
printf '%s' "$add_mounts" | while IFS= read -r m; do
  [ -n "$m" ] || continue
  spec=$(ctr_parse_mount "$m") || die "invalid --mount '$m' (HOST_PATH[:CONTAINER_PATH][:ro|rw], absolute paths)"
  drop_mount_line "${spec%%:*}"
  printf '%s\n' "$m" >> "$MOUNTS"
  [ -e "${spec%%:*}" ] || warn "mount source ${spec%%:*} does not exist on this host yet (it is skipped until it exists)"
  log "mounts: $spec"
done

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

# イメージ。利用者のユーザーはイメージに含めない（起動時にホストのユーザーを登録する）ので、
# ホストに依存しない。image/ の中身（Dockerfile など）のハッシュをラベル cubby.image-hash に
# 記録し、中身が変わっていれば自動で作り直す（--rebuild なら常に作り直す）。
img_hash=$(cd "$here/image" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
             printf '%s  ' "$f"; sha256sum < "$f" | cut -d' ' -f1
           done | sha256sum | cut -c1-16)
have_hash=$(podman image inspect -f '{{index .Labels "cubby.image-hash"}}' "$IMAGE" 2>/dev/null || true)
case "$have_hash" in '<no value>') have_hash= ;; esac
if [ "$rebuild" = 1 ] || [ "$have_hash" != "$img_hash" ]; then
  if [ "$rebuild" = 1 ]; then
    log "rebuilding image $IMAGE (--rebuild) ..."
  elif [ -n "$have_hash" ] || podman image exists "$IMAGE"; then
    log "image/ (Dockerfile etc.) changed since $IMAGE was built; rebuilding ..."
  else
    log "building image $IMAGE ..."
  fi
  podman build -q --label cubby.image-hash="$img_hash" -t "$IMAGE" "$here/image" >&2
  log "built $IMAGE (image/ hash $img_hash)"
fi

# rootless でコンテナが動き、ホストのユーザーが同じ名前・UID・ホームで使えるか（ctr-connect と同じ指定で）
want_id="$(id -un) $(id -u) $(id -g) $HOME"
if ! out=$(podman run --rm --userns=keep-id --user root --passwd=false --security-opt label=disable \
            --uts=private --network=private \
            -e CTR_USER="$(id -un)" -e CTR_UID="$(id -u)" -e CTR_GID="$(id -g)" -e CTR_HOME="$HOME" \
            "$IMAGE" sh -c 'u=$CTR_USER; echo "$(id -un "$u") $(id -u "$u") $(id -g "$u") $(getent passwd "$u" | cut -d: -f6)"' \
            2>&1 </dev/null) || [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want_id" ]; then
  printf '%s\n' "$out" >&2
  die "cannot run a rootless container as $(id -un) (check /etc/subuid, /etc/subgid, and user namespaces / AppArmor)"
fi
log "rootless container check passed (user $want_id)"

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
    if gout=$(podman run --rm --userns=keep-id --user root --passwd=false --security-opt label=disable \
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

# マウントの設定が変わったのに作り直していないコンテナを知らせる
sig=$(ctr_mount_sig)
outdated=
for c in $(podman ps -a --filter label=ctr.managed=true --format '{{.Names}}' 2>/dev/null); do
  [ "$(ctr_container_sig "$c")" = "$sig" ] || outdated="$outdated $c"
done
[ -z "$outdated" ] || warn "containers created with older mount settings:$outdated (apply with: ctr-recreate <name>)"
# イメージを作り直したのに、古いイメージのままのコンテナを知らせる
oldimg=
for c in $(podman ps -a --filter label=ctr.managed=true --format '{{.Names}}' 2>/dev/null); do
  ctr_image_outdated "$c" && oldimg="$oldimg $c"
done
[ -z "$oldimg" ] || warn "containers still using an older image:$oldimg (apply with: ctr-recreate <name>)"

log "done (host id: ${CTR_HOST_ID:-unset})"
printf 'CUBBY_USER %s\n' "$(id -un)"
printf 'CUBBY_GPU %s %s\n' "$gpu_avail" "$gpu_info"
printf 'CUBBY_HOSTKEY %s\n' "$(cut -d' ' -f1,2 "$key.pub")"
