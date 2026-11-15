# cubby

Claude Desktop の SSH 接続で、**接続名ごとに専用のコンテナ**を自動で用意し、その中で Claude Code を動かすための仕組みです。リモートホストは複数台を使い分けられます。

- 接続名は `ctr-<作業名>.<ホストID>`（例 `ctr-feature1.lab1`）。ドットの後ろでホストを選びます。
- **GPU を使うコンテナ**は、接続名の先頭を `gpu-` にするだけです（例 `gpu-train.lab1`）。GPU が使えるホストかどうかは自動で判定します。
- 同じ接続名なら、何度つないでも同じコンテナに戻ります。違う接続名なら、別のコンテナ・別の作業ディレクトリになります。
- 各コンテナの作業ディレクトリは**空で始まります**。リポジトリの clone などは、コンテナ内の Claude Code（や利用者）が行います。
- 新しいコンテナがほしいときは、Desktop に新しい名前の SSH 接続を追加するだけです。
- コンテナは各ホストの **rootless Podman** で動かします。
- ホストへは **Cloudflare Tunnel**（`cloudflared access ssh`）経由で接続できます。
- **ホスト側の事前準備は不要**です。手元の `cubby add-host` 1 回で、Podman などのインストールから、鍵の登録、イメージのビルドまで済みます。
- Claude Desktop を動かす手元の PC は **Windows・macOS・Linux** に対応します。複数の PC から同じホストを使えます。

コマンド・オプション・設定の一覧は「[コマンドとオプション一覧](#コマンドとオプション一覧)」にまとめています。

当初の設計は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) と [docs/claude-desktop-ssh-container.html](docs/claude-desktop-ssh-container.html) にあります（Docker・単一ホスト・git worktree 前提。変更点は末尾の「設計からの変更点」を参照）。

## しくみ

```
Claude Desktop ──SSH(ctr-feat.lab1)──▶ ~/.ssh/config の cubby ブロックの Host ctr-*.lab1
   ProxyCommand: ssh lab1 .local/bin/ctr-connect ctr-feat.lab1
                  │  └ Host lab1 は ProxyCommand cloudflared access ssh（Cloudflare Tunnel）
                  ▼
   lab1 上の ctr-connect: コンテナ・作業ディレクトリがなければ作る / 止まっていれば起動
                  ▼
   podman exec -i ctr-feat nc 127.0.0.1 22
                  ▼
   コンテナ内 sshd → ホストと同じユーザー（例 alice）→ Claude Code 本体（~/.claude/remote/）
```

各ホストに置かれるもの（すべてログインユーザーの権限）:

| 物 | 場所 |
|---|---|
| コンテナ | `ctr-<作業名>` / `gpu-<作業名>`（ラベル `ctr.managed=true`）。ポートは公開しない |
| ユーザー | コンテナ用のユーザーは作らない。**ホストのログインユーザーそのもの**（同じ名前・UID・GID・ホームのパス）でコンテナに入る |
| ホーム | ボリューム `<名前>-home` → コンテナの、ホストと同じホームのパス（例 `/home/alice`）。Claude Code のセッション・設定・認証情報 |
| 作業ディレクトリ | `~/cubby/work/<名前>`（`--work-root` で変更可）。コンテナにも同じパスでマウント |
| 設定 | `~/.config/cubby/config.env`、追加マウントは `~/.config/cubby/mounts` |
| ホスト鍵 | `~/.config/cubby/hostkeys/`（ホストごとに 1 つ。そのホストの全コンテナで共有） |
| 公開鍵 | `~/.config/cubby/authorized_keys/<ユーザー名>` |
| スクリプト | `~/.local/bin/ctr-connect`・`ctr-list`・`ctr-remove`・`ctr-recreate`（元は `~/.local/share/cubby/`） |

## リポジトリの中身

```
client/cubby            手元で使うコマンド（ホストの登録・一覧・事前確認）。sh スクリプト
client/cubby-lib.sh     OS ごとの差（ssh の選択・パスの形式）を吸収する共通部分
client/cubby.ps1        Windows の PowerShell から cubby を実行するラッパー
client/cubby.cmd        Windows の cmd.exe から cubby を実行するラッパー
client/ssh_config.snippet  cubby が書く ssh_config の例（macOS・Windows）
bin/ctr-connect         ProxyCommand から呼ばれる本体（ホスト側）
bin/ctr-list            コンテナ・ボリューム・作業ディレクトリの一覧（ホスト側）
bin/ctr-remove          片付け（ホスト側）
bin/ctr-recreate        コンテナだけを作り直す（マウントの設定の反映。ホスト側）
bin/ctr-common.sh       ホスト側のスクリプトが共有する部分（追加マウントの解釈）
host/bootstrap-root.sh  root が要るホストの準備（cubby add-host が必要なときだけ sudo で実行する）
host/setup-host.sh      ホストの準備（cubby add-host が自動で実行する）
host/preflight.sh       ホストの事前確認（変更しない）
image/                  コンテナイメージ（sshd, nc, git, curl, tini, sudo。利用者のユーザーは含めない）
image/ctr-entrypoint.sh 起動時にホストのユーザーをコンテナの /etc/passwd に登録し、sudo を許可する
config.env.example      ホスト側の設定の見本
tests/smoke.sh          CLI で確かめられる受け入れテスト（手元から実行）
```

## 必要なもの

**リモートホスト（各台）**: Linux。`ssh <ホスト>` でログインでき（**パスワード認証でもよい**）、そのユーザーが sudo を使えること。**これ以外の準備は要りません**。足りないものは `cubby add-host` が入れます。

| 自動で用意するもの | 内容 |
|---|---|
| ホストへのログイン用の公開鍵 | 鍵認証で入れなければ、ログインのパスワードを 1 回だけ尋ねて手元の公開鍵をホストの `~/.ssh/authorized_keys` に追記する（`ssh-copy-id` と同じ。既存の行は消さない） |
| パッケージ | podman, git, flock, ssh-keygen, tar, newuidmap/newgidmap ほか（apt / dnf / yum / zypper / pacman / apk に対応） |
| rootless の設定 | `/etc/subuid`・`/etc/subgid` の範囲、newuidmap/newgidmap の権限、linger |
| 作業ディレクトリの置き場 | 既定の `~/cubby/work` は sudo なしで作る。ログインユーザーが作れない場所（`/srv/...` など）を指定したときだけ、ログインユーザー所有で作る |
| GPU（NVIDIA） | ドライバが動いていれば、NVIDIA Container Toolkit と CDI の定義（「GPU を使う」を参照） |
| cubby 本体 | 設定、コンテナ用のホスト鍵、公開鍵の登録、スクリプト、コンテナイメージ |

root が要る作業は、残っているときだけ sudo で行います（2 回目以降は通常 sudo を使いません）。sudo にパスワードが要る場合は、先に入力したログインのパスワードをまず試し、違えば手元の端末で尋ねます。既存のディレクトリの所有者や中身、既存の設定値は変えません。

Desktop は接続の途中でパスワードを入力できないため、日常の接続は鍵認証で行います。パスワードを使うのは `add-host` の初回だけです。パスワードは ssh に端末経由ではなく `SSH_ASKPASS`（一時的な小さなプログラム。終了時に消す）で渡すので、Windows・macOS・Linux のどれでも同じように動きます。端末がない場合（自動化）は、標準入力から 1 行読みます（例 `printf '%s\n' "$PW" | sh client/cubby add-host ...`）。ホストの sshd がパスワード認証を許可していない場合は、最初の鍵の登録だけ別の手段で行ってください（sshd の設定は変えません）。

**手元の PC（Claude Desktop を動かすマシン）**:

| OS | 必要なもの | cubby の実行方法 |
|---|---|---|
| macOS | 標準の OpenSSH・sh・tar。Cloudflare Tunnel を使うなら `brew install cloudflared` | ターミナルで `sh client/cubby ...` |
| Linux | OpenSSH クライアント・sh・tar。Cloudflare Tunnel を使うなら cloudflared | ターミナルで `sh client/cubby ...` |
| Windows | Windows 標準の OpenSSH クライアント（設定 > システム > オプション機能 > OpenSSH クライアント）、[Git for Windows](https://git-scm.com/download/win)（cubby の実行に使う）、Cloudflare Tunnel を使うなら [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) | Git Bash で `sh client/cubby ...`、PowerShell で `.\client\cubby.ps1 ...`、cmd で `client\cubby.cmd ...` |

Windows では、cubby は Git Bash 付属の ssh ではなく **Windows 標準の OpenSSH（`ssh.exe`）**を使います。Claude Desktop・Windows の ssh-agent と同じ設定（`%USERPROFILE%\.ssh\config`）と鍵を使うためです。生成される ProxyCommand も Windows 標準の `ssh.exe` を呼び、sh を必要としません。

**Cloudflare 側**: 各ホストで cloudflared のトンネルが SSH（`ssh://localhost:22`）を公開しており、Access アプリケーションでホスト名（例 `lab1.example.com`）が設定済みであること。

## 初期設定（ホストごとに 1 回）

```sh
git clone https://github.com/perorin0418/cubby.git && cd cubby

# Cloudflare Tunnel 経由のホストを登録し、ホストの環境を整える（macOS・Linux・Git Bash）
sh client/cubby add-host lab1 --hostname lab1.example.com --user alice --cloudflared
```

```powershell
# Windows の PowerShell から
.\client\cubby.ps1 add-host lab1 --hostname lab1.example.com --user alice --cloudflared
```

`add-host` は次をまとめて行います（何度実行しても同じ結果になります）。

1. `~/.ssh/config` の先頭に、このホスト用の管理ブロック（`# >>> cubby lab1 ... >>>` 〜 `# <<< cubby lab1 <<<`）を書く。元のファイルは `config.cubby.bak` に保存します。`Include` は使わないので、`Include` を解釈しない SSH クライアントでも読めます
2. `ssh lab1` に鍵で入れるか確かめる。入れなければログインのパスワードを 1 回尋ねて公開鍵を登録する。Cloudflare Access の初回はブラウザでのログインを求められます。ホスト自体のホスト鍵は初回に自動で受け入れます（以後、変わっていれば止まります）
3. root が要る準備が残っていれば sudo で行う（上の表）
4. ホストにスクリプトを転送し、公開鍵の登録（既定は `~/.ssh/id_ed25519.pub` など。`--key` で指定可）、ホスト鍵の生成、イメージのビルド（初回は数分）、rootless コンテナの動作確認、GPU の判定を行う
5. コンテナのホスト鍵を `~/.ssh/known_hosts` に `cubby-lab1` として登録する。ホストへの認証済みの SSH で受け取るので、初回接続時の確認は出ません

ProxyCommand には `ssh` と `cloudflared` の**絶対パス**を書きます。GUI から起動した Claude Desktop（特に macOS）は PATH が最小限で、Homebrew などで入れたコマンドが見つからないためです。cloudflared を後から入れた・移した場合は `add-host` を再実行してください。

既に `~/.ssh/config` にホストの設定があるなら、`--hostname` などの代わりに `--ssh-host <その名前>` を指定します。作業ディレクトリの置き場を変えるなら `--work-root` を指定します（初回のみ有効。既存の設定は変えません）。

```sh
sh client/cubby add-host lab2 --ssh-host lab2 --work-root /data/cubby-work
```

最後に、Desktop からはパスフレーズを入力できないので、鍵を ssh-agent に登録します。

| OS | 方法 |
|---|---|
| macOS | `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`。`~/.ssh/config` の `Host *` に `UseKeychain yes` と `AddKeysToAgent yes` を書くと再起動後も使えます |
| Linux | デスクトップ環境の ssh-agent（GNOME Keyring など）に `ssh-add ~/.ssh/id_ed25519` |
| Windows | 管理者の PowerShell で `Get-Service ssh-agent \| Set-Service -StartupType Automatic; Start-Service ssh-agent`、その後 `ssh-add $env:USERPROFILE\.ssh\id_ed25519` |

```sh
ssh ctr-test.lab1 hostname   # → ctr-test と返れば完了（Windows は PowerShell でも同じ）
```

## 日常の使い方

- **新しい作業を始める**: Claude Desktop の Code タブで「+ Add SSH connection」→ SSH Host に `ctr-<作業名>.<ホストID>`（例 `ctr-feature1.lab1`）を指定します。初回接続時に、空の作業ディレクトリとコンテナが作られます。
  - 作業名は `ctr-`（GPU なし）または `gpu-`（GPU あり）で始まる英小文字・数字・ハイフン、44 文字以内
  - 同じ作業名でもホストが違えば別のコンテナです（`ctr-feature1.lab1` と `ctr-feature1.lab2`）
- **続きから作業する**: 同じ接続を選びます。Desktop を再起動しても同じコンテナに戻ります。
- **一覧を見る**: 手元で `sh client/cubby list`（全ホスト）、`sh client/cubby list lab1`（指定したホストだけ）。登録済みのホストは `sh client/cubby hosts`。

Desktop には登録した SSH 接続を編集・削除する画面がない時期がありました。接続名は作業単位で使い回す運用をおすすめします。

## 作業ディレクトリとリポジトリ

cubby はリポジトリを管理しません。各コンテナには空の作業ディレクトリ（ホストの `~/cubby/work/<名前>`、コンテナ内も同じパス）が用意されるだけです。必要なリポジトリは、コンテナ内で Claude Code に clone させてください（例「`git@github.com:example/web.git` を clone して…」）。1 つのコンテナで複数のリポジトリを扱っても、リポジトリを使わない作業でもかまいません。

- **ユーザー**: コンテナ用のユーザーは作りません。ホストのログインユーザー（例 alice、UID 1000）そのものとしてコンテナに入ります。作業ディレクトリや追加マウントのファイルは、ホストとコンテナで所有者が一致します。
- **ホームは同じパスでも中身は別**です。コンテナのホーム（例 `/home/alice`）はコンテナごとのボリュームで、ホストの `/home/alice` の中身は見えません（作業ディレクトリと、`--mount` で指定したものだけが見えます）。
- SSH でログインした直後の場所はホーム（ホストと同じパス。例 `/home/alice`）です。作業ディレクトリは `~/cubby/work/<名前>`（例 `/home/alice/cubby/work/ctr-feature1`）で、ホストとコンテナで同じパスです（Claude Code のセッションを始めるディレクトリとして指定します）。
- 作業ディレクトリはホストからも同じパスで見えます。コンテナで作ったファイルは、ホストではログインユーザーの所有になります。
- コンテナを作り直しても（`ctr-recreate`、`podman rm`）、作業ディレクトリとホームは残ります。
- **GitHub などの認証はコンテナ内で用意してください**。ホーム（ボリューム）に置いたものはコンテナを作り直しても残るので、一度設定すればそのコンテナでは使い続けられます（例: コンテナ内で `gh auth login`（gh は別途インストール）、デプロイキーや個人用の鍵を `~/.ssh` に置く、`git config --global user.name/user.email`）。
- 手元の ssh-agent はコンテナに転送しません（Desktop がエージェント転送を使うかは未確認のため）。

## コンテナ内の sudo

コンテナ内では、ホストと同じユーザーのまま **パスワードなしで sudo** が使えます（`apt-get install` など。Claude Code にパッケージを入れさせることもできます）。

```sh
sudo apt-get update && sudo apt-get install -y jq
```

- コンテナ内の root は rootless Podman のユーザー名前空間の中の root で、**ホストの root ではありません**。ホストに対しては、ログインユーザーができること以上はできません。
- `apt` などで入れたものはコンテナに残りますが、**コンテナを作り直すと消えます**（`ctr-recreate`、`podman rm`）。常に必要なものは `image/Dockerfile` に追記して `cubby add-host <id> --rebuild` でイメージを作り直してください。
- sudo（root）で作業ディレクトリに作ったファイルは、ホストではログインユーザーではなく別の UID（例 100000）の所有に見え、ホストのログインユーザーからは直接変更できません。作業ディレクトリでは sudo を使わずに作業するのが無難です（`ctr-remove --force` は `podman unshare` で消すので、片付けはできます）。
- 不要なホストでは、ホストの `~/.config/cubby/config.env` に `CTR_SUDO=no` と書き、既存のコンテナを `ctr-recreate` で作り直すと無効になります。

## GPU を使う

接続名の先頭で、GPU を使うかどうかを選びます。

| 接続名 | コンテナ | 使えるホスト |
|---|---|---|
| `ctr-<作業名>.<ホストID>` | GPU なし | すべてのホスト |
| `gpu-<作業名>.<ホストID>` | ホストの全 GPU が見える | GPU が使えるホスト（`cubby hosts` で `gpu=yes`） |

```sh
ssh gpu-train.lab1 nvidia-smi -L   # → GPU 0: NVIDIA ...
sh client/cubby hosts
# lab1   ssh-host=lab1   gpu=yes   connect as ctr-<name>.lab1, gpu-<name>.lab1
# lab2   ssh-host=lab2   gpu=no    connect as ctr-<name>.lab2
```

- `ctr-x` と `gpu-x` は別のコンテナ・別の作業ディレクトリです（GPU の有無はコンテナを作るときに決まるため）。
- GPU が使えないホストに `gpu-` でつなぐと、何も作らずに接続を断ります（`ctr-` でつなぐよう案内します）。

**ホストの準備（自動）**: `cubby add-host` は、ホストで **NVIDIA のドライバが動いていれば**（`nvidia-smi` が通れば）、次を自動で行います。
1. NVIDIA の公式リポジトリを追加し、NVIDIA Container Toolkit を入れる（apt / dnf / yum / zypper / pacman）
2. CDI の定義（`/etc/cdi/nvidia.yaml`）を作る。rootless Podman はこれで GPU を使います（`--device nvidia.com/gpu=all`）
3. 実際に GPU 付きのコンテナで `nvidia-smi -L` が通るか確かめ、結果をホストの `~/.config/cubby/detected.env` と手元の `cubby hosts` に反映する

- **NVIDIA のドライバ自体は入れません**（カーネル・再起動・Secure Boot が絡むため）。ドライバを入れてから `cubby add-host` を再実行してください。GPU はあるのにドライバが動いていない場合は警告を出します。
- ドライバを更新すると CDI の定義が古くなります。`cubby add-host` を再実行すると作り直します（版の食い違いを検出します）。
- GPU の準備をしたくないホストでは `--no-gpu` を付けます。
- コンテナにはホストのドライバのライブラリと `nvidia-smi` が入ります。CUDA Toolkit は入れていないので、PyTorch など CUDA を同梱するパッケージを使うか、コンテナ内で入れてください。
- **AMD の GPU** は自動では準備しません。ホストの `~/.config/cubby/config.env` に `CTR_GPU_ARGS="--device /dev/kfd --device /dev/dri --group-add keep-groups"` のように書いて `cubby add-host` を再実行すると、その指定で起動できるかを確かめ、`gpu-` の接続で使えるようになります。

## ホストのディレクトリを毎回マウントする

データセットやキャッシュなど、ホストのディレクトリを**そのホストの全コンテナ**（`ctr-` も `gpu-` も）に毎回マウントできます。

```sh
# 手元から設定する（何度でも。--mount / --unmount は複数指定できる）
sh client/cubby add-host lab1 --mount /data/datasets:/datasets:ro --mount /scratch
sh client/cubby add-host lab1 --unmount /scratch
```

書式は `ホストのパス[:コンテナ内のパス][:ro|rw]` です。コンテナ内のパスを省略するとホストと同じパスに、モードを省略すると `rw` になります。書き換えたくないものには `:ro` を付けてください。

設定はホストの `~/.config/cubby/mounts` に 1 行ずつ保存されます。直接編集してもかまいません（空白を含むパスは直接編集で書けます。`:` を含むパスは書けません）。

```
# ~/.config/cubby/mounts
/data/datasets:/datasets:ro
/scratch
/home/alice/.cache/huggingface:ro
```

- **既存のコンテナへの反映**: マウントはコンテナを作るときに決まります。設定を変えたら、ホストで `ctr-recreate <名前>` を実行してください。コンテナだけを作り直し、ホームと作業ディレクトリは残ります（動いている Claude Code のセッションは止まりますが、記録はホームに残ります）。次の接続で新しい設定のコンテナが作られます。
- 反映していないコンテナは、`add-host` の出力・`ctr-list`（`cubby list`）・接続時のメッセージで知らせます。接続時に自動で作り直すことはしません（セッションが切れるため）。
- ホストにないディレクトリは、警告を出して飛ばします（接続は失敗させません）。後から作られたら、`ctr-recreate` で反映できます。
- rootless なので、コンテナから書けるのはホストのログインユーザーが書けるファイルだけです。
- `/etc`・`/usr`・ホーム（ホストと同じパス）そのものなど、コンテナの動作に必要な場所にはマウントできません（`~/.cache/huggingface` のような下の階層はできます。コンテナのホームはホストと同じパスなので、ホストのパスをそのまま書けば同じ場所に見えます）。

## 片付け

ホスト上で実行します（`ssh lab1` してから）。

```sh
ctr-remove ctr-feature1          # 対象を表示して確認を求める
ctr-remove -y ctr-feature1       # 確認を省略
ctr-remove --force ctr-feature1  # 作業ディレクトリに中身があっても消す
```

コンテナ → 作業ディレクトリ → ホームのボリュームの順で消します。**作業ディレクトリが空でないと、何も消さずに止まり**、中身を表示します。中に git のリポジトリ（コンテナ内で clone したもの）があれば、**未コミットの変更と push していないコミットの数**も表示します。必要なものを push・移動してから再実行するか、`--force` で中身ごと消してください。

`ctr-list`（手元からは `cubby list`）でも、各作業ディレクトリの中のリポジトリのブランチと未コミットの変更の数が見られます。

手元の登録だけを消すには `sh client/cubby remove-host lab1`（`~/.ssh/config` の cubby ブロックと known_hosts の `cubby-lab1` を消します。ホスト上のものは残ります）。

## 複数の PC から使う

自宅と会社など、複数の PC から同じホストを使えます。それぞれの PC で、**同じホスト ID** を指定して `cubby add-host` を実行してください。2 台目の公開鍵が追記され、ホストの設定やイメージはそのまま使われます。

- 同じ接続名でつなぐと同じコンテナ・同じ作業ディレクトリになります。ただし、一方の PC の Desktop で始めたセッションをもう一方で再開できるか、2 台から同時につないで問題ないかは未検証です。同時に作業するなら、PC ごとに接続名を分けるのが確実です。
- 自宅と会社で別の Anthropic アカウントを使う場合は、コンテナ内の認証情報が上書きされないよう、接続名を PC ごとに分けてください。

## テスト

```sh
sh client/cubby preflight lab1         # ホストの事前確認（変更しない）
sh tests/smoke.sh lab1                 # テスト用の ctr-smoke を作って確認する
sh tests/smoke.sh lab1 --cleanup       # 最後に ctr-remove --force で片付ける
```

Desktop での確認（セッションがコンテナ内で動く・再起動後に戻る・別名で別コンテナ・同時に動かしても干渉しない）は手作業で行います。手順は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) の 6.6 を参照してください。

## コマンドとオプション一覧

### 手元の PC: `cubby`

macOS・Linux・Git Bash は `sh client/cubby ...`、Windows の PowerShell は `.\client\cubby.ps1 ...`、cmd は `client\cubby.cmd ...` で実行します（引数はすべて同じ）。

| コマンド | 内容 |
|---|---|
| `cubby add-host <id> [オプション]` | リモートホストを登録し、ホストの環境を整える。何度実行してもよい（設定の変更・鍵の追加・イメージの更新にも使う） |
| `cubby hosts` | 登録済みのホストを一覧する（SSH 名・GPU の有無・接続名の形） |
| `cubby list [id...]` | 各ホストのコンテナ・ボリューム・追加マウント・作業ディレクトリ（中のリポジトリの状態）を一覧する。省略時は全ホスト |
| `cubby preflight <id>` | ホストの事前確認（何も変更しない） |
| `cubby remove-host [-y] <id>` | 手元の登録（`~/.ssh/config` の cubby ブロックと known_hosts の `cubby-<id>`）だけを消す。ホスト上のものは消さない。`-y` で確認を省略 |

`<id>` はホスト ID（英小文字・数字・ハイフン、32 文字以内）。接続名の末尾や ssh_config の名前に使います。

#### `cubby add-host` のオプション

| オプション | 既定 | 内容 |
|---|---|---|
| `--hostname FQDN\|IP` | なし | ホストの実際の接続先（DNS 名・IP アドレス・Cloudflare のホスト名）。指定すると ssh_config にホスト本体の設定（`Host <id>`）も書く |
| `--user USER` | 手元のユーザー名 | ホストのログインユーザー（`--hostname` と一緒に使う）。コンテナにも同じユーザーで入る |
| `--port N` | 22 | ホストの SSH ポート（`--hostname` と一緒に使う） |
| `--cloudflared` | なし | Cloudflare Tunnel 経由で接続する（`ProxyCommand cloudflared access ssh --hostname %h`。`--hostname` と一緒に使う） |
| `--identity FILE` | ssh の既定 | ホストとコンテナへのログインに使う秘密鍵。公開鍵の登録には `FILE.pub` を使う |
| `--ssh-host ALIAS` | `<id>` | ホストの SSH 名。`--hostname` を使わず、`~/.ssh/config` に自分で書いた既存の設定を使うときに指定する |
| `--key FILE` | `~/.ssh/id_ed25519.pub` → `id_ecdsa.pub` → `id_rsa.pub` → ssh-agent の鍵 | コンテナ（とホスト）に登録する公開鍵 |
| `--work-root PATH` | `~/cubby/work` | ホスト上の作業ディレクトリの置き場。各コンテナの作業ディレクトリは `<置き場>/<名前>`。初回のみ有効（既存の設定は変えない） |
| `--mount SPEC` | なし | そのホストの全コンテナに毎回マウントするディレクトリを足す。複数指定可。`SPEC` は `ホストのパス[:コンテナ内のパス][:ro\|rw]`（省略時は同じパス・`rw`） |
| `--unmount PATH` | なし | そのホストのパスのマウントをやめる。複数指定可 |
| `--no-gpu` | GPU を自動判定 | GPU の準備（NVIDIA Container Toolkit の導入・CDI の定義の作成）をしない |
| `--rebuild` | 必要なときだけ | コンテナイメージを作り直す（イメージの版が古いときは指定しなくても作り直す） |
| `--replace-hostkey` | なし | コンテナのホスト鍵が known_hosts の記録と違っても置き換える（ホスト側で鍵を作り直したとき） |

- `--mount` / `--unmount` / `--work-root` などで変えた設定を既存のコンテナに反映するには、ホストで `ctr-recreate <名前>` を実行します。
- 廃止したオプション: `--repo`、`--repo-url`、`--no-repo`、`--worktrees`（指定するとエラーで止まり、代わりの方法を表示します）。

### リモートホスト: `ctr-*`

`ssh <id>` でホストに入ってから実行します（`~/.local/bin` にあります）。

| コマンド | 内容 |
|---|---|
| `ctr-list` | このホストのコンテナ・ボリューム・追加マウント（設定が古いコンテナ）・作業ディレクトリ（中のリポジトリのブランチと未コミットの変更の数）を一覧する |
| `ctr-remove [-y] [--force] <名前>` | コンテナ・作業ディレクトリ・ホームのボリュームを消す。作業ディレクトリが空でなければ、何も消さずに止まる（中のリポジトリの未コミット・未 push も表示）。`-y` で確認を省略、`--force` で中身があっても消す |
| `ctr-recreate [-y] <名前>` | コンテナだけを作り直す（ホームと作業ディレクトリは残る）。次の接続で今の設定（追加マウント・sudo など）のコンテナが作られる。`-y` で確認を省略 |
| `ctr-connect <接続名>` | ssh_config の ProxyCommand から呼ばれる本体。手で実行するのは調査のときだけ（例 `ctr-connect ctr-x.lab1 </dev/null \| head -c 8` が `SSH-2.0-` を返すか） |

`<名前>` は `ctr-<作業名>` / `gpu-<作業名>`。接続名（`ctr-feature1.lab1`）をそのまま渡してもかまいません。

### 接続名

```
<ctr|gpu>-<作業名>.<ホストID>
```

| 部分 | 内容 |
|---|---|
| `ctr-` / `gpu-` | `ctr-` は GPU なし、`gpu-` は GPU あり（GPU が使えるホストのみ） |
| `<作業名>` | 英小文字・数字・ハイフン。`ctr-` / `gpu-` を含めて 44 文字以内。コンテナ名・作業ディレクトリ名になる |
| `<ホストID>` | `cubby add-host` で決めた ID |

### テスト: `tests/smoke.sh`

```
sh tests/smoke.sh <id> [--cleanup]
```

| 引数・環境変数 | 内容 |
|---|---|
| `--cleanup` | 最後にテスト用のコンテナ・作業ディレクトリ・ボリュームを `ctr-remove --force` で消す |
| `CTR_SMOKE_NAME` | テスト用の名前（既定 `ctr-smoke`。GPU のテストは `gpu-smoke`） |
| `CTR_WORK_ROOT` | ホストの作業ディレクトリの置き場（既定: ホストの設定の値） |

### ホストの設定: `~/.config/cubby/config.env`

`cubby add-host` が初回に作ります（既存の値は変えません）。sh の文法で書きます。値を変えたら、既存のコンテナは `ctr-recreate` で作り直すと反映されます。

| 変数 | 既定 | 内容 |
|---|---|---|
| `CTR_HOST_ID` | `add-host` の ID | このホストの ID。接続名のホスト ID と一致しない接続は断る |
| `CTR_WORK_ROOT` | `~/cubby/work` | 作業ディレクトリの置き場 |
| `CTR_IMAGE` | `localhost/ctr-dev:latest` | コンテナイメージ |
| `CTR_GPU_ARGS` | `--device nvidia.com/gpu=all` | `gpu-` のコンテナに付ける podman の引数（例 AMD は `--device /dev/kfd --device /dev/dri --group-add keep-groups`） |
| `CTR_SUDO` | `yes` | `no` にするとコンテナ内の sudo を許可しない |
| `CTR_MOUNTS_FILE` | `~/.config/cubby/mounts` | 追加マウントの設定ファイル |
| `CTR_HOSTKEYS` | `~/.config/cubby/hostkeys` | コンテナ用のホスト鍵の置き場 |
| `CTR_AUTHKEYS` | `~/.config/cubby/authorized_keys` | コンテナに登録する公開鍵の置き場（ファイル名はユーザー名） |
| `CTR_LOCK_DIR` | `$XDG_RUNTIME_DIR/cubby-locks` | 同時接続の排他に使うロックの置き場 |
| `CTR_BIN_DIR` | `~/.local/bin` | `ctr-*` の設置先 |

ホストのその他のファイル:

| ファイル | 内容 |
|---|---|
| `~/.config/cubby/mounts` | 追加マウントの一覧（`--mount` / `--unmount` で編集。直接編集してもよい） |
| `~/.config/cubby/detected.env` | `add-host` が自動で書く検出結果（GPU が使えるか）。編集しない |
| `~/.local/share/cubby/` | `add-host` が転送した cubby のスクリプトとイメージの定義 |

### 手元の環境変数

| 変数 | 内容 |
|---|---|
| `CUBBY_SSH_DIR` | `~/.ssh` の代わりに使うディレクトリ（テスト用。ssh に `-F` を付けて、そこの `config` と `known_hosts` を使う） |

## トラブル時の確認箇所

| 症状 | 確認すること |
|---|---|
| `cannot ssh to <host>` | `ssh <host>` が単体で通るか。ホスト名・ネットワーク、cloudflared のログイン（ブラウザ） |
| `could not log in ... with the password` | ログインのパスワード。ホストの sshd がパスワード認証を許可しているか |
| `key authentication still fails` | ホストの `~`・`~/.ssh` の権限（グループや他人が書けると sshd が鍵を無視する）。鍵にパスフレーズがあるなら ssh-agent に登録されているか |
| `accepts only public keys` | ホストがパスワード認証を許可していない。最初の鍵の登録だけ別の手段で行う |
| `--repo ... was removed` | リポジトリの管理はなくなった。コンテナ内で clone する。作業ディレクトリの置き場は `--work-root` |
| `this host has no usable GPU` | `cubby hosts` の `gpu=`。ホストで `nvidia-smi` が通るか（ドライバ）。通るなら `cubby add-host` を再実行 |
| `gpu=no` なのに GPU がある | ドライバの更新後なら `cubby add-host` の再実行で CDI の定義を作り直す。`add-host` の出力の `WARNING`（toolkit の導入や `nvidia-ctk cdi generate` の失敗） |
| コンテナにマウントが見えない | `ctr-list` の extra mounts（ホストにないパスは飛ばされる）。設定を変えた後なら `ctr-recreate <名前>` |
| `mount settings changed since ...` | マウントの設定が変わった。反映するならホストで `ctr-recreate <名前>` |
| `sudo: a password is required` | ホストの `config.env` が `CTR_SUDO=no` になっていないか。旧版のイメージで作ったコンテナなら `cubby add-host <id>` の後に `ctr-recreate <名前>` |
| `work directory ... is not empty` | `ctr-remove` の安全装置。中身（とリポジトリの未コミット・未 push）を確かめてから、移すか `--force` |
| コンテナ内の git で認証エラー | コンテナ内で GitHub などの認証を用意する（「作業ディレクトリとリポジトリ」を参照） |
| `ssh ctr-x.<id>` が `kex_exchange_identification` などで即切れる | `ssh <host> '.local/bin/ctr-connect ctr-x.<id> </dev/null \| head -c 8'` が `SSH-2.0-` を返すか。標準エラー出力の `ctr-connect:` のメッセージ |
| `invalid name` / `host id mismatch` | 接続名が `ctr-<作業名>.<ホストID>` の形か。ホスト ID はホストの `~/.config/cubby/config.env` の `CTR_HOST_ID` |
| `lock timeout` | 同名の ctr-connect が準備中のまま残っていないか（`$XDG_RUNTIME_DIR/cubby-locks`） |
| `sshd not ready` | ホストで `podman logs ctr-x`。ホスト鍵の権限（600） |
| `Permission denied (publickey)` | `~/.config/cubby/authorized_keys/<ユーザー名>` に手元の公開鍵があるか。ssh_config の `Host ctr-*` の `User` がホストのユーザー名か。ssh-agent に鍵があるか。`cubby add-host` を再実行すると追記される |
| `container host key ... changed` | ホスト側でホスト鍵を作り直した場合。意図したものなら `--replace-hostkey` を付けて再実行 |
| Desktop を閉じるとセッションが消える | ホストの linger（`loginctl show-user <ユーザー> -p Linger`） |
| コンテナ作成時に `keep-id` や `newuidmap` のエラー | `/etc/subuid`・`/etc/subgid` にログインユーザーの行があるか |
| 作業ディレクトリで書き込みエラー | 置き場がログインユーザーの書ける場所か。イメージをビルドし直す（`cubby add-host <id> --rebuild`） |
| Desktop で本体の配置に失敗する | Desktop のログ、コンテナ内の `~/.claude/remote/`。イメージに足りないコマンドやライブラリがないか |

## 注意

- コンテナのポートは公開しません。
- 秘密鍵・認証情報・`config.env` の実値はコミットしないでください。
- Desktop は Anthropic の認証情報をコンテナ内（ホームのボリューム）に置きます。コンテナを他人と共有しないでください。
- **Windows 版 Desktop について**: Windows 標準の OpenSSH（9.5）では、生成した設定（パターン `Host ctr-*.<id>`・ProxyCommand・%n）が sh なしで動くことを確認済みです。一方、Desktop が内蔵の SSH クライアントを使う場合に同じ設定を解釈するかは未検証です。パターンが解釈されない場合は、[client/ssh_config.snippet](client/ssh_config.snippet) を参考に接続名ごとに `Host ctr-feature1.lab1` と書き分けてください。

## 設計からの変更点（docs/handoff-ctr-connect.md との違い）

| 当初の設計 | 現在 | 理由 |
|---|---|---|
| Docker | rootless Podman（`--userns=keep-id --user root`、`--security-opt label=disable`、`--uts/--network private`） | 利用者の環境に合わせた |
| 単一ホスト、接続名 `ctr-<作業名>` | 複数ホスト、接続名 `ctr-<作業名>.<ホストID>`、`Host ctr-*.<id>` をホストごとに生成 | 複数のリモートホストを使い分けるため |
| 元リポジトリ（`/srv/project`）から接続名ごとに git worktree とブランチを作り、`.git` だけをマウント | リポジトリは管理しない。各コンテナに空の作業ディレクトリ（`~/cubby/work/<名前>`）を用意し、clone はコンテナ内の Claude Code が行う | 1 ホスト 1 リポジトリの前提が実際の運用（コンテナごとに必要なリポジトリを AI が clone する）と合わないため |
| `ctr-remove` は未コミットの変更があれば止まる | 作業ディレクトリが空でなければ止まり、中のリポジトリの未コミット・未 push を表示する | 上の変更に合わせた |
| 設定・鍵は `/etc/ctr`（root 所有）、スクリプトは `/usr/local/bin` | `~/.config/cubby`、`~/.local/bin`（ログインユーザー所有） | rootless なので sudo を不要にした。rootless ではホストの root 所有のファイルをコンテナから読めない |
| 公開鍵の登録・known_hosts の受け入れは手作業 | `cubby add-host` が自動で行う | 利用者の要望 |
| ホストへは直接 SSH | Cloudflare Tunnel（`cloudflared access ssh`）を ProxyCommand に設定できる | 利用者の環境に合わせた |
| — | ロック中に起動するコマンドで fd 9 を閉じる | rootless Podman の conmon・fuse-overlayfs がロックの fd を受け継ぎ、ロックを持ち続けたため（検証で判明） |
| — | linger を有効化する | rootless では、無効だとログアウト時にコンテナが止まるため |
| ホストの事前準備（docker・git の導入、ディレクトリ作成）は手作業 | `cubby add-host` が必要なときだけ sudo で自動実行（`host/bootstrap-root.sh`） | 利用者の要望 |
| ホストへのログインは鍵認証が前提 | パスワード認証のホストでも、`add-host` が初回に公開鍵を登録する | 利用者の要望 |
| GPU の扱いなし | 接続名 `gpu-<作業名>` で GPU 付きコンテナ（CDI `nvidia.com/gpu=all`）。NVIDIA Container Toolkit と CDI の定義を自動で準備し、使えるホストかを自動判定 | 利用者の要望 |
| マウントは repo の `.git`・worktree・ホーム・鍵のみ | ホストごとの `~/.config/cubby/mounts` で任意のディレクトリを全コンテナにマウント。`cubby add-host --mount/--unmount`、反映は `ctr-recreate` | 利用者の要望 |
| — | `~/.ssh/config` の書き換えを mkdir のロックで排他し、別のファイルに書いてから置き換える | 複数の `add-host` を同時に動かすと、互いのブロックを上書きしたり、書き換え中のファイルを ssh が読んで失敗したりしたため（検証で判明） |
| コンテナ内に `dev` ユーザーを作り（UID/GID をホストに合わせてイメージをビルド）、`dev` でログイン | ユーザーは作らない。起動時にホストのログインユーザー（同じ名前・UID・GID・ホームのパス）をコンテナの `/etc/passwd` に登録し、その名前でログインする。イメージはホストに依存しない（版のラベルで古いイメージを自動で作り直す） | 権限の食い違いを避けるため（利用者の要望） |
| コンテナ内で sudo は使えない | ホストのユーザーにパスワードなしの sudo を許可（`CTR_SUDO=no` で無効） | 利用者の要望。コンテナ内の root はホストの root ではないため |
| `docker run --init` | イメージに tini を入れて PID 1 にする | ホストの catatonit の有無に依存しないため |
| 手元は macOS・Linux の OpenSSH 前提、`~/.ssh/config` に手で追記 | Windows・macOS・Linux に対応。`~/.ssh/config` の先頭に管理ブロックを書く（`Include` は使わない）。ProxyCommand は絶対パス。Windows は Windows 標準の OpenSSH を使う | 利用者の要望。GUI から起動した Desktop の PATH が最小限のため |
