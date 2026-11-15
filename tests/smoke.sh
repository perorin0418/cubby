#!/bin/sh
# tests/smoke.sh <host-id> [--cleanup]
#
# 受け入れテストのうち CLI で確かめられる項目を、手元の PC から実行する。
# Windows（Git Bash）・macOS・Linux で動く。ssh は cubby と同じもの（Windows は Windows 標準の OpenSSH）を使う。
#
# 前提: `client/cubby add-host <host-id> ...` を実行済み（ssh_config・鍵・イメージが揃っている）。
#
# テスト用の名前（既定 ctr-smoke）のコンテナ・作業ディレクトリ・ボリュームをホストに作る。
# 片付け（テスト 12b など実際の削除）は --cleanup を付けたときだけ行う。
#
# 環境変数:
#   CTR_WORK_ROOT    ホストの作業ディレクトリの置き場   （既定: ホストの config.env の値）
#   CTR_SMOKE_NAME   テスト用の名前                     （既定 ctr-smoke）
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

# 作業ディレクトリの置き場（ホストの設定。$HOME などはホスト側で展開する）
WORK_ROOT=${CTR_WORK_ROOT:-$(remote '. "${XDG_CONFIG_HOME:-$HOME/.config}/cubby/config.env" 2>/dev/null; echo "${CTR_WORK_ROOT:-$HOME/cubby/work}"' | tr -d '\r')}
WORK="$WORK_ROOT/$NAME"

echo "== smoke test: $CONN via $REMOTE (work root $WORK_ROOT) =="

# 前提: テスト用の名前がまだ使われていないこと（テスト 3 を新規作成で確かめるため）
pre=$(count_containers)
if [ "$pre" != 0 ] || remote "test -e '$WORK'"; then
  echo "$NAME already exists on $REMOTE. Remove it first (ctr-remove $NAME) or set CTR_SMOKE_NAME." >&2
  exit 1
fi

# 1. 不正な名前を拒否する（終了コード 2）
t1=ok
for bad in "'bad name'" "ctr-UPPER" "ctr-x.other-host" "ctr-x.a.$ID" "ctr-x.nogit.$ID" "ctr-x..$ID" "'ctr-a
b'" "x-foo" "ctr-" "ctr--x" "ctr-a/b" "ctr-$(printf 'a%.0s' $(seq 1 41))"; do
  rc=$(remote "$RBIN/ctr-connect $bad </dev/null >/dev/null 2>&1; echo \$?" 2>&1 | tr -d '\r')
  [ "$rc" = 2 ] || { t1=ng; info "name $bad -> exit $rc"; }
done
[ "$t1" = ok ] && ok "1 invalid names / wrong host id are rejected with exit 2" || ng "1 invalid names / wrong host id are rejected with exit 2"

# 3. 同名の同時接続でコンテナが 1 つ（新規作成の競合）
remote "for i in 1 2; do (timeout 30 $RBIN/ctr-connect $NAME </dev/null 2>/dev/null | head -c 8 >/dev/null) & done; wait" >/dev/null 2>&1
n=$(count_containers)
if [ "$n" = 1 ] && remote "test -d '$WORK'"; then
  ok "3 concurrent connects create exactly one container and its work directory"
else
  ng "3 concurrent connects: containers=$n"
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

# 4b. コンテナのユーザーはホストのログインユーザーそのもの（名前・UID・GID・ホームのパス）
hid=$(remote 'echo "$(id -un) $(id -u) $(id -g) $HOME"' | tr -d '\r')
cid=$(cssh 'echo "$(id -un) $(id -u) $(id -g) $HOME"; ls -ld "$HOME" | cut -d" " -f3' 2>/dev/null | tr -d '\r')
if [ "$(printf '%s\n' "$cid" | head -n 1)" = "$hid" ] && [ "$(printf '%s\n' "$cid" | sed -n 2p)" = "${hid%% *}" ]; then
  ok "4b container user is the host user ($hid), owns its home"
else
  ng "4b container user: host '$hid' / container '$(printf '%s' "$cid" | tr '\n' ' ')'"
fi

# 4c. sudo（ホストの CTR_SUDO=no なら使えないこと、それ以外なら使えること）
hsudo=$(remote '. "${XDG_CONFIG_HOME:-$HOME/.config}/cubby/config.env" 2>/dev/null; echo "${CTR_SUDO:-yes}"' | tr -d '\r')
sid=$(cssh 'sudo -n id -u 2>/dev/null' 2>/dev/null | tr -d '\r')
if [ "$hsudo" = no ]; then
  [ -z "$sid" ] && ok "4c sudo is disabled (CTR_SUDO=no)" || ng "4c sudo works although CTR_SUDO=no"
else
  [ "$sid" = 0 ] && ok "4c sudo works without a password (sudo id -u -> 0)" || ng "4c sudo: '$sid'"
fi

# T. 開発ツール（イメージに入れたもの）が動く
missing=$(cssh 'for c in go java node npm python3 pip3 jq yq kubectl helm aws docker; do command -v $c >/dev/null 2>&1 || printf "%s " $c; done; node -e "process.exit(0)" 2>/dev/null || printf "node(run) "; java -version >/dev/null 2>&1 || printf "java(run) "' 2>/dev/null | tr -d '\r')
[ -z "$missing" ] && ok "T1 dev tools are available (go java node npm python3 pip3 jq yq kubectl helm aws docker)" \
                   || ng "T1 missing tools: $missing"

# D. コンテナ内から別のコンテナを起動できる（ホストの Podman の API ソケット）
hsock=$(remote 'sed -n "s/^CTR_PODMAN_SOCKET=//p" "${XDG_CONFIG_HOME:-$HOME/.config}/cubby/detected.env" 2>/dev/null' | tr -d "\r'")
if [ -z "$hsock" ]; then
  sk "D1 no podman API socket on $REMOTE (containers cannot start other containers)"
else
  # 兄弟のコンテナで作業ディレクトリを同じパスでマウントし、書いたものが見えるか（イメージはホストにあるものを使う）
  out=$(cssh "cd '$WORK' && echo from-sibling-test > d1.txt && docker run --rm -v '$WORK:$WORK' localhost/ctr-dev:latest cat '$WORK/d1.txt'; rm -f '$WORK/d1.txt'" 2>&1 | tr -d '\r' | tail -n 1)
  [ "$out" = from-sibling-test ] && ok "D1 docker run inside the container starts a sibling container (work dir shared at the same path)" \
                                 || ng "D1 docker run inside the container: $out"
fi

# 5. 作業ディレクトリ: 空で始まり、ホストと同じパスで見え、書いたものがホストから見える
if [ "$(cssh "ls -A '$WORK' | wc -l" 2>/dev/null | tr -d ' \r')" = 0 ] \
   && cssh "echo hi > '$WORK/ctr-smoke-file'" >/dev/null 2>&1 \
   && [ "$(remote "cat '$WORK/ctr-smoke-file'" | tr -d '\r')" = hi ] \
   && [ "$(remote "stat -c %U '$WORK/ctr-smoke-file'" | tr -d '\r')" = "$(remote 'id -un' | tr -d '\r')" ]; then
  ok "5 work directory starts empty at the same path; files written in the container appear on the host, owned by the login user"
else
  ng "5 work directory"
fi
remote "rm -f '$WORK/ctr-smoke-file'"

# 5b. コンテナ内で git を使える（clone の代わりに init/commit で確かめる。ネットワークに依存しない）
if out=$(cssh "cd '$WORK' && git init -q demo && cd demo && echo a > a.txt && git add a.txt && git -c user.name=smoke -c user.email=smoke@invalid commit -q -m first && git log --oneline | wc -l" 2>&1) \
   && [ "$(printf '%s' "$out" | tr -d ' \r')" = 1 ]; then
  ok "5b git works inside the container (init/commit in the work directory)"
else
  ng "5b git in container: $out"
fi

# 11. コンテナを作り直しても接続でき、ホームと作業ディレクトリが残る
cssh 'echo keep > ~/.ctr-smoke-marker' >/dev/null 2>&1
remote "podman rm -f $NAME >/dev/null"
if [ "$(cssh 'cat ~/.ctr-smoke-marker' 2>/dev/null | tr -d '\r')" = keep ] && cssh "test -f '$WORK/demo/a.txt'" >/dev/null 2>&1; then
  ok "11 reconnect after podman rm -f works; home and work directory are kept"
else
  ng "11 reconnect after podman rm -f (home or work directory missing, or connect failed)"
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

# O. コンテナの OS がホストの OS に合っている（Debian・Ubuntu・Fedora のホスト。ほかは Debian になる）
hos=$(remote '. /etc/os-release; echo "$ID $VERSION_ID"' | tr -d '\r')
cos=$(cssh '. /etc/os-release; echo "$ID $VERSION_ID"' 2>/dev/null | tr -d '\r')
case "${hos%% *}" in
  debian|ubuntu|fedora) want=$hos ;;
  *) want= ;;
esac
if [ -z "$want" ]; then
  sk "O1 host OS '$hos' has no matching base image; container OS is '$cos'"
elif [ "$cos" = "$want" ]; then
  ok "O1 container OS matches the host ($cos)"
else
  ng "O1 container OS '$cos' differs from the host '$hos'"
fi

# R. 古くなったコンテナは、誰もつないでいない接続のときに自動で作り直される
#    （マウントの設定を一時的に変えて古くし、最後に元に戻す）
MF='${XDG_CONFIG_HOME:-$HOME/.config}/cubby/mounts'
created() { remote "podman container inspect -f '{{.Created}}' $NAME" | tr -d '\r'; }
# 1 本目の接続を開いておき、その間にコンテナを古くする（マウントの設定を変える）
rssh -o BatchMode=yes "$CONN" 'sleep 25' </dev/null >/dev/null 2>&1 &
bg=$!
sleep 6
remote "touch $MF; cp $MF $MF.smoke-bak; echo '/tmp:/ctr-smoke-tmp:ro' >> $MF"
c1=$(created)
# 2 本目でつなぐ → 1 本目がつないでいるので作り直さない
r_busy=$(cssh "test -e /ctr-smoke-tmp && echo mounted || echo not-mounted" 2>/dev/null | tr -d '\r')
c2=$(created)
wait "$bg" 2>/dev/null
sleep 2
# 誰もつないでいない → 接続のときに作り直す
r_idle=$(cssh "test -e /ctr-smoke-tmp && echo mounted || echo not-mounted" 2>/dev/null | tr -d '\r')
c3=$(created)
remote "mv -f $MF.smoke-bak $MF"
if [ "$c1" = "$c2" ] && [ "$r_busy" = not-mounted ]; then
  ok "R1 an outdated container is not recreated while someone is connected"
else
  ng "R1 busy: created $c1 -> $c2, mount $r_busy"
fi
if [ "$c3" != "$c2" ] && [ "$r_idle" = mounted ] && cssh "test -f ~/.ctr-smoke-marker" >/dev/null 2>&1; then
  ok "R2 an outdated container is recreated on connect when nobody is connected (home kept)"
else
  ng "R2 idle: created $c2 -> $c3, mount $r_idle"
fi

# 12a. ctr-remove: 作業ディレクトリが空でなければ止まり、中の git の未コミットの変更を知らせる
cssh "echo b > '$WORK/demo/b.txt'" >/dev/null 2>&1
out=$(remote "$RBIN/ctr-remove -y $NAME" 2>&1); rc=$?
if [ "$rc" != 0 ] && remote "test -d '$WORK'" && [ "$(count_containers)" = 1 ] \
   && printf '%s\n' "$out" | grep -q 'demo: 1 uncommitted'; then
  ok "12a ctr-remove stops on a non-empty work directory and reports uncommitted changes in git repos"
else
  ng "12a ctr-remove on non-empty work dir: exit=$rc"
  printf '%s\n' "$out" | sed 's/^/      /'
fi

# 12b. ctr-remove --force: 片付く（--cleanup のときだけ実際に削除する）
if [ "$cleanup" = 1 ]; then
  if remote "$RBIN/ctr-remove -y --force $NAME" >/dev/null 2>&1 \
     && [ "$(count_containers)" = 0 ] \
     && ! remote "test -e '$WORK'" \
     && ! remote "podman volume exists $NAME-home"; then
    ok "12b ctr-remove --force removes container, work directory and volume"
  else
    ng "12b ctr-remove did not clean up completely"
  fi
else
  sk "12b ctr-remove cleanup (run with --cleanup, or run: ctr-remove --force $NAME on $REMOTE)"
fi

# G. GPU（gpu-<作業名>）。ホストの detected.env の結果に従って確かめる
GNAME="gpu-${NAME#ctr-}"
GWORK="$WORK_ROOT/$GNAME"
gavail=$(remote "sed -n 's/^CTR_GPU_AVAILABLE=//p' \"\${XDG_CONFIG_HOME:-\$HOME/.config}/cubby/detected.env\" 2>/dev/null" | tr -d '\r')
if [ "$gavail" = yes ]; then
  if remote "test -e '$GWORK'" || [ "$(remote "podman ps -aq --filter label=ctr.name=$GNAME | wc -l" | tr -d ' \r')" != 0 ]; then
    sk "G1 $GNAME already exists on $REMOTE (remove it first to test GPU containers)"
  else
    out=$(rssh -o BatchMode=yes "$GNAME.$ID" 'hostname; nvidia-smi -L' </dev/null 2>/dev/null | tr -d '\r')
    if printf '%s\n' "$out" | head -n 1 | grep -qx "$GNAME" && printf '%s\n' "$out" | grep -q '^GPU 0'; then
      ok "G1 $GNAME.$ID sees the GPU: $(printf '%s\n' "$out" | grep -m1 '^GPU 0')"
    else
      ng "G1 $GNAME.$ID: $out"
    fi
    glabel=$(remote "podman container inspect -f '{{index .Config.Labels \"ctr.gpu\"}}' $GNAME" | tr -d '\r')
    [ "$glabel" = yes ] && ok "G2 $GNAME is labeled ctr.gpu=yes" || ng "G2 label ctr.gpu=$glabel"
    if [ "$cleanup" = 1 ]; then
      remote "$RBIN/ctr-remove -y $GNAME" >/dev/null 2>&1 && ok "G3 ctr-remove $GNAME" || ng "G3 ctr-remove $GNAME"
    fi
  fi
else
  rc=$(remote "$RBIN/ctr-connect $GNAME.$ID </dev/null >/dev/null 2>&1; echo \$?" | tr -d '\r')
  if [ "$rc" = 2 ] && ! remote "test -e '$GWORK'"; then
    ok "G1 no GPU on $REMOTE: $GNAME.$ID is rejected with exit 2 and nothing is created"
  else
    ng "G1 $GNAME.$ID on a host without GPU -> exit $rc"
  fi
fi

echo
echo "result: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
