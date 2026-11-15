# client/cubby-lib.sh : cubby と tests/smoke.sh が共有する、手元の OS ごとの差を吸収する部分。
# sh で読み込む（. client/cubby-lib.sh）。Windows（Git Bash）・macOS・Linux に対応する。
#
# 設定される変数:
#   CUBBY_OS     windows | mac | linux
#   SSH_BIN      使う ssh（Windows は Windows 標準の OpenSSH の ssh.exe）
#   SSH_ADD_BIN  使う ssh-add
#   SSH_DIR      ssh の設定ディレクトリ（CUBBY_SSH_DIR で変更可。テスト用）
#   SSH_CONFIG   $SSH_DIR/config
#   KNOWN_HOSTS  $SSH_DIR/known_hosts
#   CUSTOM_DIR   1 なら SSH_DIR が既定と違う（ssh に -F を付ける）

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) CUBBY_OS=windows ;;
  Darwin)               CUBBY_OS=mac ;;
  *)                    CUBBY_OS=linux ;;
esac

if [ "$CUBBY_OS" = windows ]; then
  # Git Bash から Windows のプログラム（ssh.exe）に渡す引数を、パスとして書き換えさせない
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  # Claude Desktop と同じく、Windows 標準の OpenSSH（と Windows の ssh-agent）を使う
  win_ssh_dir=
  for d in "$(cygpath -u "${SYSTEMROOT:-C:/Windows}")/System32/OpenSSH" /c/Windows/System32/OpenSSH; do
    if [ -x "$d/ssh.exe" ]; then win_ssh_dir=$d; break; fi
  done
  if [ -n "$win_ssh_dir" ]; then
    SSH_BIN="$win_ssh_dir/ssh.exe"
    SSH_ADD_BIN="$win_ssh_dir/ssh-add.exe"
  else
    printf 'cubby: ERROR: %s\n' "Windows OpenSSH client not found. Enable it: Settings > System > Optional features > OpenSSH Client" >&2
    exit 1
  fi
  default_ssh_dir="$(cygpath -u "${USERPROFILE:-$HOME}")/.ssh"
else
  SSH_BIN=$(command -v ssh) || { printf 'cubby: ERROR: ssh not found\n' >&2; exit 1; }
  SSH_ADD_BIN=$(command -v ssh-add || echo ssh-add)
  default_ssh_dir="$HOME/.ssh"
fi

SSH_DIR=${CUBBY_SSH_DIR:-$default_ssh_dir}
SSH_CONFIG="$SSH_DIR/config"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
CUSTOM_DIR=0
[ "$SSH_DIR" = "$default_ssh_dir" ] || CUSTOM_DIR=1

# ssh_config に書くためのパス（Windows は C:/Users/... の形にする）
natpath() {
  if [ "$CUBBY_OS" = windows ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# 手元の ssh を呼ぶ
rssh() {
  if [ "$CUSTOM_DIR" = 1 ]; then
    "$SSH_BIN" -F "$(natpath "$SSH_CONFIG")" "$@"
  else
    "$SSH_BIN" "$@"
  fi
}

# パスワードを渡す SSH_ASKPASS 用の小さなプログラムを作り、そのパスを出す。
# パスワードそのものはファイルに書かず、環境変数 CUBBY_ASKPASS_PW で渡す。
# 使い終わったら呼び出し側で消す。
make_askpass() {
  d=$(mktemp -d)
  chmod 700 "$d"
  if [ "$CUBBY_OS" = windows ]; then
    # Windows 標準の ssh.exe はスクリプトを直接実行できないので .cmd から PowerShell で出力する
    # （cmd の echo では & や % などの記号を含むパスワードが壊れるため）
    printf '@powershell.exe -NoProfile -NonInteractive -Command "[Console]::Out.Write($env:CUBBY_ASKPASS_PW)"\r\n' \
      > "$d/askpass.cmd"
    natpath "$d/askpass.cmd"
  else
    printf '#!/bin/sh\nprintf "%%s\\n" "$CUBBY_ASKPASS_PW"\n' > "$d/askpass"
    chmod 700 "$d/askpass"
    printf '%s\n' "$d/askpass"
  fi
}

# パスワードを読む。端末なら表示せずに尋ね、端末でなければ標準入力から 1 行読む（自動化用）。
read_secret() {
  if [ -t 0 ]; then
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r secret || secret=
    stty echo 2>/dev/null || true
    echo >&2
  else
    IFS= read -r secret || secret=
  fi
}

# ~/.ssh/config の cubby の管理ブロックから、ホスト ID の SSH 名を読む
#   # >>> cubby <id> ssh-host=<alias> >>>
cubby_alias_of() {
  sed -n "s/^# >>> cubby $1 ssh-host=\\([^ ]*\\) >>>\$/\\1/p" "$SSH_CONFIG" 2>/dev/null | head -n 1
}
cubby_ids() {
  sed -n 's/^# >>> cubby \([^ ]*\) ssh-host=[^ ]* >>>$/\1/p' "$SSH_CONFIG" 2>/dev/null
}
