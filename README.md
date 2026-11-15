# cubby

Claude Desktop の SSH 接続で、**接続名ごとに専用のコンテナ**を自動で用意し、その中で Claude Code を動かすための仕組みです。リモートホストは複数台を使い分けられます。

- 接続名は `ctr-<作業名>.<ホストID>`（例 `ctr-feature1.lab1`）。ドットの後ろでホストを選びます。
- **GPU を使うコンテナ**は、接続名の先頭を `gpu-` にするだけです（例 `gpu-train.lab1`）。GPU が使えるホストかどうかは自動で判定します。
- 同じ接続名なら、何度つないでも同じコンテナに戻ります。
- 違う接続名なら、別のコンテナ・別の作業ディレクトリ（git worktree）になります。
- 新しいコンテナがほしいときは、Desktop に新しい名前の SSH 接続を追加するだけです。
- コンテナは各ホストの **rootless Podman** で動かします。
- ホストへは **Cloudflare Tunnel**（`cloudflared access ssh`）経由で接続できます。
- **ホスト側の事前準備は不要**です。手元の `cubby add-host` 1 回で、Podman などのインストールから、元リポジトリの clone、鍵の登録、イメージのビルドまで済みます。
- Claude Desktop を動かす手元の PC は **Windows・macOS・Linux** に対応します。

当初の設計は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) と [docs/claude-desktop-ssh-container.html](docs/claude-desktop-ssh-container.html) にあります（Docker・単一ホスト前提。変更点は末尾の「設計からの変更点」を参照）。

## しくみ

```
Claude Desktop ──SSH(ctr-feat.lab1)──▶ ~/.ssh/config の cubby ブロックの Host ctr-*.lab1
   ProxyCommand: ssh lab1 .local/bin/ctr-connect ctr-feat.lab1
                  │  └ Host lab1 は ProxyCommand cloudflared access ssh（Cloudflare Tunnel）
                  ▼
   lab1 上の ctr-connect: コンテナ・worktree がなければ作る / 止まっていれば起動
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
client/cubby            手元で使うコマンド（ホストの登録・一覧・事前確認）。sh スクリプト
client/cubby-lib.sh     OS ごとの差（ssh の選択・パスの形式）を吸収する共通部分
client/cubby.ps1        Windows の PowerShell から cubby を実行するラッパー
client/cubby.cmd        Windows の cmd.exe から cubby を実行するラッパー
client/ssh_config.snippet  cubby が書く ssh_config の例（macOS・Windows）
host/bootstrap-root.sh  root が要るホストの準備（cubby add-host が必要なときだけ sudo で実行する）
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

**リモートホスト（各台）**: Linux。`ssh <ホスト>` でログインでき（**パスワード認証でもよい**）、そのユーザーが sudo を使えること。**これ以外の準備は要りません**。足りないものは `cubby add-host` が入れます。

| 自動で用意するもの | 内容 |
|---|---|
| ホストへのログイン用の公開鍵 | 鍵認証で入れなければ、ログインのパスワードを 1 回だけ尋ねて手元の公開鍵をホストの `~/.ssh/authorized_keys` に追記する（`ssh-copy-id` と同じ。既存の行は消さない） |
| パッケージ | podman, git, flock, ssh-keygen, tar, newuidmap/newgidmap ほか（apt / dnf / yum / zypper / pacman / apk に対応） |
| rootless の設定 | `/etc/subuid`・`/etc/subgid` の範囲、newuidmap/newgidmap の権限、linger |
| ディレクトリ | 元リポジトリ・worktree の置き場（なければログインユーザー所有で作る） |
| 元リポジトリ | `--repo-url` を指定すると clone する（ssh の URL は手元の ssh-agent を転送して認証） |
| cubby 本体 | 設定、コンテナ用のホスト鍵、公開鍵の登録、スクリプト、コンテナイメージ |

root が要る作業は、残っているときだけ sudo で行います（2 回目以降は通常 sudo を使いません）。sudo にパスワードが要る場合は、先に入力したログインのパスワードをまず試し、違えば手元の端末で尋ねます。

Desktop は接続の途中でパスワードを入力できないため、日常の接続は鍵認証で行います。パスワードを使うのは `add-host` の初回だけです。パスワードは ssh に端末経由ではなく `SSH_ASKPASS`（一時的な小さなプログラム。終了時に消す）で渡すので、Windows・macOS・Linux のどれでも同じように動きます。端末がない場合（自動化）は、標準入力から 1 行読みます（例 `printf '%s
' "$PW" | sh client/cubby add-host ...`）。ホストの sshd がパスワード認証を許可していない場合は、最初の鍵の登録だけ別の手段で行ってください（sshd の設定は変えません）。既存のディレクトリの所有者や中身、既存の設定値は変えません。

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
sh client/cubby add-host lab1 \
  --hostname lab1.example.com --user alice --cloudflared \
  --repo /srv/project --repo-url git@github.com:example/project.git
```

```powershell
# Windows の PowerShell から
.\client\cubby.ps1 add-host lab1 --hostname lab1.example.com --user alice --cloudflared --repo /srv/project --repo-url git@github.com:example/project.git
```

`add-host` は次をまとめて行います（何度実行しても同じ結果になります）。

1. `~/.ssh/config` の先頭に、このホスト用の管理ブロック（`# >>> cubby lab1 ... >>>` 〜 `# <<< cubby lab1 <<<`）を書く。元のファイルは `config.cubby.bak` に保存します。`Include` は使わないので、`Include` を解釈しない SSH クライアントでも読めます
2. `ssh lab1` に鍵で入れるか確かめる。入れなければログインのパスワードを 1 回尋ねて公開鍵を登録する。Cloudflare Access の初回はブラウザでのログインを求められます。ホスト自体のホスト鍵は初回に自動で受け入れます（以後、変わっていれば止まります）
3. root が要る準備が残っていれば sudo で行う（上の表）
4. ホストにスクリプトを転送し、元リポジトリの clone、公開鍵の登録（既定は `~/.ssh/id_ed25519.pub` など。`--key` で指定可）、ホスト鍵の生成、イメージのビルド（初回は数分）、rootless コンテナの動作確認を行う
5. コンテナのホスト鍵を `~/.ssh/known_hosts` に `cubby-lab1` として登録する。ホストへの認証済みの SSH で受け取るので、初回接続時の確認は出ません

ProxyCommand には `ssh` と `cloudflared` の**絶対パス**を書きます。GUI から起動した Claude Desktop（特に macOS）は PATH が最小限で、Homebrew などで入れたコマンドが見つからないためです。cloudflared を後から入れた・移した場合は `add-host` を再実行してください。

既に `~/.ssh/config` にホストの設定があるなら、`--hostname` などの代わりに `--ssh-host <その名前>` を指定します。

```sh
sh client/cubby add-host lab2 --ssh-host lab2 --worktrees /home/alice/worktrees
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

- **新しい作業を始める**: Claude Desktop の Code タブで「+ Add SSH connection」→ SSH Host に `ctr-<作業名>.<ホストID>`（例 `ctr-feature1.lab1`）を指定します。初回接続時にブランチ・worktree・コンテナが作られます。
  - 作業名は `ctr-`（GPU なし）または `gpu-`（GPU あり）で始まる英小文字・数字・ハイフン、44 文字以内
  - 同じ作業名でもホストが違えば別のコンテナです（`ctr-feature1.lab1` と `ctr-feature1.lab2`）
- **続きから作業する**: 同じ接続を選びます。Desktop を再起動しても同じコンテナに戻ります。
- **一覧を見る**: 手元で `sh client/cubby list`（全ホスト）、`sh client/cubby list lab1`（指定したホストだけ）。登録済みのホストは `sh client/cubby hosts`。

Desktop には登録した SSH 接続を編集・削除する画面がない時期がありました。接続名は作業単位で使い回す運用をおすすめします。

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

- `ctr-x` と `gpu-x` は別のコンテナ・別の worktree・別のブランチです（GPU の有無はコンテナを作るときに決まるため）。
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

## 片付け

ホスト上で実行します（`ssh lab1` してから）。

```sh
ctr-remove ctr-feature1          # 対象を表示して確認を求める
ctr-remove -y ctr-feature1       # 確認を省略
ctr-remove --force ctr-feature1  # 未コミットの変更があっても worktree を消す
```

コンテナ → worktree → ホームのボリュームの順で消します。**未コミットの変更があると、何も消さずに止まります**。ブランチは消しません。

手元の登録だけを消すには `sh client/cubby remove-host lab1`（`~/.ssh/config` の cubby ブロックと known_hosts の `cubby-lab1` を消します。ホスト上のものは残ります）。

## テスト

```sh
sh client/cubby preflight lab1                     # ホストの事前確認（変更しない）
sh tests/smoke.sh lab1                             # テスト用の ctr-smoke を作って確認する
sh tests/smoke.sh lab1 --cleanup                   # 最後に ctr-remove で片付ける（ブランチは残る）
CTR_WT_ROOT=/home/alice/worktrees sh tests/smoke.sh lab2   # worktree の置き場が既定と違うとき
```

Desktop での確認（セッションがコンテナ内で動く・再起動後に戻る・別名で別コンテナ・同時に動かしても干渉しない）は手作業で行います。手順は [docs/handoff-ctr-connect.md](docs/handoff-ctr-connect.md) の 6.6 を参照してください。

## トラブル時の確認箇所

| 症状 | 確認すること |
|---|---|
| `cannot ssh to <host>` | `ssh <host>` が単体で通るか。ホスト名・ネットワーク、cloudflared のログイン（ブラウザ） |
| `could not log in ... with the password` | ログインのパスワード。ホストの sshd がパスワード認証を許可しているか |
| `key authentication still fails` | ホストの `~`・`~/.ssh` の権限（グループや他人が書けると sshd が鍵を無視する）。鍵にパスフレーズがあるなら ssh-agent に登録されているか |
| `accepts only public keys` | ホストがパスワード認証を許可していない。最初の鍵の登録だけ別の手段で行う |
| `this host has no usable GPU` | `cubby hosts` の `gpu=`。ホストで `nvidia-smi` が通るか（ドライバ）。通るなら `cubby add-host` を再実行 |
| `gpu=no` なのに GPU がある | ドライバの更新後なら `cubby add-host` の再実行で CDI の定義を作り直す。`add-host` の出力の `WARNING`（toolkit の導入や `nvidia-ctk cdi generate` の失敗） |
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
- **Windows 版 Desktop について**: Windows 標準の OpenSSH（9.5）では、生成した設定（パターン `Host ctr-*.<id>`・ProxyCommand・%n）が sh なしで動くことを確認済みです。一方、Desktop が内蔵の SSH クライアントを使う場合に同じ設定を解釈するかは未検証です。パターンが解釈されない場合は、[client/ssh_config.snippet](client/ssh_config.snippet) を参考に接続名ごとに `Host ctr-feature1.lab1` と書き分けてください。
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
| ホストの事前準備（docker・git の導入、ディレクトリ作成）は手作業 | `cubby add-host` が必要なときだけ sudo で自動実行（`host/bootstrap-root.sh`） | 利用者の要望 |
| ホストへのログインは鍵認証が前提 | パスワード認証のホストでも、`add-host` が初回に公開鍵を登録する | 利用者の要望 |
| GPU の扱いなし | 接続名 `gpu-<作業名>` で GPU 付きコンテナ（CDI `nvidia.com/gpu=all`）。NVIDIA Container Toolkit と CDI の定義を自動で準備し、使えるホストかを自動判定 | 利用者の要望 |
| — | `~/.ssh/config` の書き換えを mkdir のロックで排他する | 複数の `add-host` を同時に動かすと互いのブロックを上書きしたため（検証で判明） |
| `docker run --init` | イメージに tini を入れて PID 1 にする | ホストの catatonit の有無に依存しないため |
| 手元は macOS・Linux の OpenSSH 前提、`~/.ssh/config` に手で追記 | Windows・macOS・Linux に対応。`~/.ssh/config` の先頭に管理ブロックを書く（`Include` は使わない）。ProxyCommand は絶対パス。Windows は Windows 標準の OpenSSH を使う | 利用者の要望。GUI から起動した Desktop の PATH が最小限のため |
