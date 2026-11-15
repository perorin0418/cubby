# 作業書：Claude Desktop の SSH 接続で、接続名ごとに別コンテナの Claude Code を使う環境を作る

作成日：2026-11-15
引き継ぎ先：Claude Code
状態：設計済み・未実装・未検証

---

## 1. 結論（この作業で作るもの）

手元の Claude Desktop から SSH で接続したとき、**接続名（例 `ctr-feature1`）ごとに専用の Docker コンテナが自動で用意され、その中で Claude Code が動く**環境を作る。

- 同じ接続名なら、何度つないでも同じコンテナに戻る。
- 違う接続名なら、別のコンテナになる。作業ディレクトリも別になる。
- 新しいコンテナがほしいときは、Desktop に新しい名前の SSH 接続を追加するだけでよい。

この対応づけは、手元の `~/.ssh/config` に書く **ProxyCommand** で実現する。ProxyCommand は「SSH の通信路として、指定したコマンドの標準入出力を使う」という OpenSSH の設定である。ここではリモートホスト上のスクリプト **ctr-connect** を呼ぶ。ctr-connect は、接続名のコンテナを用意したうえで、コンテナ内の **sshd**（SSH の接続を受け付けるサーバープログラム）と標準入出力をつなぐ。

完了の条件は「8. 受け入れテスト」の全項目が通ることとする。

---

## 2. なぜこの構成で動くのか（根拠）

Claude Desktop の SSH セッションは、画面だけを手元に残し、Claude Code の本体を SSH でログインした先のマシンで動かす。本体は SSH ユーザーのホームディレクトリの `~/.claude/remote/` に自動で配置され、次回以降の接続で再利用される。本体は SSH が切れても、Desktop を終了しても動き続け、Desktop は再接続時にその本体へ戻る。

したがって、SSH のログイン先をコンテナにすれば、Claude Code はコンテナの中で動く。また、再接続のたびに同じ本体へ戻る必要があるため、「接続のたびに新しいコンテナ」ではなく「接続名ごとに固定のコンテナ」にする。

Desktop は、macOS と Linux では端末の OpenSSH クライアントで接続し、`~/.ssh/config` のそのホストの設定を適用する。Windows では内蔵の SSH クライアントを使う。

参考資料：

- Claude Desktop の SSH セッション：https://claude.com/docs/third-party/claude-desktop/ssh-remote-sessions
- Docker のサンドボックスに Desktop を SSH 接続する例：https://docs.docker.com/ai/sandboxes/integrations/claude-desktop.md

---

## 3. 全体構成

```
手元のPC                         リモートホスト remote-host (Linux)
┌──────────────────┐            ┌─────────────────────────────────────────────┐
│ Claude Desktop    │  ①SSH     │ sshd :22（ホストへのログイン）                  │
│  接続: ctr-xxx    │──────────▶│   │ ②ProxyCommand で実行                      │
│ ~/.ssh/config     │            │   ▼                                         │
│  Host ctr-*       │            │ /usr/local/bin/ctr-connect ctr-xxx          │
│  ProxyCommand ... │            │   ・コンテナ/worktree がなければ作る           │
└──────────────────┘            │   ・止まっていれば起動、sshd の起動待ち         │
                                 │   │ ③docker exec -i ctr-xxx nc 127.0.0.1 22 │
                                 │   ▼                                         │
                                 │ ┌ コンテナ ctr-xxx ─────────────────────┐    │
                                 │ │ sshd 127.0.0.1:22                    │    │
                                 │ │  ④ Claude Code 本体 ~/.claude/remote/ │    │
                                 │ │ 作業先 /srv/worktrees/ctr-xxx         │    │
                                 │ └──────────────────────────────────────┘    │
                                 │ ボリューム ctr-xxx-home → /home/dev           │
                                 │ /srv/worktrees/ctr-xxx（git worktree）        │
                                 │ /srv/project/.git（元リポジトリ。全コンテナ共有）│
                                 └─────────────────────────────────────────────┘
```

**git worktree** は、1つのリポジトリから作業ディレクトリを複数作る git の機能である。コンテナごとに worktree を1つ割り当て、並行作業での衝突を防ぐ。

コンテナのポートは外部に公開しない。sshd は 127.0.0.1 だけで待ち受け、`docker exec` 経由でのみ到達できる。

---

## 4. 着手前に利用者へ確認すること

次の値は未確定である。実装に入る前に利用者へ確認し、決まった値を `config.env`（6.1 参照）に反映すること。既定値は仮の案である。

| 項目 | 既定の案 | 補足 |
|---|---|---|
| リモートホストの SSH 名 | `remote-host` | 手元の `~/.ssh/config` での名前 |
| リモートホストの OS | Linux（ディストリビューション未定） | docker、git、flock があること |
| 元リポジトリのパス | `/srv/project` | |
| worktree の置き場 | `/srv/worktrees` | |
| コンテナ内ユーザー | `dev` | UID/GID は元リポジトリの所有者に合わせる（6.2 参照） |
| ベースイメージ | `debian:bookworm-slim` | 開発に必要なツール（言語処理系など）を確認する |
| スクリプトの設置先 | `/usr/local/bin` | sudo が使えなければ `~/bin` にして絶対パスで呼ぶ |
| この成果物を置くリポジトリ | 新規 `ctr-dev-env/` | |
| Windows 版 Desktop の利用有無 | 不明 | 使うなら 9 章の未検証事項を優先して確認する |
| コンテナ内の git の名前とメール | 未定 | 環境変数で渡すか、ホームに設定するか |
| CPU・メモリの上限 | なし | 必要なら `docker run` に `--cpus`、`--memory` を足す |

---

## 5. 作業の進め方（全体ルール）

1. **着手時**：cairn の `wiki_search` で「Claude Desktop SSH」「ProxyCommand」「docker exec nc」「git worktree コンテナ」を検索し、過去の知見を確認する。見つけた知見は過去の観察として扱い、現物で確かめてから使う。
2. **フェーズごと**に、そのフェーズの確認項目を通してから次へ進む。
3. この作業書と、リモートホスト上の既存の設定やコードが食い違うときは、**既存の側に従う**。見つけた食い違いは、すべて完了報告に挙げる。
4. 破壊的な操作は、利用者の確認なしに行わない（10 章参照）。
5. **完了時**：仕様書や規約に書かれていないが、試して初めて分かったことを cairn の `raw_add` で wiki に追記する。認証情報、個人情報、顧客情報は書かない。

---

## 6. 実装手順

### フェーズ0：リモートホストの事前確認

リモートホストで次を確認し、結果を記録する。

```sh
uname -a
docker version            # 実行できるか（docker グループ所属または sudo）
git --version             # 2.17 以降なら worktree の操作に問題はない
command -v flock          # util-linux に含まれる
id                        # ログインユーザーの UID/GID
stat -c '%U %u %G %g' /srv/project /srv/project/.git
df -h /srv /var/lib/docker
```

確認項目：

- ログインユーザーが sudo なしで `docker` を実行できるか。docker グループは実質 root と同じ権限なので、共用ホストなら利用者に可否を確認する。
- ログインユーザーが `/srv/project/.git` と `/srv/worktrees` に書き込めるか。

### フェーズ1：成果物リポジトリの骨組み

```
ctr-dev-env/
├── README.md
├── config.env.example      # 4 章の値。実値の config.env はリモートホストにだけ置く
├── image/
│   ├── Dockerfile
│   └── ctr-sshd.conf
├── bin/
│   ├── ctr-connect         # ProxyCommand から呼ばれる本体
│   ├── ctr-list            # 管理下のコンテナと worktree の一覧
│   └── ctr-remove          # 片付け
├── host/
│   └── setup-host.sh       # ホスト鍵・authorized_keys・ディレクトリの準備
├── client/
│   └── ssh_config.snippet  # 手元の ~/.ssh/config に追記する内容
└── tests/
    └── smoke.sh            # 8 章のうち CLI で確かめられる項目
```

### 6.1 config.env

ctr-connect などのスクリプトは、`/etc/ctr/config.env`（なければ環境変数、さらになければ既定値）から次の値を読む。

```sh
CTR_REPO=/srv/project
CTR_WT_ROOT=/srv/worktrees
CTR_IMAGE=ctr-dev:latest
CTR_HOSTKEYS=/etc/ctr/hostkeys
CTR_AUTHKEYS=/etc/ctr/authorized_keys
CTR_LOCK_DIR=/tmp/ctr-locks
```

### 6.2 フェーズ2：コンテナイメージ

要件：

- Linux イメージであること。Desktop の SSH 接続先は Linux のみ対応と報告されている。
- `openssh-server`、`netcat-openbsd`（nc）、`git`、`ca-certificates`、`curl`、`bash` を入れる。
- ユーザー `dev` を作り、**UID/GID を元リポジトリの所有者と同じ**にする。ずれると、worktree への書き込みや git の所有者チェック（dubious ownership エラー）で失敗する。ビルド引数で渡す。
- `ubuntu:24.04` を使う場合は、既存の `ubuntu` ユーザーが UID 1000 を使っているので削除してから作る。
- パッケージ導入時に生成されたホスト鍵は削除する。ホスト鍵は、接続先が前回と同じ相手かを確かめるための鍵である。全コンテナ共通のホスト鍵をホストから読み取り専用でマウントするので、イメージには含めない（含めるとイメージの配布先に秘密鍵が漏れる）。
- 公開鍵（authorized_keys）もホストからマウントする。ホームはボリュームなので、イメージに入れると後から更新できなくなるため。

Dockerfile の叩き台：

```dockerfile
FROM debian:bookworm-slim
ARG DEV_UID=1000
ARG DEV_GID=1000
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server netcat-openbsd git ca-certificates curl bash \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd \
 && groupadd -g "${DEV_GID}" dev \
 && useradd -m -u "${DEV_UID}" -g dev -s /bin/bash dev
COPY ctr-sshd.conf /etc/ssh/sshd_config.d/ctr.conf
CMD ["/usr/sbin/sshd", "-D", "-e"]
```

`ctr-sshd.conf` の叩き台（Debian の sshd_config は先頭で `sshd_config.d/*.conf` を読み込み、先に読んだ値が優先される）：

```
ListenAddress 127.0.0.1
HostKey /etc/ssh/ctr-hostkeys/ssh_host_ed25519_key
AuthorizedKeysFile /etc/ssh/ctr-authorized_keys/%u
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers dev
```

`AllowTcpForwarding` などの転送系の設定は、Desktop が何を使うか未確認なので、既定のまま変えない。制限する場合はフェーズ5の確認を通してから行う。

確認項目：

- `docker build --build-arg DEV_UID=$(id -u) --build-arg DEV_GID=$(id -g) -t ctr-dev:latest image/` が通る。
- イメージ内に `/etc/ssh/ssh_host_*` が残っていない。

### 6.3 フェーズ3：ホストの準備（host/setup-host.sh）

```sh
sudo mkdir -p /etc/ctr/hostkeys /etc/ctr/authorized_keys
sudo ssh-keygen -t ed25519 -N '' -C ctr-dev-containers \
     -f /etc/ctr/hostkeys/ssh_host_ed25519_key     # 既にあれば作り直さない
sudo install -m 644 -o root -g root <手元の公開鍵> /etc/ctr/authorized_keys/dev
sudo install -d -o <ログインユーザー> /srv/worktrees
```

- ホスト鍵の秘密鍵は root 所有・600 のままにする。sshd は他者が読める秘密鍵を拒否する。
- authorized_keys は root 所有・644 にする。sshd の StrictModes の所有者チェックを通すため。
- スクリプトは何度実行しても同じ結果になるように書く（既存の鍵を上書きしない）。

### 6.4 フェーズ4：ctr-connect

仕様：

- 引数は接続名1つ。`^ctr-[a-z0-9][a-z0-9-]*$` かつ 44 文字以下でなければ終了コード 2 で終わる。検証は `case` 文で行う（grep は改行を含む入力を行ごとに判定するため、すり抜けが起きる）。
- **標準出力は SSH の通信路そのもの**である。ログ、git や docker の出力は、すべて標準エラー出力に回す。1バイトでも標準出力に漏れると SSH の接続が壊れる。
- 同じ名前で同時に接続が来ても、コンテナや worktree が二重に作られないよう、名前ごとに flock で排他する。
- **排他用のファイル記述子は、最後の `exec docker exec` の前に必ず閉じる**。閉じ忘れると、セッション中ずっとロックを持ち続け、同じ名前の2本目の接続が待たされる。
- worktree がなければ作る。ブランチ名は接続名と同じにする。ブランチが既にあれば `-b` を付けずにそのブランチで作る。
- コンテナがなければ作り、止まっていれば起動する。
- コンテナ内の sshd が応答するまで最大 15 秒待つ。
- 最後に `docker exec -i <名前> nc 127.0.0.1 22` を `exec` で実行する。

マウントの方針：

- ホーム：名前付きボリューム `<名前>-home` → `/home/dev`
- worktree：`/srv/worktrees/<名前>` を同じパスにマウント
- 元リポジトリ：**`/srv/project/.git` だけ**を同じパスにマウントする。worktree の `.git` ファイルは元リポジトリの `.git` 内を絶対パスで指すので、`.git` があれば git は動く。元リポジトリの作業ディレクトリ本体をマウントしないことで、コンテナから main のチェックアウトを書き換えられないようにする。この方針は未検証なので、フェーズ5で commit と fetch が通ることを確かめる。通らなければ `/srv/project` 全体のマウントに切り替え、完了報告に書く。

叩き台：

```sh
#!/bin/sh
# ctr-connect <name>
# 標準出力は SSH の通信路。ログやエラーは必ず標準エラー出力へ出す。
set -eu

[ -r /etc/ctr/config.env ] && . /etc/ctr/config.env
REPO=${CTR_REPO:-/srv/project}
WT_ROOT=${CTR_WT_ROOT:-/srv/worktrees}
IMAGE=${CTR_IMAGE:-ctr-dev:latest}
HOSTKEYS=${CTR_HOSTKEYS:-/etc/ctr/hostkeys}
AUTHKEYS=${CTR_AUTHKEYS:-/etc/ctr/authorized_keys}
LOCK_DIR=${CTR_LOCK_DIR:-/tmp/ctr-locks}

log() { printf 'ctr-connect: %s\n' "$*" >&2; }

name=${1:-}
case "$name" in
  ''|*[!a-z0-9-]*) log "invalid name: $name"; exit 2 ;;
  ctr-[a-z0-9]*)   ;;
  *)               log "invalid name: $name"; exit 2 ;;
esac
[ "${#name}" -le 44 ] || { log "name too long: $name"; exit 2; }

wt="$WT_ROOT/$name"

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/$name.lock"
flock -w 60 9 || { log "lock timeout: $name"; exit 1; }

if [ ! -d "$wt" ]; then
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$name"; then
    git -C "$REPO" worktree add "$wt" "$name" 1>&2
  else
    git -C "$REPO" worktree add -b "$name" "$wt" 1>&2
  fi
fi

if ! docker inspect "$name" >/dev/null 2>&1; then
  docker run -d --name "$name" --hostname "$name" \
    --label ctr.managed=true --label ctr.name="$name" \
    --init --restart unless-stopped \
    -v "$name-home:/home/dev" \
    -v "$REPO/.git:$REPO/.git" \
    -v "$wt:$wt" \
    -v "$HOSTKEYS:/etc/ssh/ctr-hostkeys:ro" \
    -v "$AUTHKEYS:/etc/ssh/ctr-authorized_keys:ro" \
    -w "$wt" \
    "$IMAGE" >/dev/null
elif [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
  docker start "$name" >/dev/null
fi

i=0
until docker exec "$name" nc -z 127.0.0.1 22 >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 60 ] && { log "sshd not ready: $name"; exit 1; }
  sleep 0.25
done

exec 9>&-
exec docker exec -i "$name" nc 127.0.0.1 22
```

確認項目（リモートホスト上で）：

- `ctr-connect 'bad name'`、`ctr-connect ctr-UPPER`、改行を含む名前が終了コード 2 で終わる。
- `ctr-connect ctr-test </dev/null | head -c 64` の出力が `SSH-2.0-` で始まる（標準出力に余計なものが出ていない）。
- 2回目の実行でコンテナや worktree が増えない。
- 同じ名前で2本同時に実行しても、コンテナが1つしか作られない。

### 6.5 フェーズ5：手元の SSH 設定と CLI での接続確認

`client/ssh_config.snippet`（手元の `~/.ssh/config` の、`Host *` より上に追記する）：

```
Host ctr-*
  User dev
  ProxyCommand ssh remote-host /usr/local/bin/ctr-connect %n
  HostKeyAlias dev-containers
  ServerAliveInterval 30
```

- `%n` は接続時に指定した名前に置き換わる。もし手元の OpenSSH が ProxyCommand で `%n` を受け付けなければ `%h` を使う（HostName を書いていないので同じ値になる）。
- HostKeyAlias は、ホスト鍵の照合に使う名前を固定する設定である。全コンテナが同じホスト鍵なので、known_hosts の記録は `dev-containers` の1件で済む。
- Desktop からはパスフレーズの入力ができないので、手元の鍵は ssh-agent に登録しておく。

確認項目（手元のターミナルで）：

- `ssh ctr-test hostname` が `ctr-test` を返す。
- `ssh ctr-test 'cd /srv/worktrees/ctr-test && git status && git commit --allow-empty -m test && git log -1 --oneline'` が通る。最後に `git -C /srv/project branch` をホストで実行し、ctr-test ブランチにコミットが見えることを確かめる。テスト用コミットは後で利用者の確認を取って消す。
- `ssh ctr-test 'touch /srv/project/README.md'` が失敗する（作業ディレクトリ本体を書けない）。

### 6.6 フェーズ6：Claude Desktop での確認

利用者に依頼して、Desktop で次を行ってもらう（Claude Code からは Desktop を操作できない）。

1. Code タブの「+ Add SSH connection」で SSH Host に `ctr-test` を指定して接続する。
2. セッションの中で `hostname; pwd; id` を実行させ、`ctr-test`、worktree のパス、`dev` が返ることを確かめる。
3. Desktop を終了して再起動し、同じ接続で前のセッションに戻れることを確かめる。
4. `ctr-test2` を追加し、別のコンテナで動くことを確かめる（`hostname` が `ctr-test2`）。
5. 2つのセッションを同時に動かし、互いの worktree に影響しないことを確かめる。

本体の配置に失敗した場合は、Desktop のログとコンテナ内の `~/.claude/remote/` を確認する。本体がイメージに追加のコマンドやライブラリを要求している可能性がある。分かったことは wiki に追記する。

### 6.7 フェーズ7：運用スクリプト

- `ctr-list`：`docker ps -a --filter label=ctr.managed=true` と `git -C "$REPO" worktree list` を並べて表示する。
- `ctr-remove <名前>`：次の順で片付ける。
  1. 対象を表示し、確認を求める（`-y` で省略可）。
  2. `docker rm -f <名前>`
  3. `git -C "$REPO" worktree remove "$WT_ROOT/<名前>"`。未コミットの変更があって失敗したら、そこで止めて内容を表示する。`--force` は明示の指定があるときだけ付ける。
  4. `docker volume rm <名前>-home`
  5. ブランチは消さない。消すのは利用者が別途判断する。

### 6.8 フェーズ8：README

利用者向けに、初期設定（ホスト、手元）、日常の使い方（新しい名前で接続を追加する）、片付け方、トラブル時の確認箇所を書く。Desktop には登録した SSH 接続を編集・削除する画面がない時期があったので、接続名は作業単位で使い回す運用を勧める。

---

## 7. 設計上の判断（変えるときは利用者と相談する）

| 判断 | 理由 |
|---|---|
| 接続名とコンテナを 1 対 1 で固定する | Desktop は再接続時に、動き続けている本体へ戻るため |
| ポートを公開せず docker exec で接続する | ポートの割り当てが不要。外部から届かない |
| ホスト鍵を全コンテナで共有し、ホストからマウントする | known_hosts を1件で済ませ、イメージに秘密鍵を入れないため |
| authorized_keys をホストからマウントする | ホームはボリュームで、後から更新できなくなるため |
| 元リポジトリは `.git` だけをマウントする | main のチェックアウトをコンテナから書き換えさせないため |
| ブランチ名＝接続名 | 対応関係を追いやすくするため |

---

## 8. 受け入れテスト

| # | 内容 | 確認方法 |
|---|---|---|
| 1 | 不正な名前を拒否する | フェーズ4 |
| 2 | 標準出力に SSH 以外が出ない | フェーズ4（`SSH-2.0-` で始まる） |
| 3 | 同名の同時接続でコンテナが1つ | フェーズ4 |
| 4 | CLI で接続でき、ホスト名が接続名になる | フェーズ5 |
| 5 | worktree で commit でき、ホストから見える | フェーズ5 |
| 6 | 元リポジトリの作業ディレクトリを書けない | フェーズ5 |
| 7 | Desktop のセッションがコンテナ内で動く | フェーズ6-2 |
| 8 | Desktop 再起動後に同じセッションへ戻る | フェーズ6-3 |
| 9 | 別名で別コンテナになる | フェーズ6-4 |
| 10 | 2セッション同時でも干渉しない | フェーズ6-5 |
| 11 | コンテナを作り直しても接続でき、ホームが残る | `docker rm -f` 後に再接続 |
| 12 | ctr-remove で片付き、未コミットがあれば止まる | フェーズ7 |

1〜6、11、12 は `tests/smoke.sh` で自動化する。7〜10 は利用者に依頼する。

---

## 9. 未検証事項とリスク

- **Windows 版 Desktop**：内蔵の SSH クライアントが `Host ctr-*` のパターンや ProxyCommand を解釈するか未確認。ProxyCommand の実行には Git for Windows の sh が必要という報告がある。解釈されない場合は、名前ごとに `Host ctr-feature1` のように個別に書く。
- **Desktop が張る SSH 接続の本数**：1セッションで複数の SSH 接続を同時に張る可能性がある。flock による排他はそのための対策で、テスト3で確かめる。
- **本体の動作要件**：Desktop が配置する本体が、slim イメージで足りないものを要求する可能性がある。フェーズ6で確かめる。
- **`.git` だけのマウント**：git の一部の操作（フックの実行、サブモジュールなど）で元の作業ディレクトリを参照する可能性がある。問題が出たら `/srv/project` 全体のマウントに切り替える。
- **認証情報**：Desktop は Anthropic の認証情報をコンテナ内に置く。コンテナを他人と共有しない。
- **docker 権限**：ログインユーザーの docker 実行権限は、実質ホストの root 権限である。

---

## 10. やってはいけないこと

- コンテナのポートを公開する（`-p` を付ける）。
- 秘密鍵、認証情報、`config.env` の実値をリポジトリにコミットする。
- 利用者の確認なしに、ブランチ、ボリューム、worktree を削除する。テスト用のものも含む。
- `docker system prune` や `docker volume prune` など、管理外のリソースまで消すコマンドを実行する。
- リモートホストの既存の sshd 設定を変更する。

---

## 11. 完了報告に含めるもの

1. 受け入れテストの結果（項目ごとに成否と、失敗時の原因）
2. 4 章の確認事項で決まった値
3. この作業書と既存環境・既存コードの食い違い（すべて）
4. 未検証のまま残った事項
5. cairn に追記した知見の要約
