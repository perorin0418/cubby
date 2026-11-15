#!/bin/sh
# ctr-entrypoint : コンテナの起動時（コンテナ内の root）に、ホストのログインユーザーを
# コンテナの /etc/passwd・/etc/group に登録してから、引数のコマンド（sshd）を実行する。
#
# イメージには利用者のユーザーを作らない。ホストのユーザー（名前・UID・GID・ホームのパス）を
# そのまま使う。--userns=keep-id で、コンテナ内の同じ UID がホストのそのユーザーに対応する。
# sshd はログインするユーザーが /etc/passwd にいることを求めるので、ここで登録する。
#
#   CTR_USER  ホストのユーザー名      CTR_UID  ホストの UID
#   CTR_GID   ホストの GID            CTR_HOME ホストのホームのパス（コンテナのホームもここ）
#   CTR_SUDO  no 以外なら、そのユーザーにパスワードなしの sudo を許可する（既定 yes）
#
# 環境変数がなければ（動作確認用の podman run など）何もせずにコマンドを実行する。
# 登録に失敗しても sshd は起動する（コンテナを止めず、ログで原因を追えるようにする）。
set -u

write_claude_md() {
  h=$1 cu=$2 cg=$3
  f="$h/.claude/CLAUDE.md"
  mkdir -p "$h/.claude"
  [ "$(stat -c %u "$h/.claude")" = "$cu" ] || chown "$cu:$cg" "$h/.claude"
  # shellcheck disable=SC1091
  os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  if command -v apt-get >/dev/null 2>&1; then pkg="sudo apt-get install -y <パッケージ>"; else pkg="sudo dnf install -y <パッケージ>"; fi
  work=${CTR_WORK:-}
  ttl=${CTR_TASK_TTL_HOURS:-72}
  block=$(mktemp)
  {
    echo '<!-- >>> cubby: この区切りの中はコンテナの起動のたびに自動で書き換わります。書き足すなら区切りの外へ >>> -->'
    echo '# この環境について（cubby）'
    echo
    echo "- ここは **$os** のコンテナです（ホストと同じ OS・版）。Claude Code はこのコンテナの中で動いています。"
    echo "- 作業ディレクトリ: \`$work\`（ホストと同じパス）。ホームはこのコンテナ専用で、ホストのホームとは別です。"
    echo "- \`sudo\` はパスワードなしで使えます。OS のパッケージは \`$pkg\` で入れられます（コンテナを作り直すと消えます）。"
    echo '- 入っているツール: go, java (Temurin 21), node/npm/npx (LTS), python3/pip3/venv, jq, yq, kubectl, helm, aws, docker/docker compose, git, curl。'
    if [ -S /var/run/docker.sock ]; then
      echo '- `docker` はホストの Podman につながっています。起動したコンテナはホスト上の兄弟のコンテナになります（`localhost` で使うなら `--network container:$(hostname)`）。'
      echo
      echo '## 作業ごとのコンテナ（必ず守ること）'
      echo
      echo 'ユーザーの依頼（作業）ごとに、別々の **作業用コンテナ** の中でコマンドを実行してください。作業どうしで環境を混ぜないためです。'
      echo
      echo '1. 作業を始めるときに **作業名** を決める（英小文字・数字・ハイフン。例: 庶務A → `shomu-a`）。どの作業か分からなければユーザーに確認する。続きの作業なら前と同じ作業名を使う。'
      echo "2. コマンドは \`cubby-task sh <作業名> '<コマンド>'\` で実行する（初回に作業用コンテナが自動で作られる）。このコンテナで直接コマンドを実行しない（ファイルの読み書きは除く）。"
      echo "3. その作業のファイルは作業フォルダ \`$work/tasks/<作業名>\`（\`cubby-task path <作業名>\`）に置く。作業用コンテナからも同じパスで見える。ほかの作業のフォルダには触らない。"
      echo '4. 作業用コンテナの中は root で、`apt-get` / `dnf` などで自由にパッケージを入れてよい（ほかの作業には影響しない）。'
      echo "5. 作業用コンテナは最後に使ってから ${ttl} 時間で自動で消える（作業フォルダは残る）。自分で消さない（ユーザーに頼まれたときだけ \`cubby-task rm <作業名>\`）。"
      echo '6. `cubby-task list` で作業用コンテナの一覧が見られる。'
    fi
    echo '<!-- <<< cubby <<< -->'
  } > "$block"
  if [ -f "$f" ]; then
    # 前回の区切りを取り除き、新しい区切りを先頭に置く
    awk '
      index($0, "<!-- >>> cubby:") == 1 { skip = 1; next }
      skip && index($0, "<!-- <<< cubby <<< -->") == 1 { skip = 0; eat = 1; next }
      skip { next }
      eat && $0 == "" { eat = 0; next }
      { eat = 0; print }' "$f" > "$f.rest"
    { cat "$block"; echo; cat "$f.rest"; } > "$f"
    rm -f "$f.rest"
  else
    cat "$block" > "$f"
  fi
  rm -f "$block"
  chown "$cu:$cg" "$f"
}

if [ -n "${CTR_USER:-}" ] && [ -n "${CTR_UID:-}" ] && [ -n "${CTR_GID:-}" ] && [ -n "${CTR_HOME:-}" ]; then
  u=$CTR_USER uid=$CTR_UID gid=$CTR_GID home=$CTR_HOME

  # グループ: その GID がなければ作る（名前はユーザー名。使われていれば別名）
  if ! getent group "$gid" >/dev/null; then
    groupadd -g "$gid" "$u" 2>/dev/null || groupadd -g "$gid" "cubby$gid"
  fi

  # ユーザー: 同じ名前 → 設定を合わせる / 同じ UID の別名（例 ubuntu）→ 名前を変える / なければ登録
  if getent passwd "$u" >/dev/null; then
    [ "$(id -u "$u")" = "$uid" ] || usermod -o -u "$uid" "$u"
    usermod -g "$gid" -d "$home" -s /bin/bash "$u"
  elif other=$(getent passwd "$uid" | cut -d: -f1) && [ -n "$other" ]; then
    usermod -l "$u" -g "$gid" -d "$home" -s /bin/bash "$other"
  else
    useradd -M -N -u "$uid" -g "$gid" -d "$home" -s /bin/bash "$u"
  fi

  # sudo（CTR_SUDO=no でなければ、パスワードなしで許可する。ユーザーにパスワードはないため）。
  # コンテナ内の root は rootless Podman のユーザー名前空間の中の root で、ホストの root ではない。
  if [ "${CTR_SUDO:-yes}" != no ] && [ -d /etc/sudoers.d ]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > /etc/sudoers.d/cubby
    chmod 440 /etc/sudoers.d/cubby
  else
    rm -f /etc/sudoers.d/cubby
  fi

  # ホーム（コンテナごとのボリューム）。初回は空なので、所有者を合わせて /etc/skel を入れる。
  # chown -R はしない: ホームの下には追加マウント（ホストのディレクトリ）があり得るので、
  # ホームそのものと、ここで入れたファイルだけの所有者を変える。
  mkdir -p "$home"
  if [ "$(stat -c %u "$home")" != "$uid" ]; then
    chown "$uid:$gid" "$home" || true
  fi
  # ホームの下のマウント（作業ディレクトリ・追加マウント）のために podman が作った途中の
  # ディレクトリ（例 ~/.cache、~/cubby）は root の所有になるので、利用者が中に書けるよう所有者を直す。
  # マウントそのもの（ホストのディレクトリ）には触らない。
  sed 's/\\040/ /g' /proc/self/mountinfo | awk '{print $5}' | while IFS= read -r m; do
    case "$m" in "$home"/*) ;; *) continue ;; esac
    d=$(dirname "$m")
    while [ "${#d}" -gt "${#home}" ]; do
      if [ "$(stat -c %u "$d" 2>/dev/null)" = 0 ]; then
        chown "$uid:$gid" "$d" && chmod 755 "$d" || true
      fi
      d=$(dirname "$d")
    done
  done

  # SSH のセッションには podman run -e の環境変数が届かないので、cubby-task などが使う値をファイルに残す
  mkdir -p /etc/cubby
  {
    echo "CTR_NAME='${CTR_NAME:-}'"
    echo "CTR_WORK='${CTR_WORK:-}'"
    echo "CTR_IMAGE='${CTR_IMAGE:-localhost/ctr-dev:latest}'"
    echo "CTR_TASK_TTL_HOURS='${CTR_TASK_TTL_HOURS:-72}'"
  } > /etc/cubby/session.env
  chmod 644 /etc/cubby/session.env

  # Claude Code への説明（~/.claude/CLAUDE.md）。cubby が管理する区切りの中だけを毎回書き換え、
  # 利用者が書いた部分は残す。
  write_claude_md "$home" "$uid" "$gid" || true

  if [ ! -e "$home/.bashrc" ] && [ -d /etc/skel ]; then
    for f in /etc/skel/.[!.]* /etc/skel/*; do
      [ -e "$f" ] || continue
      t="$home/$(basename "$f")"
      [ -e "$t" ] && continue
      cp -a "$f" "$t" && chown -R "$uid:$gid" "$t" || true
    done
  fi
fi

exec "$@"
