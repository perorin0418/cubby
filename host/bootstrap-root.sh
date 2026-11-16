#!/bin/sh
# host/bootstrap-root.sh --user USER [--gpu auto|off] [--check]
#
# rootless Podman で cubby を動かすための、root 権限が要る準備をする。
# 通常は手元の `client/cubby add-host` から自動で呼ばれる。何度実行しても同じ結果になる。
#
#   --check  root 不要。準備が要るかだけを調べる（終了コード 0: 不要、10: 要る、1: 続行不可）
#   （なし） root で実行する。足りないものだけを用意する:
#     - パッケージ: podman, git, flock, ssh-keygen, tar, newuidmap/newgidmap など
#     - /etc/subuid・/etc/subgid に USER の範囲（65536 個）
#     - USER の linger（SSH が切れてもコンテナと Claude Code 本体を動かし続ける）
#     - GPU（--gpu auto のとき。既定）: AMD の GPU があり、その装置ファイルを USER が使えなければ、
#       USER を所有グループ（render・video）に加える。NVIDIA のドライバが動いていれば、
#       NVIDIA Container Toolkit を入れ、CDI の定義（/etc/cdi/nvidia.yaml）を作る。
#       ドライバの版が変わって CDI の定義が古くなっていれば作り直す。
#       ドライバ自体は入れない（カーネル・再起動・Secure Boot が絡むため）。
#
# 既存のディレクトリの所有者や中身は変えない。
set -eu

user= check=0 gpu=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --user)      user=$2; shift 2 ;;
    --work-root) shift 2 ;;   # 旧版のクライアントとの互換のため受け付けて無視する
    --check)     check=1; shift ;;
    --gpu)       gpu=$2; shift 2 ;;
    *) echo "bootstrap: unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$user" ] || {
  echo "usage: $0 --user USER [--gpu auto|off] [--check]" >&2; exit 1; }

log()  { printf 'bootstrap: %s\n' "$*" >&2; }
die()  { printf 'bootstrap: ERROR: %s\n' "$*" >&2; exit 1; }

[ "$user" != root ] || die "log in as a normal user, not root (containers run rootless as that user)"

# git は ctr-remove がホーム内のリポジトリの状態（未コミットの変更など）を調べるのに使う
REQUIRED_CMDS="podman git flock ssh-keygen tar newuidmap newgidmap"

missing_cmds() {
  for c in $REQUIRED_CMDS; do command -v "$c" >/dev/null 2>&1 || printf '%s ' "$c"; done
}
has_subid() { grep -q "^$user:" "$1" 2>/dev/null; }

# ---- GPU（NVIDIA） ----
CDI_SPEC=/etc/cdi/nvidia.yaml
nvidia_driver_ok() { [ "$gpu" = auto ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }
nvidia_hw_present() {
  [ -e /proc/driver/nvidia/version ] && return 0
  command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'nvidia' && return 0
  return 1
}
driver_version() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d ' \r'; }
# CDI の定義があり、今のドライバの版で作られているか（ドライバ更新後は作り直しが要る）
cdi_fresh() {
  [ -r "$CDI_SPEC" ] || return 1
  v=$(driver_version)
  [ -z "$v" ] || grep -qF "$v" "$CDI_SPEC"
}
# ---- GPU（AMD） ----
# amdgpu ドライバの描画ノードと /dev/kfd のうち、USER が読み書きできないもの
amd_blocked_nodes() {
  [ "$gpu" = auto ] || return 0
  for n in /sys/class/drm/renderD*; do
    [ -e "$n/device/driver" ] || continue
    [ "$(basename "$(readlink -f "$n/device/driver")")" = amdgpu ] || continue
    for d in "/dev/dri/$(basename "$n")" /dev/kfd; do
      [ -e "$d" ] || continue
      if [ "$check" = 1 ]; then
        [ -r "$d" ] && [ -w "$d" ] && continue
      elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- sh -c "[ -r '$d' ] && [ -w '$d' ]" && continue
      else
        su "$user" -s /bin/sh -c "[ -r '$d' ] && [ -w '$d' ]" && continue
      fi
      printf '%s
' "$d"
    done
  done | sort -u
}

# GPU のために root が要る作業: 出力が空なら不要
gpu_needs() {
  [ -z "$(amd_blocked_nodes)" ] || printf 'amd-device-groups '
  nvidia_driver_ok || return 0
  command -v nvidia-ctk >/dev/null 2>&1 || { printf 'nvidia-container-toolkit '; }
  cdi_fresh || printf 'cdi-spec '
}
install_nvidia_toolkit() {
  log "installing NVIDIA Container Toolkit from NVIDIA's repository"
  base=https://nvidia.github.io/libnvidia-container
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >&2
    apt-get install -y -q curl gnupg ca-certificates >&2
    curl -fsSL "$base/gpgkey" | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL "$base/stable/deb/nvidia-container-toolkit.list" \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -q >&2
    apt-get install -y -q nvidia-container-toolkit >&2
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    curl -fsSL "$base/stable/rpm/nvidia-container-toolkit.repo" > /etc/yum.repos.d/nvidia-container-toolkit.repo
    if command -v dnf >/dev/null 2>&1; then dnf install -y -q nvidia-container-toolkit >&2
    else yum install -y -q nvidia-container-toolkit >&2; fi
  elif command -v zypper >/dev/null 2>&1; then
    zypper -n ar -f "$base/stable/rpm/nvidia-container-toolkit.repo" >&2 2>/dev/null || true
    zypper -n --gpg-auto-import-keys install nvidia-container-toolkit >&2
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed nvidia-container-toolkit >&2
  else
    log "WARNING: do not know how to install nvidia-container-toolkit here; GPU containers stay disabled"
    return 1
  fi
}
# newuidmap/newgidmap が setuid か file capability を持っているか（ないと rootless で名前空間を作れない）
uidmap_ok() {
  for b in newuidmap newgidmap; do
    p=$(command -v "$b" 2>/dev/null) || return 1
    [ -u "$p" ] && continue
    # getcap がなければ判断できないので、問題なしとみなす（推測で setuid を付けない）
    command -v getcap >/dev/null 2>&1 || continue
    getcap "$p" 2>/dev/null | grep -q 'cap_set[ug]id' && continue
    return 1
  done
}
linger_needed() {
  command -v loginctl >/dev/null 2>&1 || return 1
  [ -d /run/systemd/system ] || return 1
  [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" != yes ]
}

# ---- 調べるだけ ----
if [ "$check" = 1 ]; then
  need=
  m=$(missing_cmds); [ -z "$m" ] || need="$need packages($m)"
  [ -n "$m" ] || uidmap_ok || need="$need uidmap-caps"
  has_subid /etc/subuid || need="$need subuid"
  has_subid /etc/subgid || need="$need subgid"
  if linger_needed; then need="$need linger"; fi
  g=$(gpu_needs); [ -z "$g" ] || need="$need gpu($g)"
  if [ -n "$need" ]; then log "needs root for:$need"; exit 10; fi
  exit 0
fi

# ---- root で準備する ----
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

# パッケージ
m=$(missing_cmds)
if [ -n "$m" ]; then
  log "installing packages (missing: $m)"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >&2
    apt-get install -y -q podman uidmap slirp4netns fuse-overlayfs git openssh-client util-linux tar >&2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q podman git-core util-linux openssh-clients tar shadow-utils >&2
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q podman git util-linux openssh-clients tar shadow-utils >&2
  elif command -v zypper >/dev/null 2>&1; then
    zypper -n -q install podman git-core util-linux openssh-clients tar shadow >&2
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed podman git util-linux openssh tar shadow >&2
  elif command -v apk >/dev/null 2>&1; then
    apk add -q podman git util-linux openssh-keygen tar shadow-uidmap fuse-overlayfs >&2
  else
    die "unknown package manager (${PRETTY_NAME:-unknown OS}); install: $m"
  fi
  m=$(missing_cmds)
  [ -z "$m" ] || die "still missing after install: $m"
fi

# newuidmap/newgidmap の権限（パッケージ本来の状態に戻す。コンテナ内で入れたときなどに失われる）
if ! uidmap_ok; then
  if command -v rpm >/dev/null 2>&1; then
    rpm --setcaps shadow-utils >&2 2>/dev/null || true
  fi
  if ! uidmap_ok; then
    for b in newuidmap newgidmap; do chmod u+s "$(command -v "$b")"; done
    log "set the setuid bit on newuidmap/newgidmap"
  else
    log "restored file capabilities of newuidmap/newgidmap"
  fi
fi

# subuid / subgid（既存の範囲と重ならない場所に 65536 個）
add_subid() {
  f=$1
  touch "$f"
  has_subid "$f" && return 0
  start=$(awk -F: 'BEGIN{m=100000} NF>=3 {e=$2+$3; if (e>m) m=e} END{print m}' "$f")
  printf '%s:%s:65536\n' "$user" "$start" >> "$f"
  log "added $user:$start:65536 to $f"
  migrate=1
}
migrate=0
add_subid /etc/subuid
add_subid /etc/subgid
if [ "$migrate" = 1 ]; then
  # ユーザー側で podman system migrate を実行させる目印（setup-host.sh が見る）
  home=$(getent passwd "$user" | cut -d: -f6)
  install -d -o "$user" -m 700 "$home/.config" "$home/.config/cubby" 2>/dev/null || true
  touch "$home/.config/cubby/.needs-migrate" && chown "$user" "$home/.config/cubby/.needs-migrate"
fi

# linger
if linger_needed; then
  loginctl enable-linger "$user"
  log "enabled linger for $user"
fi

# GPU（AMD）: 描画ノード・/dev/kfd を USER が使えなければ、その所有グループ（render・video）に USER を加える
for d in $(amd_blocked_nodes); do
  g=$(stat -c %G "$d")
  if [ -n "$g" ] && [ "$g" != root ] && ! id -nG "$user" | tr ' ' '
' | grep -qx "$g"; then
    usermod -aG "$g" "$user" && log "added $user to group $g (for $d; takes effect on the next login)"
  fi
done

# GPU（NVIDIA）
if nvidia_driver_ok; then
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    install_nvidia_toolkit || true
  fi
  if command -v nvidia-ctk >/dev/null 2>&1 && ! cdi_fresh; then
    mkdir -p "$(dirname "$CDI_SPEC")"
    if nvidia-ctk cdi generate --output="$CDI_SPEC" >&2; then
      log "generated CDI spec $CDI_SPEC (driver $(driver_version))"
    else
      log "WARNING: nvidia-ctk cdi generate failed; GPU containers stay disabled"
    fi
  fi
elif [ "$gpu" = auto ] && nvidia_hw_present; then
  log "WARNING: an NVIDIA GPU seems present but nvidia-smi does not work; install the NVIDIA driver (needs a reboot), then rerun cubby add-host"
fi

log "root setup done"
