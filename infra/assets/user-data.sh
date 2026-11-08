#!/bin/bash
# Hermes Agent の初回セットアップ。初回起動時に root で 1 回だけ実行される。
# 秘密情報（トークン類）はここに書かないこと。UserData は IMDS と EC2 API から読める。
# インストーラーが失敗しても SSM から復旧できるよう、ユーザー・ディレクトリ・unit を先に作る。
set -euxo pipefail
exec > >(tee -a /var/log/hermes-bootstrap.log) 2>&1

HERMES_USER=hermes
CLAUDE_CODE_VERSION="__CLAUDE_CODE_VERSION__"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update
apt-get "${APT_OPTS[@]}" upgrade
# libatomic1 は Hermes インストーラーが apt で入れようとするが、hermes ユーザーには sudo がないので先に入れておく
apt-get "${APT_OPTS[@]}" install git curl tar coreutils jq ca-certificates libatomic1 unattended-upgrades

# セキュリティ更新を自動適用する
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

# 4GB メモリに対して、Hermes + Chromium + リクエストごとの claude プロセスは余裕がないので swap を足す
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# 専用ユーザー（sudo 権限なし）
if ! id "$HERMES_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$HERMES_USER"
fi
chmod 700 "/home/$HERMES_USER"
sudo -u "$HERMES_USER" -H bash -c 'mkdir -p ~/.hermes ~/.claude ~/.local/bin && chmod 700 ~/.hermes ~/.claude'

# gateway の systemd unit。`hermes gateway install` は使わない（PATH と claude の場所を明示したいので自前の unit にする）。
# unit 名は hermes-gateway.service のままにすること。Hermes（v0.23 時点）はこの名前の unit を自分の gateway として探し、
# `hermes` の起動時に止まっていれば systemctl start しようとする。hermes ユーザーには権限がないので失敗する
# （service_start_failed）。そのため、インストール後に enable して常時起動しておく。
cat >/etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HERMES_USER}
WorkingDirectory=/home/${HERMES_USER}
Environment=HOME=/home/${HERMES_USER}
Environment=USER=${HERMES_USER}
Environment=PATH=/home/${HERMES_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND=/home/${HERMES_USER}/.local/bin/claude
ExecStart=/home/${HERMES_USER}/.local/bin/hermes gateway run
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ここから先は失敗しても止めず、どこで失敗したかをログに残す
status=ok

# Hermes Agent 公式インストーラー
sudo -u "$HERMES_USER" -H bash -lc \
  'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-computer-use' \
  || { echo "FAILED: hermes installer"; status=failed; }

# Claude Code（ネイティブインストーラー、~/.local/bin/claude に入る）
sudo -u "$HERMES_USER" -H bash -lc \
  "curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION}" \
  || { echo "FAILED: claude code installer"; status=failed; }

# メッセージングを設定する前でも gateway は起動できる（"No messaging platforms enabled" で待機する）
if [ "$status" = ok ]; then
  systemctl enable --now hermes-gateway || { echo "FAILED: enable hermes-gateway"; status=failed; }
fi

echo "$status" >/var/lib/hermes-bootstrap.status
echo "hermes bootstrap finished: $status"
