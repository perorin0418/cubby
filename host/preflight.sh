#!/bin/sh
# host/preflight.sh : フェーズ0（リモートホストの事前確認）。何も変更しない。
# 出力をそのまま記録として残す。
set -u

if [ -r /etc/ctr/config.env ]; then
  # shellcheck disable=SC1091
  . /etc/ctr/config.env
fi
REPO=${CTR_REPO:-/srv/project}
WT_ROOT=${CTR_WT_ROOT:-/srv/worktrees}

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }

run uname -a
run sh -c '. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"'
run docker version
run git --version
run sh -c 'command -v flock'
run sh -c 'command -v ssh-keygen'
run id
run stat -c '%U %u %G %g %n' "$REPO" "$REPO/.git"
run df -h /srv /var/lib/docker

printf '\n== checks ==\n'
if docker info >/dev/null 2>&1; then
  echo "OK   docker runs without sudo"
else
  echo "NG   docker does not run without sudo (docker group = root equivalent; ask before adding)"
fi
if [ -w "$REPO/.git" ]; then echo "OK   $REPO/.git is writable"; else echo "NG   $REPO/.git is not writable"; fi
if [ -d "$WT_ROOT" ]; then
  if [ -w "$WT_ROOT" ]; then echo "OK   $WT_ROOT is writable"; else echo "NG   $WT_ROOT is not writable"; fi
else
  echo "--   $WT_ROOT does not exist yet (setup-host.sh creates it)"
fi
if [ "$(stat -c %u "$REPO/.git" 2>/dev/null)" = "$(id -u)" ]; then
  echo "OK   $REPO/.git is owned by the login user (use DEV_UID=$(id -u) DEV_GID=$(id -g))"
else
  echo "!!   $REPO/.git owner differs from login user; build the image with the repo owner's UID/GID"
fi
