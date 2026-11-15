#!/bin/sh
# tests/smoke.sh <host-id> [--cleanup]
#
# 受け入れテストのうち CLI で確かめられる項目（1〜6, 11, 12）を、手元の PC から実行する。
# Windows（Git Bash）・macOS・Linux で動く。ssh は cubby と同じもの（Windows は Windows 標準の OpenSSH）を使う。
#
# 前提: `client/cubby add-host <host-id> ...` を実行済み（ssh_config・鍵・イメージが揃っている）。
#
# テスト用の名前（既定 ctr-smoke）のコンテナ・worktree・ボリューム・ブランチをホストに作る。
# 片付け（テスト 12 の後半＝実際の削除）は --cleanup を付けたときだけ行う。ブランチは消さない。
#
# 環境変数:
#   CTR_REPO         ホストの元リポジトリ             （既定: ホストの config.env の値）
#   CTR_WT_ROOT      ホストの worktree の置き場       （既定: ホストの config.env の値）
#   CTR_SMOKE_NAME   テスト用の名前                   （既定 ctr-smoke）
#   CUBBY_SSH_DIR    cubby と同じく ~/.ssh 以外を使うとき
set -u

ID=${1:-}
[ -n "$ID" ] || { echo "usage: $0 <host-id> [--cleanup]" >&2; exit 2; }
cleanup=0
[ "${2:-}" = --cleanup ] && cleanup=1

here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=client/cubby-lib.sh
. "$here/client/cubby-lib.sh"
REMOTE=$(cubby_alias_of "$ID")
[ -n "$REMOTE" ] || { echo "host $ID is not registered in $SSH_CONFIG; run: client/cubby add-host $ID ..." >&2; exit 2; }
RBIN=.local/bin
NAME=${CTR_SMOKE_NAME:-ctr-smoke}
CONN="$NAME.$ID"

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$*"; }
ng()   { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
sk()   { skip=$((skip + 1)); printf 'SKIP  %s\n' "$*"; }
info() { printf '      %s\n' "$*"; }

# リモートホストでシェル文字列を実行する
remote() { rssh -o BatchMode=yes "$REMOTE" "$1" </dev/null; }

# コンテナに SSH で入ってシェル文字列を実行する
cssh() { rssh -o BatchMode=yes "$CONN" "$1" </dev/null; }

count_containers() {
  remote "podman ps -aq --filter label=ctr.name=$NAME | wc -l" | tr -d ' \r'
}

# ホストの設定（元リポジトリ・worktree の置き場）を読む。環境変数があればそちらを優先する。
hostconf() {
  remote "sed -n 's/^$1=//p' \"\${XDG_CONFIG_HOME:-\$HOME/.config}/cubby/config.env\" 2>/dev/null | tail -n 1" | tr -d '\r'
}
REPO=${CTR_REPO:-$(hostconf CTR_REPO)}; REPO=${REPO:-/srv/project}
WT_ROOT=${CTR_WT_ROOT:-$(hostconf CTR_WT_ROOT)}; WT_ROOT=${WT_ROOT:-/srv/worktrees}
WT="$WT_ROOT/$NAME"
norepo=0; [ "$REPO" = none ] && norepo=1

echo "== smoke test: $CONN via $REMOTE =="

# 前提: テスト用の名前がまだ使われていないこと（テスト 3 を新規作成で確かめるため）
pre=$(count_containers)
if [ "$pre" != 0 ] || remote "test -e '$WT'"; then
  echo "$NAME already exists on $REMOTE. Remove it first (ctr-remove $NAME) or set CTR_SMOKE_NAME." >&2
  exit 1
fi

# 1. 不正な名前を拒否する（終了コード 2）
t1=ok
for bad in "'bad name'" "ctr-UPPER" "ctr-x.other-host" "ctr-x.a.b" "ctr-x.bogus.$ID" "ctr-x..$ID" "'ctr-a
b'" "x-foo" "ctr-" "ctr--x" "ctr-a/b" "ctr-$(printf 'a%.0s' $(seq 1 41))"; do
  remote "$RBIN/ctr-connect $bad </dev/null >/dev/null 2>&1; echo \$?" > /tmp/ctr-smoke.$$ 2>&1
  rc=$(tr -d '\r' < /tmp/ctr-smoke.$$)
  [ "$rc" = 2 ] || { t1=ng; info "name $bad -> exit $rc"; }
done
rm -f /tmp/ctr-smoke.$$
[ "$t1" = ok ] && ok "1 invalid names / wrong host id are rejected with exit 2" || ng "1 invalid names / wrong host id are rejected with exit 2"

# 3. 同名の同時接続でコンテナが 1 つ（新規作成の競合）
remote "for i in 1 2; do (timeout 30 $RBIN/ctr-connect $NAME </dev/null 2>/dev/null | head -c 8 >/dev/null) & done; wait" >/dev/null 2>&1
n=$(count_containers)
if [ "$norepo" = 1 ]; then
  nwt=$(remote "test -d '$WT' && ! test -e '$WT/.git' && echo 1 || echo 0" | tr -d '\r')
else
  nwt=$(remote "git -C '$REPO' worktree list --porcelain | grep -c '^worktree $WT\$'" | tr -d '\r')
fi
if [ "$n" = 1 ] && [ "$nwt" = 1 ]; then
  ok "3 concurrent connects create exactly one container and one worktree"
else
  ng "3 concurrent connects: containers=$n worktrees=$nwt"
fi

# 2. 標準出力に SSH 以外が出ない
banner=$(remote "timeout 20 $RBIN/ctr-connect $NAME </dev/null 2>/dev/null | head -c 8")
if [ "$banner" = "SSH-2.0-" ]; then
  ok "2 stdout starts with SSH-2.0-"
else
  ng "2 stdout starts with '$banner' (expected SSH-2.0-)"
fi

# 2 回目でも増えない
n=$(count_containers)
[ "$n" = 1 ] && ok "2b reconnect does not create another container" || ng "2b containers=$n after reconnect"

# 4. CLI で接続でき、ホスト名が接続名になる
h=$(cssh hostname 2>/dev/null | tr -d '\r')
[ "$h" = "$NAME" ] && ok "4 ssh $CONN hostname -> $h" || ng "4 ssh $CONN hostname -> $h"

if [ "$norepo" = 1 ]; then
# 5n. リポジトリのないホスト: 作業ディレクトリはただのディレクトリで、書いたものがホストから見える
if cssh "cd '$WT' && test ! -e .git && echo hi > ctr-smoke-file" >/dev/null 2>&1 \
   && [ "$(remote "cat '$WT/ctr-smoke-file'" | tr -d '\r')" = hi ]; then
  ok "5n work directory is a plain directory (no .git) and the host sees files written in it"
else
  ng "5n plain work directory"
fi
remote "rm -f '$WT/ctr-smoke-file'"
sk "5/5b/5c/6 git tests (this host has no repository)"
else
# 5. worktree で commit でき、ホストから見える
msg="ctr-smoke $(date +%s)"
if out=$(cssh "cd '$WT' && git -c user.name=ctr-smoke -c user.email=ctr-smoke@invalid commit --allow-empty -q -m '$msg' && git log -1 --format=%s" 2>&1); then
  seen=$(remote "git -C '$REPO' log -1 --format=%s '$NAME'" | tr -d '\r')
  if [ "$seen" = "$msg" ]; then
    ok "5 commit in container is visible on host branch $NAME"
    info "test commit left on branch $NAME (remove it after confirmation)"
  else
    ng "5 host sees '$seen' on $NAME (expected '$msg')"
  fi
else
  ng "5 commit failed: $out"
fi

# 5b. fetch / status も通る（.git だけのマウントで動くかの確認）
if out=$(cssh "cd '$WT' && git status --short >/dev/null && git rev-parse --show-toplevel" 2>&1) \
   && [ "$(printf '%s' "$out" | tr -d '\r')" = "$WT" ]; then
  ok "5b git status / rev-parse work with only .git mounted"
else
  ng "5b git status / rev-parse: $out"
fi
if remote "git -C '$REPO' remote | grep -q ." >/dev/null 2>&1; then
  if out=$(cssh "cd '$WT' && git fetch --dry-run" 2>&1); then
    ok "5c git fetch --dry-run works"
  else
    ng "5c git fetch --dry-run failed (credentials or network inside container?): $out"
  fi
else
  sk "5c git fetch (repository has no remote)"
fi

# 6. 元リポジトリの作業ディレクトリを書けない
if cssh "touch '$REPO/README.md'" >/dev/null 2>&1; then
  ng "6 could write $REPO/README.md from container"
else
  ok "6 cannot write $REPO/README.md from container"
fi

# N. 同じホストで git なしの作業（接続名に .nogit）
NG="$NAME-ng"
if remote "test -e '$WT_ROOT/$NG'" || [ "$(remote "podman ps -aq --filter label=ctr.name=$NG | wc -l" | tr -d ' \r')" != 0 ]; then
  sk "N1-N3 $NG already exists on $REMOTE"
else
  out=$(rssh -o BatchMode=yes "$NG.nogit.$ID" "cd '$WT_ROOT/$NG' && pwd; test -e .git && echo HAS_GIT; echo hi > note.txt; hostname" </dev/null 2>/dev/null | tr -d '\r')
  if printf '%s\n' "$out" | grep -qx "$WT_ROOT/$NG" && ! printf '%s\n' "$out" | grep -q HAS_GIT \
     && printf '%s\n' "$out" | grep -qx "$NG" \
     && ! remote "git -C '$REPO' show-ref --verify --quiet refs/heads/$NG"; then
    ok "N1 $NG.nogit.$ID works in a plain directory (no .git, no branch created)"
  else
    ng "N1 $NG.nogit.$ID: $out"
  fi
  r1=$(remote "$RBIN/ctr-connect $NAME.nogit.$ID </dev/null >/dev/null 2>&1; echo \$?" | tr -d '\r')
  r2=$(remote "$RBIN/ctr-connect $NG.$ID </dev/null >/dev/null 2>&1; echo \$?" | tr -d '\r')
  if [ "$r1" = 2 ] && [ "$r2" = 2 ]; then
    ok "N2 connecting with the other kind is refused (git worktree via .nogit, plain dir without it)"
  else
    ng "N2 kind mismatch: $NAME.nogit -> $r1, $NG (no .nogit) -> $r2"
  fi
  remote "$RBIN/ctr-remove -y $NG" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 0 ] && remote "test -f '$WT_ROOT/$NG/note.txt'"; then
    ok "N3a ctr-remove refuses a non-empty plain work directory"
  else
    ng "N3a ctr-remove on non-empty plain dir: exit=$rc"
  fi
  if [ "$cleanup" = 1 ]; then
    if remote "$RBIN/ctr-remove -y --force $NG" >/dev/null 2>&1 && ! remote "test -e '$WT_ROOT/$NG'"; then
      ok "N3b ctr-remove --force removes the plain work directory"
    else
      ng "N3b ctr-remove --force $NG"
    fi
  fi
fi
fi

# 11. コンテナを作り直しても接続でき、ホームが残る
cssh 'echo keep > ~/.ctr-smoke-marker' >/dev/null 2>&1
remote "podman rm -f $NAME >/dev/null"
if [ "$(cssh 'cat ~/.ctr-smoke-marker' 2>/dev/null | tr -d '\r')" = keep ]; then
  ok "11 reconnect after podman rm -f works and home is kept"
else
  ng "11 reconnect after podman rm -f (home marker missing or connect failed)"
fi

# M. 追加マウント（ホストの ~/.config/cubby/mounts）。設定は変えず、設定済みのものを確かめる
specs=$(remote 'CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cubby"; . .local/bin/ctr-common.sh && ctr_mount_specs quiet' 2>/dev/null | tr -d '\r')
if [ -z "$specs" ]; then
  sk "M1 no extra mounts configured on $REMOTE (cubby add-host $ID --mount ...)"
else
  m_ok=1
  # パスに空白を含むことがあるので、1 行ずつ読む
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    dst=${spec%:*}; dst=${dst#*:}; mode=${spec##*:}
    if ! cssh "test -e '$dst'" >/dev/null 2>&1; then m_ok=0; info "$dst is not visible in $NAME"; continue; fi
    if [ "$mode" = ro ] && cssh "touch '$dst/.ctr-smoke-ro' 2>/dev/null" >/dev/null 2>&1; then
      m_ok=0; info "$dst is writable although mounted ro"
      cssh "rm -f '$dst/.ctr-smoke-ro'" >/dev/null 2>&1
    fi
  done <<EOF
$specs
EOF
  [ "$m_ok" = 1 ] && ok "M1 extra mounts are visible in $NAME ($(printf '%s\n' "$specs" | wc -l | tr -d ' ') mount(s), ro enforced)" \
                  || ng "M1 extra mounts"
fi

# 12. ctr-remove: 未コミットがあれば止まる
remote "echo x > '$WT/ctr-smoke-untracked'"
remote "$RBIN/ctr-remove -y $NAME" >/dev/null 2>&1
rc=$?
if [ "$rc" != 0 ] && remote "test -d '$WT'" && [ "$(count_containers)" = 1 ]; then
  ok "12a ctr-remove stops on uncommitted changes / a non-empty work dir and removes nothing"
else
  ng "12a ctr-remove with uncommitted changes: exit=$rc"
fi
remote "rm -f '$WT/ctr-smoke-untracked'"

# 12. ctr-remove: 片付く（--cleanup のときだけ実際に削除する）
if [ "$cleanup" = 1 ]; then
  if remote "$RBIN/ctr-remove -y $NAME" >/dev/null 2>&1 \
     && [ "$(count_containers)" = 0 ] \
     && ! remote "test -e '$WT'" \
     && ! remote "podman volume exists $NAME-home"; then
    ok "12b ctr-remove removes container, worktree and volume (branch $NAME kept)"
  else
    ng "12b ctr-remove did not clean up completely"
  fi
else
  sk "12b ctr-remove cleanup (run with --cleanup, or run: ctr-remove $NAME on $REMOTE)"
fi

# G. GPU（gpu-<作業名>）。ホストの detected.env の結果に従って確かめる
GNAME="gpu-${NAME#ctr-}"
GWT="$WT_ROOT/$GNAME"
gavail=$(remote "sed -n 's/^CTR_GPU_AVAILABLE=//p' \"\${XDG_CONFIG_HOME:-\$HOME/.config}/cubby/detected.env\" 2>/dev/null" | tr -d '\r')
if [ "$gavail" = yes ]; then
  if remote "test -e '$GWT'" || [ "$(remote "podman ps -aq --filter label=ctr.name=$GNAME | wc -l" | tr -d ' \r')" != 0 ]; then
    sk "G1 $GNAME already exists on $REMOTE (remove it first to test GPU containers)"
  else
    out=$(rssh -o BatchMode=yes "$GNAME.$ID" 'hostname; nvidia-smi -L' </dev/null 2>/dev/null | tr -d '\r')
    if printf '%s\n' "$out" | head -n 1 | grep -qx "$GNAME" && printf '%s\n' "$out" | grep -q '^GPU 0'; then
      ok "G1 $GNAME.$ID sees the GPU: $(printf '%s\n' "$out" | grep -m1 '^GPU 0')"
    else
      ng "G1 $GNAME.$ID: $out"
    fi
    glabel=$(remote "podman container inspect -f '{{index .Config.Labels \"ctr.gpu\"}}' $GNAME" | tr -d '\r')
    nolabel=$(remote "podman container inspect -f '{{index .Config.Labels \"ctr.gpu\"}}' $NAME 2>/dev/null || echo gone" | tr -d '\r')
    [ "$glabel" = yes ] && ok "G2 $GNAME is labeled ctr.gpu=yes (ctr- container: $nolabel)" || ng "G2 label ctr.gpu=$glabel"
    if [ "$cleanup" = 1 ]; then
      remote "$RBIN/ctr-remove -y $GNAME" >/dev/null 2>&1 && ok "G3 ctr-remove $GNAME" || ng "G3 ctr-remove $GNAME"
    fi
  fi
else
  rc=$(remote "$RBIN/ctr-connect $GNAME.$ID </dev/null >/dev/null 2>&1; echo \$?" | tr -d '\r')
  if [ "$rc" = 2 ] && ! remote "test -e '$GWT'"; then
    ok "G1 no GPU on $REMOTE: $GNAME.$ID is rejected with exit 2 and nothing is created"
  else
    ng "G1 $GNAME.$ID on a host without GPU -> exit $rc"
  fi
fi

echo
echo "result: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
