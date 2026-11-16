#!/bin/sh
# host/setup-host.sh [--id ID] [--pubkeys FILE|-] [--rebuild] [--gpu auto|off]
#                    [--mount SPEC]... [--unmount PATH]...
#
# リモートホストの準備。ログインユーザーで実行する（sudo 不要・rootless Podman）。
# 通常は手元の `client/cubby add-host` から自動で呼ばれる。何度実行しても同じ結果になる。
# root が要る準備（パッケージ・subuid・linger・必要ならディレクトリ）は host/bootstrap-root.sh が先に済ませる。
#
#   ~/.config/cubby/config.env          なければ作る（既存の値は変えない）
#   ~/.config/cubby/hostkeys/           全コンテナ共通のホスト鍵。なければ作る（上書きしない）
#   ~/.config/cubby/authorized_keys/<ユーザー名> 渡された公開鍵のうち未登録の行だけ追記する
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

id_arg= pubkeys= rebuild=0 gpu_mode=auto
add_mounts= del_mounts=
auto_url= auto_branch= auto_interval= auto_off=0
nl='
'
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)       gpu_mode=$2; shift 2 ;;
    --auto-update)          auto_url=$2; shift 2 ;;
    --auto-update-branch)   auto_branch=$2; shift 2 ;;
    --auto-update-interval) auto_interval=$2; shift 2 ;;
    --no-auto-update)       auto_off=1; shift ;;
    --mount)     add_mounts="$add_mounts$2$nl"; shift 2 ;;
    --unmount)   del_mounts="$del_mounts$2$nl"; shift 2 ;;
    --id)        id_arg=$2; shift 2 ;;
    --work-root) shift 2 ;;   # 旧版のクライアントとの互換のため受け付けて無視する
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
      "$here/config.env.example" > "$CONF"
  log "created $CONF"
fi
# shellcheck disable=SC1090
. "$CONF"
IMAGE=${CTR_IMAGE:-localhost/ctr-dev:latest}
HOSTKEYS=${CTR_HOSTKEYS:-$CONF_DIR/hostkeys}
AUTHKEYS=${CTR_AUTHKEYS:-$CONF_DIR/authorized_keys}
BIN_DIR=${CTR_BIN_DIR:-$HOME/.local/bin}
keep() { [ -z "$2" ] || [ "$2" = "$3" ] || warn "$CONF keeps $1=$3 (requested $2); edit it by hand to change"; }
keep CTR_HOST_ID "$id_arg" "${CTR_HOST_ID:-}"

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

# スクリプト
mkdir -p "$BIN_DIR"
for f in ctr-connect ctr-list ctr-remove ctr-recreate ctr-sync ctr-common.sh; do
  mode=755; case "$f" in *.sh) mode=644 ;; esac
  cp "$here/bin/$f" "$BIN_DIR/$f.tmp" && chmod "$mode" "$BIN_DIR/$f.tmp" && mv -f "$BIN_DIR/$f.tmp" "$BIN_DIR/$f"
done
log "installed ctr-connect ctr-list ctr-remove ctr-recreate ctr-sync to $BIN_DIR"

# 自動更新（ctr-sync を定期的に実行して、リポジトリの最新を反映する）
AU="$CONF_DIR/auto-update.env"
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
user_systemctl() {
  # SSH のセッションに XDG_RUNTIME_DIR がないことがある（linger が有効ならユーザーの systemd は動いている）
  [ -n "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "/run/user/$(id -u)" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  systemctl --user "$@"
}
if [ "$auto_off" = 1 ]; then
  if [ -e "$AU" ] || [ -e "$UNIT_DIR/cubby-sync.timer" ]; then
    user_systemctl disable --now cubby-sync.timer >/dev/null 2>&1 || true
    rm -f "$AU" "$UNIT_DIR/cubby-sync.timer" "$UNIT_DIR/cubby-sync.service"
    user_systemctl daemon-reload >/dev/null 2>&1 || true
    crontab -l 2>/dev/null | grep -v 'ctr-sync' | crontab - 2>/dev/null || true
    log "auto-update disabled"
  fi
elif [ -n "$auto_url" ]; then
  au_branch=${auto_branch:-main}
  au_interval=${auto_interval:-15min}
  case "$au_interval" in *[!0-9a-z]*|'') die "invalid --auto-update-interval: $au_interval (e.g. 15min, 1h)" ;; esac
  {
    echo "# written by setup-host.sh (cubby add-host). Re-run add-host to change."
    echo "CTR_AUTO_URL='$auto_url'"
    echo "CTR_AUTO_BRANCH='$au_branch'"
    echo "CTR_AUTO_GPU='$gpu_mode'"
    echo "CTR_AUTO_INTERVAL='$au_interval'"
  } > "$AU"
  # ssh の URL（git@... / ssh://...）は、このホスト用の読み取り専用のデプロイキーで取得する
  case "$auto_url" in
    git@*|ssh://*)
      if [ ! -e "$CONF_DIR/deploy_key" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "cubby-deploy-${CTR_HOST_ID:-$(hostname)}" -f "$CONF_DIR/deploy_key" </dev/null
        log "generated deploy key $CONF_DIR/deploy_key"
      fi
      chmod 600 "$CONF_DIR/deploy_key" ;;
  esac
  log "auto-update: $auto_url ($au_branch) every $au_interval"
fi
# タイマー（自動更新が設定されていれば、毎回入れ直す）
auto_mode=off
if [ -r "$AU" ]; then
  # shellcheck disable=SC1090
  . "$AU"
  interval=${CTR_AUTO_INTERVAL:-15min}
  if command -v systemctl >/dev/null 2>&1 && user_systemctl show-environment >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/cubby-sync.service" <<EOF
[Unit]
Description=cubby: apply the latest cubby repository to this host

[Service]
Type=oneshot
ExecStart=$BIN_DIR/ctr-sync
EOF
    cat > "$UNIT_DIR/cubby-sync.timer" <<EOF
[Unit]
Description=cubby: check the cubby repository every $interval

[Timer]
OnBootSec=2min
OnUnitActiveSec=$interval
RandomizedDelaySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    user_systemctl daemon-reload && user_systemctl enable --now cubby-sync.timer >/dev/null 2>&1 \
      && auto_mode="systemd timer (every $interval)" \
      || warn "could not enable the systemd user timer cubby-sync.timer"
  elif command -v crontab >/dev/null 2>&1; then
    # systemd のユーザーセッションがない環境: cron で代用する（間隔は分単位に丸める）
    mins=$(printf '%s' "$interval" | sed -n 's/^\([0-9][0-9]*\)min$/\1/p;s/^\([0-9][0-9]*\)h$/\1 60/p' | awk 'NF==2{print $1*$2;next}{print}')
    mins=${mins:-15}
    { crontab -l 2>/dev/null | grep -v 'ctr-sync'; echo "*/$mins * * * * $BIN_DIR/ctr-sync >/dev/null 2>&1"; } | crontab - \
      && auto_mode="cron (every ${mins}min)" || warn "could not install a crontab entry for ctr-sync"
  else
    warn "auto-update is configured, but neither a systemd user session nor cron is available; run ctr-sync yourself"
    auto_mode="configured (no scheduler)"
  fi
fi

# 旧版が入れた作業用コンテナの自動削除（ctr-task-gc）を取り除く（作業用コンテナの仕組みは廃止）
if [ -e "$UNIT_DIR/cubby-task-gc.timer" ]; then
  user_systemctl disable --now cubby-task-gc.timer >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/cubby-task-gc.timer" "$UNIT_DIR/cubby-task-gc.service"
  user_systemctl daemon-reload >/dev/null 2>&1 || true
  log "removed the old cubby-task-gc timer"
fi
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'ctr-task-gc'; then
  crontab -l 2>/dev/null | grep -v 'ctr-task-gc' | crontab - || true
fi
rm -f "$BIN_DIR/ctr-task-gc"

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

# イメージ。利用者のユーザーはイメージに含めない（起動時にホストのユーザーを登録する）。
# ベースイメージはホストの OS に合わせる（Claude などがカーネル名から OS を推測しても食い違わないように）。
# image/ の中身（Dockerfile など）とベースイメージのハッシュをラベル cubby.image-hash に記録し、
# どちらかが変わっていれば自動で作り直す（--rebuild なら常に作り直す）。
pick_base() {
  # shellcheck disable=SC1091
  ( . /etc/os-release 2>/dev/null
    major=${VERSION_ID%%.*}
    case "${ID:-}" in
      debian)  if [ -n "${VERSION_ID:-}" ]; then echo "docker.io/library/debian:${VERSION_ID}-slim"; else echo "docker.io/library/debian:testing-slim"; fi ;;
      ubuntu)  echo "docker.io/library/ubuntu:${VERSION_ID}" ;;
      fedora)  echo "registry.fedoraproject.org/fedora:${VERSION_ID}" ;;
      rocky)   echo "docker.io/rockylinux/rockylinux:${major}" ;;
      almalinux|rhel|centos|ol) echo "docker.io/library/almalinux:${major}" ;;
      *) case " ${ID_LIKE:-} " in
           *" debian "*|*" ubuntu "*) echo "docker.io/library/debian:stable-slim" ;;
           *" fedora "*|*" rhel "*|*" centos "*) echo "docker.io/library/almalinux:${major:-9}" ;;
           *) echo "docker.io/library/debian:stable-slim" ;;
         esac ;;
    esac )
}
# 同じ系統の最新版（ホストの版のイメージが取得できないとき）
fallback_base() {
  case "$1" in
    *fedoraproject.org/fedora:*) echo "registry.fedoraproject.org/fedora:latest" ;;
    *ubuntu:*)                   echo "docker.io/library/ubuntu:latest" ;;
    *almalinux:*|*rockylinux*)   echo "docker.io/library/almalinux:latest" ;;
    *)                           echo "docker.io/library/debian:stable-slim" ;;
  esac
}
BASE_IMAGE=${CTR_BASE_IMAGE:-$(pick_base)}
if ! podman image exists "$BASE_IMAGE" && ! podman pull -q "$BASE_IMAGE" >/dev/null 2>&1; then
  fb=$(fallback_base "$BASE_IMAGE")
  warn "could not pull base image $BASE_IMAGE; using $fb"
  BASE_IMAGE=$fb
  podman image exists "$BASE_IMAGE" || podman pull -q "$BASE_IMAGE" >/dev/null 2>&1 \
    || { BASE_IMAGE=docker.io/library/debian:stable-slim; warn "falling back to $BASE_IMAGE"; }
fi
# Windows のエディタで保存して改行が CRLF になっていると RUN 行が壊れるので、LF に揃えてからビルドする
find "$here/image" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
img_hash=$( { printf 'base %s\n' "$BASE_IMAGE"
              cd "$here/image" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
                printf '%s  ' "$f"; sha256sum < "$f" | cut -d' ' -f1
              done; } | sha256sum | cut -c1-16)
have_hash=$(podman image inspect -f '{{index .Labels "cubby.image-hash"}}' "$IMAGE" 2>/dev/null || true)
case "$have_hash" in '<no value>') have_hash= ;; esac
if [ "$rebuild" = 1 ] || [ "$have_hash" != "$img_hash" ]; then
  if [ "$rebuild" = 1 ]; then
    log "rebuilding image $IMAGE on $BASE_IMAGE (--rebuild) ..."
  elif [ -n "$have_hash" ] || podman image exists "$IMAGE"; then
    log "image/ or the base image changed since $IMAGE was built; rebuilding on $BASE_IMAGE ..."
  else
    log "building image $IMAGE on $BASE_IMAGE ..."
  fi
  podman build -q --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --label cubby.image-hash="$img_hash" --label cubby.base-image="$BASE_IMAGE" \
    -t "$IMAGE" "$here/image" >&2
  log "built $IMAGE (base $BASE_IMAGE, hash $img_hash)"
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

# GPU: GPU 付きのコンテナが起動できるか確かめ、detected.env に書く。
#   NVIDIA: ドライバが動いていれば、CDI のデバイス nvidia.com/gpu=all を渡し、nvidia-smi で確かめる
#   AMD:    amdgpu ドライバの描画ノード（/dev/dri/renderD*）があれば、それと /dev/kfd（ROCm 用）を渡し、
#           vulkaninfo で GPU が見えるか確かめる（イメージに Mesa の Vulkan ドライバを入れてある）
#   config.env に CTR_GPU_ARGS を書いた場合は、その引数で起動できるかだけを確かめる
amd_render_nodes() {
  for n in /sys/class/drm/renderD*; do
    [ -e "$n/device/driver" ] || continue
    [ "$(basename "$(readlink -f "$n/device/driver")")" = amdgpu ] && printf '/dev/dri/%s\n' "$(basename "$n")"
  done
  return 0
}
gpu_avail=no gpu_info= gpu_vendor= gpu_auto_args=
if [ "$gpu_mode" != off ]; then
  if [ -n "${CTR_GPU_ARGS:-}" ]; then
    gpu_vendor=custom; gargs=$CTR_GPU_ARGS; gtest=true
  elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    gpu_vendor=nvidia; gargs='--device nvidia.com/gpu=all'; gtest='nvidia-smi -L'
  else
    nodes=$(amd_render_nodes)
    if [ -n "$nodes" ]; then
      gpu_vendor=amd; gargs=
      for d in $nodes /dev/kfd; do [ -e "$d" ] && gargs="$gargs --device $d"; done
      # 誰でも読み書きできる権限でなければ、ホストのユーザーの補助グループ（render・video）をコンテナに引き継ぐ
      for d in $nodes /dev/kfd; do
        [ -e "$d" ] || continue
        case "$(stat -c %A "$d")" in *rw?) ;; *) gargs="$gargs --group-add keep-groups"; break ;; esac
      done
      gargs=${gargs# }; gtest='vulkaninfo --summary'
    fi
  fi
  if [ -n "$gpu_vendor" ]; then
    # shellcheck disable=SC2086
    grc=0
    gout=$(podman run --rm --userns=keep-id --user root --passwd=false --security-opt label=disable \
             --uts=private --network=private $gargs "$IMAGE" $gtest 2>&1 </dev/null) || grc=$?
    case "$gpu_vendor" in
      nvidia)
        if [ "$grc" = 0 ]; then
          n=$(printf '%s\n' "$gout" | grep -c '^GPU [0-9]' || true)
          [ "$n" -gt 0 ] && gpu_info="NVIDIA $n GPU: $(printf '%s\n' "$gout" | sed -n 's/^GPU 0: \([^(]*\).*/\1/p' | sed 's/ *$//')"
        fi ;;
      amd)
        # vulkaninfo は CPU の llvmpipe も表示するので、それ以外の deviceName を探す
        gpu_info=$(printf '%s\n' "$gout" | sed -n 's/^[[:space:]]*deviceName[[:space:]]*=[[:space:]]*//p' | grep -v -i llvmpipe | head -n 1)
        [ -n "$gpu_info" ] || grc=1
        gpu_auto_args=$gargs ;;
    esac
    if [ "$grc" = 0 ]; then
      gpu_avail=yes
      log "GPU containers available ($gpu_vendor${gpu_info:+: $gpu_info}; podman args: $gargs)"
    else
      gpu_info=
      printf '%s\n' "$gout" | tail -n 5 >&2
      case "$gpu_vendor" in
        amd) warn "an AMD GPU is present, but a container cannot use it (device permissions? the login user may need the render/video groups); GPU containers are disabled" ;;
        *)   warn "a $gpu_vendor GPU seems usable on the host, but a GPU container does not start; GPU containers are disabled" ;;
      esac
    fi
  else
    log "no usable GPU on this host (gpu-* connections are disabled)"
  fi
fi
# コンテナ内から別のコンテナを起動するための、ホストの Podman の API ソケット（Docker 互換）。
# ctr-connect がこれをコンテナの /var/run/docker.sock にマウントし、コンテナ内の docker CLI が使う。
# systemd のユーザーセッションがあれば podman.socket を有効にする（使われたときだけ podman が起動する）。
psock=
if [ "${CTR_HOST_PODMAN:-yes}" != no ]; then
  if command -v systemctl >/dev/null 2>&1 && user_systemctl show-environment >/dev/null 2>&1; then
    user_systemctl enable --now podman.socket >/dev/null 2>&1 \
      || warn "could not enable podman.socket (systemctl --user enable --now podman.socket)"
  fi
  rt=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  if [ -S "$rt/podman/podman.sock" ]; then
    psock="$rt/podman/podman.sock"
    log "host podman API socket: $psock (containers can start other containers with docker)"
  else
    warn "no podman API socket at $rt/podman/podman.sock; containers cannot start other containers (without systemd: run 'podman system service --time=0 &' on the host)"
  fi
fi
{
  echo "# written by setup-host.sh (cubby). Do not edit; override in config.env instead."
  echo "CTR_GPU_AVAILABLE=$gpu_avail"
  echo "CTR_GPU_INFO='$(printf '%s' "$gpu_info" | tr -d "'")'"
  echo "CTR_GPU_VENDOR='$gpu_vendor'"
  echo "CTR_GPU_AUTO_ARGS='$gpu_auto_args'"
  echo "CTR_PODMAN_SOCKET='$psock'"
} > "$CONF_DIR/detected.env"

# マウントの設定が変わったのに作り直していないコンテナを知らせる
sig=$(ctr_mount_sig)
outdated=
for c in $(podman ps -a --filter label=ctr.managed=true --format '{{.Names}}' 2>/dev/null); do
  [ "$(ctr_container_sig "$c")" = "$sig" ] || outdated="$outdated $c"
done
[ -z "$outdated" ] || warn "containers created with older mount settings:$outdated (recreated automatically on the next connect when nobody is connected, or now with: ctr-recreate <name>)"
# イメージを作り直したのに、古いイメージのままのコンテナを知らせる
oldimg=
for c in $(podman ps -a --filter label=ctr.managed=true --format '{{.Names}}' 2>/dev/null); do
  ctr_image_outdated "$c" && oldimg="$oldimg $c"
done
[ -z "$oldimg" ] || warn "containers still using an older image:$oldimg (recreated automatically on the next connect when nobody is connected, or now with: ctr-recreate <name>)"

log "done (host id: ${CTR_HOST_ID:-unset})"
printf 'CUBBY_USER %s\n' "$(id -un)"
printf 'CUBBY_AUTO %s\n' "$auto_mode"
[ ! -r "$CONF_DIR/deploy_key.pub" ] || [ ! -r "$AU" ] || printf 'CUBBY_DEPLOY_KEY %s\n' "$(cat "$CONF_DIR/deploy_key.pub")"
printf 'CUBBY_GPU %s %s\n' "$gpu_avail" "$gpu_info"
printf 'CUBBY_HOSTKEY %s\n' "$(cut -d' ' -f1,2 "$key.pub")"
