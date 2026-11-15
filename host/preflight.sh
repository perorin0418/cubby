#!/bin/sh
# host/preflight.sh : リモートホストの事前確認。何も変更しない。
# 手元からは: cubby preflight <id>（ssh <host> sh -s < host/preflight.sh）
set -u

CONF=${CTR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cubby/config.env}
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
WORK_ROOT=${CTR_WORK_ROOT:-$HOME/cubby/work}

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }

run uname -a
run sh -c '. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"'
run podman version
run id
run df -h "$HOME"

printf '\n== checks ==\n'
chk() { if eval "$2"; then echo "OK   $1"; else echo "NG   $1${3:+ -- $3}"; fi; }
for c in podman flock ssh-keygen tar; do
  chk "$c is installed" "command -v $c >/dev/null 2>&1"
done
chk "podman runs rootless" "[ \"\$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)\" = true ]"
chk "/etc/subuid has $(id -un)" "grep -q '^$(id -un):' /etc/subuid 2>/dev/null" "needed for --userns=keep-id"
chk "linger is enabled" "[ \"\$(loginctl show-user $(id -un) -p Linger --value 2>/dev/null)\" = yes ]" \
    "sudo loginctl enable-linger $(id -un)"
if [ -d "$WORK_ROOT" ]; then
  chk "$WORK_ROOT is writable" "[ -w '$WORK_ROOT' ]"
else
  p=$(dirname "$WORK_ROOT"); while [ ! -e "$p" ]; do p=$(dirname "$p"); done
  chk "$WORK_ROOT can be created" "[ -w '$p' ]" "sudo install -d -o $(id -un) $WORK_ROOT"
fi
command -v nvidia-smi >/dev/null 2>&1 && chk "NVIDIA driver works" "nvidia-smi -L >/dev/null 2>&1"
