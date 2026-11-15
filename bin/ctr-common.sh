# bin/ctr-common.sh : ctr-connect・ctr-list・ctr-recreate・setup-host.sh が共有する部分（sh で読み込む）。
#
# 追加マウントの設定ファイル（既定 ~/.config/cubby/mounts）。そのホストの全コンテナに毎回マウントする。
#   # コメント
#   ホストのパス[:コンテナ内のパス][:ro|rw]
#   /data/datasets:/datasets:ro
#   /scratch                       （コンテナ内も同じパス、rw）
# パスは / で始まる絶対パス。: を含むパスは書けない。マウントはコンテナを作るときに決まるので、
# 変更を既存のコンテナに反映するには ctr-recreate で作り直す。

# 1 行を解釈して「ホストのパス:コンテナ内のパス:モード」を出す。不正なら何も出さず 1 を返す。
ctr_parse_mount() {
  line=$1
  IFS=: read -r f1 f2 f3 f4 <<EOF
$line
EOF
  [ -z "${f4:-}" ] || return 1
  src=$f1 dst= mode=rw
  if [ -n "${f3:-}" ]; then
    dst=$f2 mode=$f3
  elif [ -n "${f2:-}" ]; then
    case "$f2" in ro|rw) mode=$f2 ;; *) dst=$f2 ;; esac
  fi
  [ -n "$dst" ] || dst=$src
  case "$src" in /*) ;; *) return 1 ;; esac
  case "$dst" in /*) ;; *) return 1 ;; esac
  case "$mode" in ro|rw) ;; *) return 1 ;; esac
  # コンテナの動作に必要な場所を上書きさせない（ホーム自体＝ホストのホームと同じパスも。下の階層は可）
  case "$dst" in
    /|/home|/home/|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*)
      return 1 ;;
  esac
  [ "${dst%/}" != "${HOME%/}" ] || return 1
  printf '%s:%s:%s\n' "$src" "$dst" "$mode"
}

# 設定ファイルから、実際に使うマウント（ホストにあるもの）を 1 行ずつ出す。
# $1 が quiet でなければ、不正な行・ホストにないパスを標準エラー出力に警告する。
ctr_mount_specs() {
  quiet=${1:-}
  f=${CTR_MOUNTS_FILE:-$CONF_DIR/mounts}
  [ -r "$f" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    l=$(printf '%s' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$l" in ''|'#'*) continue ;; esac
    if ! spec=$(ctr_parse_mount "$l"); then
      [ "$quiet" = quiet ] || printf 'cubby: WARNING: ignored invalid mount line in %s: %s\n' "$f" "$l" >&2
      continue
    fi
    s=${spec%%:*}
    if [ ! -e "$s" ]; then
      [ "$quiet" = quiet ] || printf 'cubby: WARNING: mount source %s does not exist on this host; skipped\n' "$s" >&2
      continue
    fi
    printf '%s\n' "$spec"
  done < "$f"
}

# 実際に使うマウントの一覧の指紋（コンテナのラベル ctr.mounts に記録し、設定の変更を検出する）
ctr_mount_sig() {
  ctr_mount_specs quiet | cksum | cut -d' ' -f1
}

# コンテナを作ったときのマウントの指紋。ラベルがない（この機能より前に作った）コンテナは
# 追加マウントなしで作られたものとみなす。
ctr_container_sig() {
  s=$(podman container inspect -f '{{index .Config.Labels "ctr.mounts"}}' "$1" </dev/null 2>/dev/null || true)
  case "$s" in ''|'<no value>') s=$(printf '' | cksum | cut -d' ' -f1) ;; esac
  printf '%s\n' "$s"
}

# コンテナが今のイメージ（作り直す前の古いイメージでないか）で作られているか。
# 古ければ 0 を返す（ctr-recreate で作り直すと新しいイメージになる）。
ctr_image_outdated() {
  img=${CTR_IMAGE:-localhost/ctr-dev:latest}
  cur=$(podman image inspect -f '{{.Id}}' "$img" </dev/null 2>/dev/null) || return 1
  used=$(podman container inspect -f '{{.Image}}' "$1" </dev/null 2>/dev/null) || return 1
  [ -n "$cur" ] && [ -n "$used" ] && [ "$cur" != "$used" ]
}
