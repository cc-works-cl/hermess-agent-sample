# Hermes Agent on AWS EC2 — 作業計画

## ゴール
AWS CDK で EC2 を 1 台立て、NousResearch の Hermes Agent を常駐させる。LLM は自分の Claude サブスク（OAuth）で動かす。

- AWS profile: `hermes`（SSO / ap-northeast-1）
- Git remote: `https://github.com/cc-works-cl/hermess-agent-sample.git`

## Claude サブスクの使い方: 公式プラグイン `claude-subscription-directsdk`
出典: https://hermes-agent.nousresearch.com/marketplace/claude-subscription-directsdk
（NousResearch/hermes-official-plugins、Official 表記、Experimental）

- Hermes の model-provider プラグイン。中で公式の `claude` (Claude Code CLI) をリクエストごとに起動し、LLM 呼び出しだけを任せる。エージェントループとツール実行は Hermes 側で行う
- 課金はサブスクの **Agent SDK 枠**から引かれ、API キーも従量課金も要らない。**Pro / Max の両方に対応**
  - アカウント側で extra usage を有効にしていると、超過分が課金されうる → 不要ならオフにしておく
- レート制限はサブスクの 5 時間枠に従う
- 前提: Hermes 0.21.4 以上、Python 3.10 以上、`npm install -g @anthropic-ai/claude-code`（Sonnet 5.5 には CLI 2.1.284 以上が必要）
- 認証は `claude auth login` のみ。setup-token や `CLAUDE_CODE_OAUTH_TOKEN` は記載なし
- systemd などで常駐させる場合は環境変数 `USER` が必要（プラグインが補完する）
- 制約: prefill・forced tool choice・n>1 は非対応。ツール結果の後に続くテキストは、遅れてまとめて届くことがある

（以前調べた組み込みの Anthropic OAuth プロバイダーは「Max + extra usage 必須・Pro 非対応」だったので、使わない）

## アーキテクチャ（案）

```
[PC] ----(SSM Session Manager: 管理作業)----------> [EC2: Ubuntu 24.04, SG inbound 全閉]
                                                      ├─ hermes ユーザー
                                                      ├─ ~/.hermes, ~/.claude (EBS gp3 暗号化)
                                                      ├─ systemd: hermes-gateway
                                                      └─ dashboard 127.0.0.1:9119
[スマホ/PC] <-> メッセージングアプリ <-(EC2 から外向きのみ)- gateway   … 対話
[スマホ/PC] <-> Tailscale (tailnet 内のみ) <-(外向きのみ)- tailscaled -> :9119  … ダッシュボード（任意）
```

| 項目 | 方針 |
|---|---|
| IaC | CDK v2 (TypeScript)、1 スタック |
| ネットワーク | 新規 VPC・public subnet 1 つ（NAT なしでコスト削減）。SG は **inbound 全閉**、egress のみ |
| アクセス | SSM Session Manager（SSH 鍵・22 番ポート不要） |
| インスタンス | t3.small（2GB）。当初は t3.medium で構築し、アイドル時のメモリ使用量が約 1GB だったため縮小 |
| OS / ディスク | Ubuntu 24.04 LTS、gp3 30GB 暗号化、`~/.hermes` を保持 |
| IAM | `AmazonSSMManagedInstanceCore` と、セッションログ用の CloudWatch Logs 書き込み権限 |
| 初期化 | UserData で `hermes` ユーザー作成 → 公式 install.sh を `--non-interactive` で実行 → Claude Code CLI を導入 |
| 常駐 | UserData で配置する自前の systemd unit `hermes-gateway.service`（User=hermes、PATH と `claude` の絶対パスを明示） |
| 保護 | AMI ID を固定（置き換え防止）、削除保護、EBS `DeleteOnTermination: false`、DLM で毎日スナップショット × 7 世代 |

## Claude 認証とプロバイダー設定の手順
UserData で `hermes` ユーザー向けに Claude Code CLI も入れておく。認証は SSM セッションから `hermes` ユーザーで手動で行う（トークンはリポジトリにも CDK コードにも入れない）。

```bash
claude auth login            # 表示された URL を Mac のブラウザで開き、コードを貼り戻す（ヘッドレスでの動作は要確認）
hermes plugins install claude-subscription-directsdk
hermes model                 # "Claude Subscription DirectSDK (Experimental)" を選ぶ
```

`~/.hermes/config.yaml` の設定例:

```yaml
model:
  provider: claude-subscription-directsdk-experimental
  default: sonnet
```

認証情報は `~/.claude/` に保存されるので、`~/.hermes/` と一緒に EBS 上に残す。

## セキュリティ対策
基本方針: inbound は全閉、接続は SSM、ダッシュボードは loopback だけで待ち受ける。そのうえで次の対策を入れる。

| # | リスク | 対策 | 実装場所 |
|---|---|---|---|
| 1 | ボットに第三者が命令し、シェル実行などのツールを使う | 許可するユーザー ID を自分だけにする（allowlist）。危険なツールは実行前に承認を求める | Hermes の gateway 設定と承認設定 |
| 2 | プロンプトインジェクションによる不正操作・データ持ち出し | ツールを承認制にする。EC2 に機密情報や不要な認証情報を置かない | Hermes の設定と運用ルール |
| 3 | EC2 上の認証情報（`~/.claude/`、IAM ロール）の窃取 | IMDSv2 を必須にし、hop limit を 1 にする。IAM ロールは `AmazonSSMManagedInstanceCore` とログ出力の権限だけにする。EBS を暗号化する。`~/.hermes` と `~/.claude` は permission 700 | CDK と UserData |
| 4 | AWS アカウントの乗っ取り | SSO に MFA をかける。CloudTrail を確認する。SSM のセッションログを CloudWatch Logs に残す | AWS 側の設定と CDK |
| 5 | インストーラーやプラグインの改ざん | 公式の配布元だけを使う。Hermes はカタログ版（pinned, reviewed）のプラグインを使い、Claude Code はバージョンを固定する | UserData |
| 6 | OS の脆弱性の放置 | unattended-upgrades でセキュリティ更新を自動適用する | UserData |
| 7 | 外部公開しているポートへの攻撃 | ポートは開けない。リモートからダッシュボードを見るときは Tailscale を使う（次の節） | CDK の SG（inbound ルールなし） |

## スマホ・PC からの利用

### 1. 対話: メッセージングアプリ経由（メインの使い方）
Hermes gateway をメッセージングアプリにつなぐ。スマホでも PC でも同じアプリから Hermes と対話できる。通信は EC2 から外に向かうだけなので、ポートを開ける必要はない。

- **Discord に決定**（無料プランで使える。Gateway WebSocket で外向き接続だけで動く）
- Discord Developer Portal でアプリとボットを作り、Message Content Intent を有効にする → 自分専用のサーバーに招待して DM で使う
- `hermes gateway setup` で Discord を選んでボットのトークンを登録し、自分の Discord ユーザー ID だけを allowlist に入れる
- ボットのトークンは `~/.hermes/.env`（permission 600）に置き、リポジトリには入れない

### 2. ダッシュボード: Tailscale 経由（任意）
Web ダッシュボード（:9119）をスマホでも見たい場合に使う。

- EC2 に Tailscale を入れ、`tailscale serve` で `127.0.0.1:9119` を自分の tailnet の中だけに公開する。インターネットには公開しない（Funnel は使わない）
- スマホと PC に Tailscale アプリを入れ、同じアカウントでログインする
- Tailscale も外向き通信だけでつながるので、SG の inbound は全閉のままでよい
- tailnet の ACL で、9119 に届くのを自分の端末だけに絞る
- 補足: `tailscale serve` を使うと Hermes から見たアクセス元は loopback になる。そのため Hermes 側の認証には頼れず、tailnet の ACL が唯一の防御線になる

### 3. 管理作業: PC から SSM
OS の操作や認証のやり直しなどの管理作業は、これまでどおり PC から SSM で行う。スマホからはやらない。

## 作業ステップ
1. **リポジトリ準備**: `git init`、remote 設定、`.gitignore`（cdk.out, node_modules, .env 等）、README
2. **前提ツール**: `aws sso login --profile hermes`、`session-manager-plugin` を導入、`gh auth login` をやり直す（現在失敗中）
3. **CDK 実装**: `cdk init app --language typescript` → VPC / SG / IAM Role / EC2 / UserData
4. **デプロイ**: `cdk bootstrap` → `cdk deploy --profile hermes`
5. **Hermes 確認**: SSM で接続して `hermes doctor`
6. **Claude 認証**: `claude auth login` → プラグイン導入 → `hermes model` で DirectSDK を選ぶ → 1 往復して動作確認
7. **Gateway 設定**: `hermes gateway setup` でメッセージングアプリをつなぐ → allowlist とツール承認を設定 → systemd で常駐 → `journalctl -u hermes-gateway -f` で確認 → スマホと PC の両方から対話できるか確認
7.5. **（任意）Tailscale**: EC2 に Tailscale を入れ、`tailscale serve` でダッシュボードを tailnet 内に公開 → ACL を設定 → スマホから表示できるか確認
8. **運用整備**: 停止/起動・接続・ダッシュボード転送のスクリプト（`scripts/`）、コストの目安、`cdk destroy` 手順を README にまとめる
9. commit & push

## 未確認事項
- install.sh の arm64 (Graviton) 対応 → 確認できれば t4g.medium に切り替えてコストを下げる
- `claude auth login` がブラウザのないサーバー上でも完結するか（URL とコードを貼り戻す方式を想定）
- 最小 RAM の公式値（Hermes に加えて、リクエストごとに `claude` プロセスが起動する点も考慮する）
