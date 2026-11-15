#!/bin/sh
# host/preflight.sh : リモートホストの事前確認。何も変更しない。
# 手元からは: ssh <host> sh -s < host/preflight.sh
set -u

CONF=${CTR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cubby/config.env}
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
REPO=${CTR_REPO:-/srv/project}
WT_ROOT=${CTR_WT_ROOT:-/srv/worktrees}

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }

run uname -a
run sh -c '. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"'
run podman version
run git --version
run id
if [ "$REPO" != none ]; then
  run stat -c '%U %u %G %g %n' "$REPO" "$REPO/.git"
  run df -h "$HOME" "$REPO"
fi

printf '\n== checks ==\n'
chk() { if eval "$2"; then echo "OK   $1"; else echo "NG   $1${3:+ -- $3}"; fi; }
for c in podman git flock ssh-keygen tar; do
  chk "$c is installed" "command -v $c >/dev/null 2>&1"
done
chk "podman runs rootless" "[ \"\$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)\" = true ]"
chk "/etc/subuid has $(id -un)" "grep -q '^$(id -un):' /etc/subuid 2>/dev/null" "needed for --userns=keep-id"
chk "linger is enabled" "[ \"\$(loginctl show-user $(id -un) -p Linger --value 2>/dev/null)\" = yes ]" \
    "sudo loginctl enable-linger $(id -un)"
if [ "$REPO" = none ]; then
  echo "--   no repository on this host (CTR_REPO=none; work without git)"
else
  chk "$REPO/.git exists and is writable" "[ -w '$REPO/.git' ]"
  chk "$REPO/.git is owned by $(id -un)" "[ \"\$(stat -c %u '$REPO/.git' 2>/dev/null)\" = $(id -u) ]"
fi
if [ -d "$WT_ROOT" ]; then
  chk "$WT_ROOT is writable" "[ -w '$WT_ROOT' ]"
else
  chk "$WT_ROOT can be created" "[ -w \"\$(dirname '$WT_ROOT')\" ]" "sudo install -d -o $(id -un) $WT_ROOT"
fi
