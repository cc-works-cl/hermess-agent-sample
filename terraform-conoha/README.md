# Hermes Agent on ConoHa VPS（Terraform 版）

AWS EC2 版（[../infra](../infra)、CDK）と同じ構成を、ConoHa VPS Ver.3.0 に Terraform で立てるコード。

- LLM は Claude のサブスク（Pro / Max）を公式プラグイン `claude-subscription-directsdk` 経由で使う
- 対話は Discord のボット経由（スマホ・Mac の両方から）
- セキュリティグループは inbound 全閉・egress のみ。管理作業は **Tailscale SSH だけ**で行う（22 番は開けない）
- 非常口として、ConoHa のコントロールパネルのコンソール（root + `admin_pass`）を残す

> **このコードはまだ一度も apply していない。** `terraform validate` も未実施（作成時の環境に terraform が無かったため）。最初の apply の前に「デプロイ手順」の 3 を必ず行うこと。

## 構成

| リソース | 内容 |
|---|---|
| `conohavps_securitygroup.hermes` | inbound ルールなし。egress は ConoHa が自動で付ける IPv4 / IPv6 全許可ルールのみ |
| `conohavps_volume.boot` | Ubuntu 24.04 から作るブートボリューム（100GB、`c3j1-ds02-boot`）。`prevent_destroy` と `ignore_changes = [image_ref]` で、消えない・作り直されないようにする |
| `conohavps_instance.hermes` | 4GB プラン。上のボリュームから起動し、上の SG だけを付ける。`user_data` と `admin_pass` は `ignore_changes`（変えると VM が作り直されるため） |

cloud-init（[cloud-init/user-data.sh](cloud-init/user-data.sh)）でやること。EC2 版の [infra/assets/user-data.sh](../infra/assets/user-data.sh) がベース:

- OS 更新と unattended-upgrades の有効化
- 4GB の swap 作成
- root 以外のユーザーからメタデータサービス（169.254.169.254）への通信を iptables で遮断（後述）
- `hermes` ユーザー（sudo なし）の作成
- `hermes-gateway.service` の配置と有効化（Hermes と Claude Code のインストールが成功したとき。メッセージング設定前は待機状態で動く）。`CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND=/home/hermes/.local/bin/claude` を絶対パスで指定
- Tailscale のインストールと `tailscale up --ssh`（auth key は `file:` 経由で渡し、使い終わったら消す）
- OpenSSH サーバーの停止（`disable_openssh = false` で残せる）
- Hermes Agent と Claude Code のインストール

## 調査結果（2026-11-07 時点）

### ConoHa VPS の API: Ver.3.0 と Ver.2.0

- 現行の公開 API は **ConoHa VPS Ver.3.0**。Ver.2.0 の API リファレンスは別に残っている [1]
- Ver.3.0 は OpenStack ベースで、認証は Keystone v3。トークンは `POST https://identity.c3j1.conoha.io/v3/auth/tokens` で発行し、**API ユーザー**の ID（または名前）・パスワードと、**テナント ID**（または名前）を使う。コントロールパネルのログインパスワードではない。トークンの有効期限は 24 時間 [2][9]
- Ver.2.0 の Identity は `https://identity.tyo2.conoha.io/v2.0` のような Keystone v2.0 で、リージョン名も違う（tyo1 / tyo2 など）[7][8]。**このコードは Ver.3.0 専用**
- 公開 API ドキュメントの例はすべてリージョン `c3j1`（compute / networking / block-storage / image-service の各エンドポイントも `*.c3j1.conoha.io`）[2][3][4][5]
- Ver.3.0 では、サーバーを作る前にブートボリュームを作っておく必要がある。サーバー作成時に `block_device_mapping_v2[].uuid` でそのボリュームを指定する。`user_data` は base64 で、エンコード前 16 KiB まで [3]
- ブートボリュームのタイプは `c3j1-ds02-boot`、容量は 512MB プラン以外 100 / 200 / 500GB [6]

### Terraform のプロバイダー

- **ConoHa 公式の `gmo-internet/conohavps` を使う**（2026-03-05 公開、v0.1.0、ベータ版、Ver.3.0 専用）[10][11][12]
  - 対応リソース: サーバー、SSH キーペア、ボリューム、セキュリティグループ、セキュリティグループルール
  - **データソースがない**。フレーバーやイメージは名前で引けないので、UUID を API で調べて変数に入れる（[lookup-ids.sh](lookup-ids.sh)）
  - 認証: `user_id` / `password` / `tenant_id` / `region`（既定 `c3j1`）/ `identity_endpoint`（既定 `https://identity.c3j1.conoha.io/v3`）。環境変数 `CONOHAVPS_*` でも渡せ、両方あると環境変数が優先される [11]
  - ベータ版で予告なく変わりうるので、`versions.tf` でバージョンを `= 0.1.0` に固定している
- `terraform-provider-openstack` も、API が OpenStack 互換なので使える可能性はある（`auth_url = "https://identity.c3j1.conoha.io/v3"`）。ただし Ver.3.0 での動作例は見つからず、**未確認**。Ver.2.0 時代の利用例はある [7][8]

### フレーバーとイメージ

- メモリ 4GB のフレーバーは `g2l-t-c4m4` / `g2l-p-c4m4`（いずれも 4 vCPU・4096MB）。ほかに `g2w-*-c4m4`、`g2d-t-c2m4d60` がある [4]
  - `g2l` は Linux、`g2w` は Windows、`t` / `p` は課金形態の違いと推測しているが、**未確認**。`g2l-t-c4m4` を想定しているが、ConoHa の画面か API で確かめてから使うこと
- Ubuntu 24.04 のイメージ名は **未確認**。API ドキュメントの例には `vmi-ubuntu-22.04-amd64` しか載っていない（`min_disk` は 100）[5]。同じ命名なら `vmi-ubuntu-24.04-amd64` のはずだが、`lookup-ids.sh` の出力で確かめること

## ユーザーが用意するもの

| もの | どこで | 使い道 |
|---|---|---|
| ConoHa のアカウント（VPS Ver.3.0） | ConoHa のコントロールパネル | |
| **API ユーザー**の ID とパスワード | コントロールパネル → API → API ユーザー作成 [9] | `CONOHAVPS_USER_ID` / `CONOHAVPS_PASSWORD` |
| **テナント ID** | コントロールパネル → API 情報 | `CONOHAVPS_TENANT_ID` |
| フレーバー ID・イメージ ID | `./lookup-ids.sh` | `flavor_id` / `image_id` |
| root のパスワード（自分で決める） | | `admin_pass`（コンソール用の非常口） |
| Tailscale のアカウントと tailnet | https://login.tailscale.com | |
| tailnet policy の `tagOwners` に `tag:hermes` | Tailscale 管理画面 → Access controls | |
| **Tailscale の auth key** | Tailscale 管理画面 → Settings → Keys | `tailscale_auth_key` |
| Mac・スマホの Tailscale アプリ | | 管理用の接続 |
| Terraform 1.5 以上、curl、jq | Mac | |
| Claude Pro / Max のサブスク、Discord のアカウント | | EC2 版と同じ |

## デプロイ手順

### 1. 認証情報を環境変数に入れる

ConoHa の API 認証情報は tfvars に書かず、環境変数で渡す。シェルの履歴に残したくなければ、パスワードマネージャーの CLI などから読み込む。

```bash
export CONOHAVPS_USER_ID=<API ユーザー ID>
export CONOHAVPS_PASSWORD=<API ユーザーのパスワード>
export CONOHAVPS_TENANT_ID=<テナント ID>
```

### 2. フレーバー ID とイメージ ID を調べる

```bash
cd terraform-conoha
./lookup-ids.sh
```

4GB のフレーバーと Ubuntu の公開イメージが、UUID 付きで一覧表示される。

### 3. Tailscale の準備

1. 管理画面の Access controls で、タグと SSH のルールを書く。例（自分のアカウントに合わせて書き換える）:

   ```jsonc
   {
     "tagOwners": {
       "tag:hermes": ["autogroup:admin"]
     },
     "grants": [
       // 自分の端末から hermes ノードへ届くのを許可する
       { "src": ["you@example.com"], "dst": ["tag:hermes"], "ip": ["*"] }
     ],
     "ssh": [
       // hermes ユーザーへのログイン
       { "action": "check", "src": ["you@example.com"], "dst": ["tag:hermes"], "users": ["hermes"] },
       // root（管理作業）へのログイン。check で定期的に再認証を求める
       { "action": "check", "src": ["you@example.com"], "dst": ["tag:hermes"], "users": ["root"] }
     ]
   }
   ```

   policy の書式は Tailscale のドキュメントで確かめること [14]。
2. Settings → Keys で auth key を作る。推奨設定:
   - **Reusable: オフ**（1 回限り）
   - **Ephemeral: オフ**（理由は「auth key のリスクと緩和策」）
   - **Pre-approved: オン**（デバイス承認を有効にしている tailnet の場合）
   - **Tags: `tag:hermes`**
   - **Expiration: 1 日**（apply の直前に作る）

### 4. tfvars を作る

```bash
cp terraform.tfvars.example terraform.tfvars
```

`flavor_id`、`image_id`、`admin_pass` を埋める。auth key はファイルに書かず、環境変数で渡すほうがよい。

```bash
export TF_VAR_tailscale_auth_key=tskey-auth-...
```

### 5. apply

```bash
terraform init
terraform plan
terraform apply
```

`terraform init` で `.terraform.lock.hcl` ができる。これはコミットしてよい（秘密情報は入らない）。

cloud-init の完了には 5〜10 分ほどかかる。完了すると、Tailscale の管理画面に `hermes-agent` が `tag:hermes` 付きで現れる。

### 6. 接続して状態を確認する

```bash
tailscale ssh root@hermes-agent
```

```bash
tail -n 30 /var/log/hermes-bootstrap.log
cat /var/lib/hermes-bootstrap.status
```

`failed` のときは、ログの `FAILED:` 行を見て該当のインストーラーを再実行する。そのあとは hermes ユーザーで入る。

```bash
tailscale ssh hermes@hermes-agent
```

Tailscale で入れないときは、ConoHa のコントロールパネルでサーバーのコンソールを開き、root と `admin_pass` でログインする。

### 7. 以降の初期設定

EC2 版の [README](../README.md) の「デプロイ後の初期設定」の 2〜5 と同じ（`claude auth login` → プラグイン導入 → `hermes model` → Discord のボット作成 → `hermes gateway setup` → gateway の再起動）。違いは次のとおり。

- `scripts/connect.sh` の代わりに `tailscale ssh hermes@hermes-agent`（hermes ユーザー）と `tailscale ssh root@hermes-agent`（管理者）を使う
- gateway の再起動は root で入って `systemctl restart hermes-gateway`。cloud-init で有効化できなかった場合（`FAILED: enable hermes-gateway` やインストーラーの失敗）は `systemctl enable --now hermes-gateway`
- Tailscale はすでに入っているので、ダッシュボードを見るなら root で `tailscale serve --bg 9119` だけでよい（**Funnel は使わない**）。tailnet の ACL が唯一の防御線になる点は EC2 版と同じ

## auth key のリスクと緩和策

### リスク

| どこに残るか | 誰が読めるか |
|---|---|
| メタデータサービスの user_data（`http://169.254.169.254/openstack/latest/user_data`） | VM の中の全プロセス。トークン不要（EC2 の IMDSv2 のような仕組みは ConoHa では確認できていない） |
| cloud-init のキャッシュ（`/var/lib/cloud/instance/user-data.txt` など） | root |
| tfstate（`user_data`、`tailscale_auth_key`、`admin_pass` が平文） | tfstate を読める人全員 |
| ConoHa の API（サーバー情報の user_data） | API ユーザーの認証情報を持つ人（取得できるかは未確認） |

Hermes はプロンプトインジェクションでツールを使わされうる。メタデータから auth key が読めると、攻撃者が自分のデバイスを tailnet に参加させられるおそれがある。

### 緩和策

1. **1 回限り（non-reusable）のキーにする。** 一度ノード登録に使えば、再利用はできない
2. **有効期限を最短（1 日）にし、apply の直前に作る。** 期限が切れたキーは使えない。登録済みのノードはそのまま使える [13]
3. **事前承認とタグを付ける。** `tag:hermes` を付けると、ノードは個人ではなくタグの権限で動く。ACL で `tag:hermes` から tailnet 内の他の端末に届かないようにしておけば（上の例では `tag:hermes` を src にしたルールがない）、万一乗っ取られても横に広がらない。ただしこれは、Tailscale の既定の全許可ルール（`acls` の `*` → `*:*`）を削除するか置き換えた場合に限る。既定の policy に上の例を足しただけでは、全許可が残る。タグ付きのノードは既定でノードキーの期限切れが無効になる [13]
4. **root 以外からメタデータに届かないようにする。** cloud-init で iptables のルールを入れ（`block-metadata-nonroot.service`）、`hermes` ユーザーやそこから起動されたツールが 169.254.169.254 に届かないようにしている
5. **トレースとログに残さない。** auth key は `set -x` を有効にする前に root 専用ファイルへ書き出し、`tailscale up --auth-key=file:...` で渡して、使い終わったら `shred` で消す。ブートストラップログは permission 600
6. **tfstate を守る。** ローカルの tfstate は `.gitignore` 済み。共有するならリモートバックエンドを暗号化して使う。apply が終わったら Tailscale の管理画面でキーを revoke しておくとよい（使用済みの 1 回限りキーでも、念のため）

**エフェメラルキーは使わない。** エフェメラルなノードは、オフラインになってからおおむね 30〜60 分で tailnet から消える [15]。VM を止めたり長めのメンテナンスをしたりすると、管理経路がなくなりコンソールしか残らない。この構成では 1 回限り・事前承認・タグ付き・短い有効期限のキーで十分に絞れる。

## EC2 版との差分

| 項目 | EC2 版（infra/） | ConoHa 版（terraform-conoha/） |
|---|---|---|
| IaC | CDK v2（TypeScript） | Terraform + `gmo-internet/conohavps` 0.1.0（ベータ） |
| 管理用の経路 | SSM Session Manager（IAM で認可、セッションログを CloudWatch Logs に保存） | Tailscale SSH（tailnet policy で認可）。非常口はコントロールパネルのコンソール。SSM のようなセッションログは残らない（Tailscale の SSH セッション録画は別機能・未検討） |
| 22 番ポート | 開けない | 開けない。OpenSSH も停止 |
| メタデータ | IMDSv2 必須、hop limit 1 | トークン不要の OpenStack メタデータ。iptables で root 以外を遮断 |
| 秘密情報の扱い | UserData に秘密を入れない | UserData に Tailscale の auth key が入る（上の緩和策で絞る） |
| ネットワーク | 専用 VPC・public subnet | ConoHa の共有ネットワークにグローバル IP 付きでつながる。SG で inbound 全閉 |
| ディスク | gp3 30GB 暗号化、`DeleteOnTermination: false` | ブートボリューム 100GB（最小値）、`prevent_destroy`。暗号化の有無は未確認 |
| スナップショット・バックアップ | DLM で毎日スナップショット × 7 世代 | Terraform では管理しない。コントロールパネルか API で**自動バックアップ**を有効にする（API: ボリュームの自動バックアップ有効化）。手動ならボリュームの「イメージ保存」。世代数は未確認 |
| イメージの固定 | AMI ID を context で固定 | `image_id` を変数で固定。変えてもボリュームは作り直さない |
| 停止 | `scripts/instance.sh stop` | `power_state = "SHUTOFF"` で apply（またはコントロールパネル） |
| 料金の目安（常時起動） | t3.medium 約 $40 + EBS 約 $3 + IPv4 約 $3.6 ≒ **約 $47/月** | 4GB プラン（4 vCPU / 100GB）**3,608 円/月**（時間課金 6.6 円/時、税込）＋自動バックアップ 100GB **363 円/月** [16] |

ConoHa で停止中に料金がかかるかは **未確認**（EC2 は停止中もディスクと IPv4 の料金がかかる）。

## 削除

ブートボリュームに `prevent_destroy` を付けているので、`terraform destroy` はそのままでは失敗する。本当に消すときは、先に自動バックアップやイメージ保存でデータを退避してから、`main.tf` の `prevent_destroy` を `false` にして実行する。

```bash
terraform destroy
```

サーバーを削除したときにブートボリュームが一緒に消えるかは **未確認**。消えずに残った場合は、コントロールパネルか API で削除する。Tailscale の管理画面からノードを削除するのも忘れずに。

## 未確認事項

- `terraform init` / `validate` / `fmt -check`（作成時に terraform が無く未実施）。`.terraform.lock.hcl` も未生成
- 実際の apply（プロバイダー v0.1.0 の挙動全般）
- Ubuntu 24.04 のイメージ名（`vmi-ubuntu-24.04-amd64` と推測）
- フレーバー名の `t` / `p`、`g2l` / `g2w` / `g2d` の意味。`g2l-t-c4m4` が想定どおりの Linux 4GB プランか
- c3j1 以外のリージョンが Ver.3.0 にあるか
- `terraform-provider-openstack` が Ver.3.0 で使えるか
- ConoHa のメタデータサービスにアクセス制限の仕組み（IMDSv2 相当）があるか。config drive が使えるか
- ConoHa の API でサーバーの user_data を読み出せるか
- ブートボリュームの暗号化の有無
- 自動バックアップの世代数・取得時刻、停止中の課金の有無
- サーバー削除時にブートボリュームが残るか
- ConoHa の Ubuntu イメージで、iptables の owner マッチ（`-m owner`）と `ssh.socket` が想定どおり動くか
- `claude auth login` がヘッドレス環境で完結するか（EC2 版から引き継いだ未確認事項）

## 出典

1. ConoHa 公開 API (VPS Ver.3.0) 目次: https://doc.conoha.jp/reference/api-vps3/
2. トークン発行（Identity API）: https://doc.conoha.jp/reference/api-vps3/api-identity-vps3/identity-post_tokens-v3/
3. VM 作成（Compute API）: https://doc.conoha.jp/reference/api-vps3/api-compute-vps3/compute-create_vm-v3/
4. フレーバー一覧・詳細: https://doc.conoha.jp/reference/api-vps3/api-compute-vps3/compute-get_flavors_list-v3/ 、 https://doc.conoha.jp/reference/api-vps3/api-compute-vps3/compute-get_flavors_detail-v3/
5. イメージ一覧（Image API）: https://doc.conoha.jp/reference/api-vps3/api-image-vps3/image-get_images_list-v3/
6. ボリューム作成・ボリュームタイプ一覧: https://doc.conoha.jp/reference/api-vps3/api-blockstorage-vps3/volume-create_vol-v3/ 、 https://doc.conoha.jp/reference/api-vps3/api-blockstorage-vps3/volume-get_types_list-v3/
   - セキュリティグループ作成（既定の egress ルール）: https://doc.conoha.jp/reference/api-vps3/api-network-vps3/network-create_secgps-v3/
7. OpenStack SDK の Vendor Support（ConoHa: `https://identity.%(region_name)s.conoha.io`、Ver.2.0 時代のリージョン）: https://docs.openstack.org/openstacksdk/2024.1/user/config/vendor-support.html
8. Terraform（OpenStack プロバイダー）で ConoHa の VPS を立てる例（Ver.2.0 時代）: https://dev.to/bmf_san/building-a-vps-with-terraform-and-ansible-354j
9. API ユーザーを作成する: https://doc.conoha.jp/reference/api-vps3/api-cp-vps3/cp-create_api_user-v3/
10. GMO インターネットのプレスリリース「Terraform ConoHa VPS Provider」提供開始（2026-03-05）: https://internet.gmo/news/article/156/
11. 公式プロバイダーのリポジトリ: https://github.com/gmo-internet/terraform-provider-conohavps （docs/ 以下にリソースの仕様）
12. Terraform Registry: https://registry.terraform.io/providers/gmo-internet/conohavps/latest/docs
13. Tailscale: Auth keys: https://tailscale.com/kb/1085/auth-keys
14. Tailscale: Tailscale SSH: https://tailscale.com/kb/1193/tailscale-ssh 、 tailscale up: https://tailscale.com/kb/1241/tailscale-up
15. Tailscale: Ephemeral nodes: https://tailscale.com/kb/1111/ephemeral-nodes
16. ConoHa VPS 料金: https://vps.conoha.jp/pricing/
