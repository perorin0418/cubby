# cubby

Claude Desktop の SSH 接続で、**接続名（例 `ctr-feature1`）ごとに専用の Docker コンテナ**を自動で用意し、その中で Claude Code を動かすための仕組みです。

- 同じ接続名なら、何度つないでも同じコンテナに戻ります。
- 違う接続名なら、別のコンテナ・別の作業ディレクトリ（git worktree）になります。
- 新しいコンテナがほしいときは、Desktop に新しい名前の SSH 接続を追加するだけです。

構成図と設計の詳細は [docs/claude-desktop-ssh-container.html](docs/claude-desktop-ssh-container.html) と [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) を参照してください。

## しくみ

```
Claude Desktop ──SSH(ctr-xxx)──▶ ProxyCommand: ssh remote-host ctr-connect ctr-xxx
                                    │ コンテナ・worktree がなければ作る / 止まっていれば起動
                                    ▼
                                 docker exec -i ctr-xxx nc 127.0.0.1 22
                                    ▼
                                 コンテナ内 sshd → dev ユーザー → Claude Code 本体（~/.claude/remote/）
```

| 物 | 場所 |
|---|---|
| コンテナ | `ctr-xxx`（ラベル `ctr.managed=true`）。ポートは公開しない |
| ホーム | 名前付きボリューム `ctr-xxx-home` → `/home/dev` |
| 作業ディレクトリ | `/srv/worktrees/ctr-xxx`（ブランチ `ctr-xxx` の git worktree） |
| 元リポジトリ | `/srv/project/.git` だけをマウント（作業ディレクトリ本体は書き換えられない） |
| ホスト鍵 | `/etc/ctr/hostkeys`（全コンテナ共通・読み取り専用でマウント） |
| 公開鍵 | `/etc/ctr/authorized_keys/dev`（読み取り専用でマウント） |

## リポジトリの中身

```
config.env.example      設定の見本（実値はリモートホストの /etc/ctr/config.env にだけ置く）
image/Dockerfile        コンテナイメージ（sshd, nc, git, dev ユーザー）
image/ctr-sshd.conf     コンテナ内 sshd の設定
bin/ctr-connect         ProxyCommand から呼ばれる本体
bin/ctr-list            管理下のコンテナ・ボリューム・worktree の一覧
bin/ctr-remove          片付け
host/preflight.sh       リモートホストの事前確認（変更しない）
host/setup-host.sh      ホスト鍵・authorized_keys・ディレクトリ・スクリプトの準備
client/ssh_config.snippet  手元の ~/.ssh/config に追記する内容
tests/smoke.sh          CLI で確かめられる受け入れテスト（手元から実行）
```

## 初期設定

### リモートホスト（Linux）

必要なもの: docker（ログインユーザーが sudo なしで実行できること）、git 2.17 以降、flock（util-linux）、ssh-keygen。

> docker グループへの所属は実質 root 権限です。共用ホストでは管理者に可否を確認してください。

```sh
git clone <this repo> ~/cubby && cd ~/cubby

# 1. 事前確認（何も変更しない）
sh host/preflight.sh

# 2. 準備（sudo を使う。何度実行しても既存の鍵は上書きしない）
#    手元の公開鍵をホストにコピーしておき、そのパスを渡す
sh host/setup-host.sh ~/id_ed25519.pub
#    必要なら /etc/ctr/config.env を編集する

# 3. イメージのビルド（dev の UID/GID を元リポジトリの所有者に合わせる）
docker build \
  --build-arg DEV_UID=$(stat -c %u /srv/project/.git) \
  --build-arg DEV_GID=$(stat -c %g /srv/project/.git) \
  -t ctr-dev:latest image/
```

### 手元の PC

1. [client/ssh_config.snippet](client/ssh_config.snippet) を `~/.ssh/config` の `Host *` より**上**に追記し、`remote-host` を実際のホスト名に置き換えます。
2. Desktop からはパスフレーズを入力できないので、鍵を ssh-agent に登録します。
3. ターミナルで一度つないで、コンテナのホスト鍵（`dev-containers`）を受け入れます。

   ```sh
   ssh ctr-test hostname   # → ctr-test
   ```

4. Claude Desktop の Code タブで「+ Add SSH connection」→ SSH Host に `ctr-test` を指定します。

## 日常の使い方

- **新しい作業を始める**: Desktop に新しい名前（`ctr-` で始まる英小文字・数字・ハイフン、44 文字以内）の SSH 接続を追加するだけです。初回接続時にブランチ・worktree・コンテナが作られます。既に同名のブランチがあれば、そのブランチで worktree を作ります。
- **続きから作業する**: 同じ接続を選びます。Desktop を再起動しても、同じコンテナの Claude Code に戻ります。
- **一覧を見る**: リモートホストで `ctr-list`。

Desktop には登録した SSH 接続を編集・削除する画面がない時期がありました。接続名は作業単位（例 `ctr-feature1`, `ctr-review`）で使い回す運用をおすすめします。

## 片付け

```sh
ctr-remove ctr-feature1          # 対象を表示して確認を求める
ctr-remove -y ctr-feature1       # 確認を省略
ctr-remove --force ctr-feature1  # 未コミットの変更があっても worktree を消す
```

コンテナ → worktree → ホームのボリュームの順で消します。**未コミットの変更があると、何も消さずに止まり**内容を表示します。ブランチは消しません（必要なら `git -C /srv/project branch -d ctr-feature1`）。

## テスト

手元の PC から実行します（リモートホストにテスト用の `ctr-smoke` のコンテナ・worktree・ブランチを作ります）。

```sh
CTR_REMOTE=remote-host sh tests/smoke.sh            # 片付けはしない
CTR_REMOTE=remote-host sh tests/smoke.sh --cleanup  # 最後に ctr-remove で片付ける（ブランチは残る）
```

Desktop での確認（セッションがコンテナ内で動く・再起動後に戻る・別名で別コンテナ・同時に動かしても干渉しない）は手作業で行います。手順は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) の 6.6 を参照してください。

## トラブル時の確認箇所

| 症状 | 確認すること |
|---|---|
| `ssh ctr-xxx` が `kex_exchange_identification` などで即切れる | ProxyCommand 単体で `ssh remote-host ctr-connect ctr-xxx </dev/null \| head -c 8` が `SSH-2.0-` を返すか。標準エラー出力の `ctr-connect:` のメッセージ |
| `invalid name` で終了する | 接続名が `ctr-[a-z0-9][a-z0-9-]*`・44 文字以内か |
| `lock timeout` | 同名の ctr-connect が 60 秒以上準備中のまま残っていないか（`/tmp/ctr-locks`） |
| `sshd not ready` | `docker logs ctr-xxx`。ホスト鍵の権限（root 所有・600）、`/etc/ctr/hostkeys` のマウント |
| `Permission denied (publickey)` | `/etc/ctr/authorized_keys/dev` に手元の公開鍵があるか、root 所有・644 か。ssh-agent に鍵があるか |
| ホスト鍵の警告 | known_hosts の `dev-containers` の記録。ホスト鍵を作り直した場合は `ssh-keygen -R dev-containers` |
| worktree で `dubious ownership` や書き込みエラー | イメージの `DEV_UID`/`DEV_GID` が元リポジトリの所有者と一致しているか |
| Desktop で本体の配置に失敗する | Desktop のログ、コンテナ内の `~/.claude/remote/`。イメージに足りないコマンドやライブラリがないか |

## 注意

- コンテナのポートは公開しません（`-p` を付けない）。
- 秘密鍵・認証情報・`config.env` の実値はコミットしないでください。
- Desktop は Anthropic の認証情報をコンテナ内に置きます。コンテナを他人と共有しないでください。
- Windows 版 Desktop が `Host ctr-*` のパターンや ProxyCommand を解釈するかは未検証です。解釈されない場合は `Host ctr-feature1` のように名前ごとに書いてください。
