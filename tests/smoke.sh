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
#   CTR_REPO         ホストの元リポジトリ             （既定 /srv/project）
#   CTR_WT_ROOT      ホストの worktree の置き場       （既定 /srv/worktrees）
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
REPO=${CTR_REPO:-/srv/project}
WT_ROOT=${CTR_WT_ROOT:-/srv/worktrees}
NAME=${CTR_SMOKE_NAME:-ctr-smoke}
CONN="$NAME.$ID"
WT="$WT_ROOT/$NAME"

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

echo "== smoke test: $CONN via $REMOTE =="

# 前提: テスト用の名前がまだ使われていないこと（テスト 3 を新規作成で確かめるため）
pre=$(count_containers)
if [ "$pre" != 0 ] || remote "test -e '$WT'"; then
  echo "$NAME already exists on $REMOTE. Remove it first (ctr-remove $NAME) or set CTR_SMOKE_NAME." >&2
  exit 1
fi

# 1. 不正な名前を拒否する（終了コード 2）
t1=ok
for bad in "'bad name'" "ctr-UPPER" "ctr-x.other-host" "ctr-x.a.b" "'ctr-a
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
nwt=$(remote "git -C '$REPO' worktree list --porcelain | grep -c '^worktree $WT\$'" | tr -d '\r')
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

# 11. コンテナを作り直しても接続でき、ホームが残る
cssh 'echo keep > ~/.ctr-smoke-marker' >/dev/null 2>&1
remote "podman rm -f $NAME >/dev/null"
if [ "$(cssh 'cat ~/.ctr-smoke-marker' 2>/dev/null | tr -d '\r')" = keep ]; then
  ok "11 reconnect after podman rm -f works and home is kept"
else
  ng "11 reconnect after podman rm -f (home marker missing or connect failed)"
fi

# 12. ctr-remove: 未コミットがあれば止まる
remote "echo x > '$WT/ctr-smoke-untracked'"
remote "$RBIN/ctr-remove -y $NAME" >/dev/null 2>&1
rc=$?
if [ "$rc" != 0 ] && remote "test -d '$WT'" && [ "$(count_containers)" = 1 ]; then
  ok "12a ctr-remove stops on uncommitted changes and removes nothing"
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

echo
echo "result: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
