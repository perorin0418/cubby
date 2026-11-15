# cubby

Claude Desktop の SSH 接続で、**接続名ごとに専用のコンテナ**を自動で用意し、その中で Claude Code を動かすための仕組みです。リモートホストは複数台を使い分けられます。

- 接続名は `ctr-<作業名>.<ホストID>`（例 `ctr-feature1.gpu1`）。ドットの後ろでホストを選びます。
- 同じ接続名なら、何度つないでも同じコンテナに戻ります。
- 違う接続名なら、別のコンテナ・別の作業ディレクトリ（git worktree）になります。
- 新しいコンテナがほしいときは、Desktop に新しい名前の SSH 接続を追加するだけです。
- コンテナは各ホストの **rootless Podman** で動かします（ホストで sudo は不要）。
- ホストへは **Cloudflare Tunnel**（`cloudflared access ssh`）経由で接続できます。
- ホストの登録・公開鍵の登録・ホスト鍵の受け入れは、手元の `cubby add-host` 1 回で済みます。

当初の設計は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) と [docs/claude-desktop-ssh-container.html](docs/claude-desktop-ssh-container.html) にあります（Docker・単一ホスト前提。変更点は末尾の「設計からの変更点」を参照）。

## しくみ

```
Claude Desktop ──SSH(ctr-feat.gpu1)──▶ ~/.ssh/cubby/gpu1.conf の Host ctr-*.gpu1
   ProxyCommand: ssh gpu1 .local/bin/ctr-connect ctr-feat.gpu1
                  │  └ Host gpu1 は ProxyCommand cloudflared access ssh（Cloudflare Tunnel）
                  ▼
   gpu1 上の ctr-connect: コンテナ・worktree がなければ作る / 止まっていれば起動
                  ▼
   podman exec -i ctr-feat nc 127.0.0.1 22
                  ▼
   コンテナ内 sshd → dev ユーザー → Claude Code 本体（~/.claude/remote/）
```

各ホストに置かれるもの（すべてログインユーザーの権限）:

| 物 | 場所 |
|---|---|
| コンテナ | `ctr-<作業名>`（ラベル `ctr.managed=true`）。ポートは公開しない |
| ホーム | ボリューム `ctr-<作業名>-home` → `/home/dev` |
| 作業ディレクトリ | `<worktree の置き場>/ctr-<作業名>`（ブランチ `ctr-<作業名>` の git worktree） |
| 元リポジトリ | `.git` だけをマウント（作業ディレクトリ本体は書き換えられない） |
| 設定 | `~/.config/cubby/config.env` |
| ホスト鍵 | `~/.config/cubby/hostkeys/`（ホストごとに 1 つ。そのホストの全コンテナで共有） |
| 公開鍵 | `~/.config/cubby/authorized_keys/dev` |
| スクリプト | `~/.local/bin/ctr-connect`・`ctr-list`・`ctr-remove`（元は `~/.local/share/cubby/`） |

## リポジトリの中身

```
client/cubby            手元で使うコマンド（ホストの登録・一覧・事前確認）
client/ssh_config.snippet  cubby が書く ssh_config の例
bin/ctr-connect         ProxyCommand から呼ばれる本体（ホスト側）
bin/ctr-list            コンテナ・ボリューム・worktree の一覧（ホスト側）
bin/ctr-remove          片付け（ホスト側）
host/setup-host.sh      ホストの準備（cubby add-host が自動で実行する）
host/preflight.sh       ホストの事前確認（変更しない）
image/                  コンテナイメージ（sshd, nc, git, dev ユーザー）
config.env.example      ホスト側の設定の見本
tests/smoke.sh          CLI で確かめられる受け入れテスト（手元から実行）
```

## 必要なもの

**リモートホスト（各台）**: Linux、rootless で使える Podman（`/etc/subuid`・`/etc/subgid` にログインユーザーの行があること）、git 2.17 以降、flock（util-linux）、ssh-keygen、tar。元リポジトリをログインユーザー所有で clone しておきます。

- **linger を有効にしてください**（`sudo loginctl enable-linger <ユーザー>`）。無効だと SSH が切れたときにコンテナと Claude Code 本体が止まり、Desktop で前のセッションに戻れません。`cubby add-host` は有効化を試み、できなければ警告を出します。
- worktree の置き場（既定 `/srv/worktrees`）をログインユーザーが作れない場合は、管理者に `sudo install -d -o <ユーザー> /srv/worktrees` を依頼するか、`--worktrees ~/worktrees` のようにホームの下を指定します。

**手元の PC**: OpenSSH クライアント、`sh`（macOS・Linux は標準、Windows は Git Bash）、`tar`、Cloudflare Tunnel を使うなら [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)。

**Cloudflare 側**: 各ホストで cloudflared のトンネルが SSH（`ssh://localhost:22`）を公開しており、Access アプリケーションでホスト名（例 `gpu1.example.com`）が設定済みであること。

## 初期設定（ホストごとに 1 回）

```sh
git clone https://github.com/perorin0418/cubby.git && cd cubby

# 1. ホストを登録する（Cloudflare Tunnel 経由の例）
sh client/cubby add-host gpu1 \
  --hostname gpu1.example.com --user alice --cloudflared \
  --repo /srv/project
```

`add-host` は次をまとめて行います（何度実行しても同じ結果になります）。

1. `~/.ssh/cubby/gpu1.conf` を書き、`~/.ssh/config` の先頭に `Include cubby/*.conf` を足す（元のファイルは `config.cubby.bak` に保存）
2. `ssh gpu1` が通るか確かめる。Cloudflare Access の初回はブラウザでのログインを求められます
3. ホストにスクリプトを転送し、`host/setup-host.sh` を実行する
   - コンテナ用の公開鍵の登録（既定は `~/.ssh/id_ed25519.pub` など。`--key` で指定可）
   - コンテナ用のホスト鍵の生成、worktree の置き場の作成、スクリプトの設置
   - コンテナイメージのビルド（初回は数分かかります）、linger の有効化
4. コンテナのホスト鍵を `~/.ssh/known_hosts` に `cubby-gpu1` として登録する。ホストへの認証済みの SSH で受け取るので、初回接続時の確認は出ません

ホストへのログイン自体（`ssh gpu1`）に必要な鍵の登録は、事前に済ませておいてください。既に `~/.ssh/config` にホストの設定があるなら、`--hostname` などの代わりに `--ssh-host <その名前>` を指定します。

```sh
# 既存の ~/.ssh/config の Host gpu2 を使う例
sh client/cubby add-host gpu2 --ssh-host gpu2 --worktrees /home/alice/worktrees
```

最後に、Desktop からはパスフレーズを入力できないので、鍵を ssh-agent に登録しておきます。

```sh
ssh ctr-test.gpu1 hostname   # → ctr-test と返れば完了
```

## 日常の使い方

- **新しい作業を始める**: Claude Desktop の Code タブで「+ Add SSH connection」→ SSH Host に `ctr-<作業名>.<ホストID>`（例 `ctr-feature1.gpu1`）を指定します。初回接続時にブランチ・worktree・コンテナが作られます。
  - 作業名は `ctr-` で始まる英小文字・数字・ハイフン、44 文字以内
  - 同じ作業名でもホストが違えば別のコンテナです（`ctr-feature1.gpu1` と `ctr-feature1.gpu2`）
- **続きから作業する**: 同じ接続を選びます。Desktop を再起動しても同じコンテナに戻ります。
- **一覧を見る**: 手元で `sh client/cubby list`（全ホスト）、`sh client/cubby list gpu1`（指定したホストだけ）。登録済みのホストは `sh client/cubby hosts`。

Desktop には登録した SSH 接続を編集・削除する画面がない時期がありました。接続名は作業単位で使い回す運用をおすすめします。

## 片付け

ホスト上で実行します（`ssh gpu1` してから）。

```sh
ctr-remove ctr-feature1          # 対象を表示して確認を求める
ctr-remove -y ctr-feature1       # 確認を省略
ctr-remove --force ctr-feature1  # 未コミットの変更があっても worktree を消す
```

コンテナ → worktree → ホームのボリュームの順で消します。**未コミットの変更があると、何も消さずに止まります**。ブランチは消しません。

手元の登録だけを消すには `sh client/cubby remove-host gpu1`（`~/.ssh/cubby/gpu1.conf` と known_hosts の `cubby-gpu1` を消します。ホスト上のものは残ります）。

## テスト

```sh
sh client/cubby preflight gpu1                     # ホストの事前確認（変更しない）
sh tests/smoke.sh gpu1                             # テスト用の ctr-smoke を作って確認する
sh tests/smoke.sh gpu1 --cleanup                   # 最後に ctr-remove で片付ける（ブランチは残る）
CTR_WT_ROOT=/home/alice/worktrees sh tests/smoke.sh gpu2   # worktree の置き場が既定と違うとき
```

Desktop での確認（セッションがコンテナ内で動く・再起動後に戻る・別名で別コンテナ・同時に動かしても干渉しない）は手作業で行います。手順は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) の 6.6 を参照してください。

## トラブル時の確認箇所

| 症状 | 確認すること |
|---|---|
| `cannot ssh to <host>` | `ssh <host>` が単体で通るか。cloudflared のログイン（ブラウザ）、ホストの鍵の登録 |
| `ssh ctr-x.<id>` が `kex_exchange_identification` などで即切れる | `ssh <host> '.local/bin/ctr-connect ctr-x.<id> </dev/null \| head -c 8'` が `SSH-2.0-` を返すか。標準エラー出力の `ctr-connect:` のメッセージ |
| `invalid name` / `host id mismatch` | 接続名が `ctr-<作業名>.<ホストID>` の形か。ホスト ID はホストの `~/.config/cubby/config.env` の `CTR_HOST_ID` |
| `lock timeout` | 同名の ctr-connect が準備中のまま残っていないか（`$XDG_RUNTIME_DIR/cubby-locks`） |
| `sshd not ready` | ホストで `podman logs ctr-x`。ホスト鍵の権限（600） |
| `Permission denied (publickey)` | `~/.config/cubby/authorized_keys/dev` に手元の公開鍵があるか。ssh-agent に鍵があるか。`cubby add-host` を再実行すると追記される |
| `container host key ... changed` | ホスト側でホスト鍵を作り直した場合。意図したものなら `--replace-hostkey` を付けて再実行 |
| Desktop を閉じるとセッションが消える | ホストの linger（`loginctl show-user <ユーザー> -p Linger`） |
| コンテナ作成時に `keep-id` や `newuidmap` のエラー | `/etc/subuid`・`/etc/subgid` にログインユーザーの行があるか |
| worktree で `dubious ownership` や書き込みエラー | 元リポジトリがログインユーザー所有か。イメージをビルドし直す（`cubby add-host <id> --rebuild`） |
| Desktop で本体の配置に失敗する | Desktop のログ、コンテナ内の `~/.claude/remote/`。イメージに足りないコマンドやライブラリがないか |

## 注意

- コンテナのポートは公開しません。
- 秘密鍵・認証情報・`config.env` の実値はコミットしないでください。
- Desktop は Anthropic の認証情報をコンテナ内に置きます。コンテナを他人と共有しないでください。
- Windows 版 Desktop は内蔵の SSH クライアントを使うため、`Include`・`Host ctr-*.<id>` のパターン・ProxyCommand（cloudflared を含む 2 段）を解釈するかは未検証です。解釈されない場合は、[client/ssh_config.snippet](client/ssh_config.snippet) を参考に `~/.ssh/config` へ直接、名前ごとに書いてください。
- 各ホストのブランチ名は `ctr-<作業名>` です。複数のホストで同じ上流リポジトリへ push する場合は、作業名が重ならないようにしてください。

## 設計からの変更点（docs/handoff-ctr-connect.md との違い）

| 当初の設計 | 現在 | 理由 |
|---|---|---|
| Docker | rootless Podman（`--userns=keep-id --user root`、`--security-opt label=disable`、`--uts/--network private`） | 利用者の環境に合わせた |
| 単一ホスト、接続名 `ctr-<作業名>` | 複数ホスト、接続名 `ctr-<作業名>.<ホストID>`、`Host ctr-*.<id>` をホストごとに生成 | 複数のリモートホストを使い分けるため |
| 設定・鍵は `/etc/ctr`（root 所有）、スクリプトは `/usr/local/bin` | `~/.config/cubby`、`~/.local/bin`（ログインユーザー所有） | rootless なので sudo を不要にした。rootless ではホストの root 所有のファイルをコンテナから読めない |
| 公開鍵の登録・known_hosts の受け入れは手作業 | `cubby add-host` が自動で行う | 利用者の要望 |
| ホストへは直接 SSH | Cloudflare Tunnel（`cloudflared access ssh`）を ProxyCommand に設定できる | 利用者の環境に合わせた |
| — | ロック中に起動するコマンドで fd 9 を閉じる | rootless Podman の conmon・fuse-overlayfs がロックの fd を受け継ぎ、ロックを持ち続けたため（検証で判明） |
| — | linger を有効化する | rootless では、無効だとログアウト時にコンテナが止まるため |
