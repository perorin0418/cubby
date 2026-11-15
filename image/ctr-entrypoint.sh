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
#
# 環境変数がなければ（動作確認用の podman run など）何もせずにコマンドを実行する。
# 登録に失敗しても sshd は起動する（コンテナを止めず、ログで原因を追えるようにする）。
set -u

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
