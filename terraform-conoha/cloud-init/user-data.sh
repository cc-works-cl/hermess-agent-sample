#!/bin/bash
# Hermes Agent on ConoHa VPS の初回セットアップ。初回起動時に cloud-init が root で 1 回だけ実行する。
# infra/assets/user-data.sh（EC2 版）がベース。差分は Tailscale・メタデータ遮断・OpenSSH 停止。
# この内容はメタデータサービス（169.254.169.254）から読める。Tailscale の auth key 以外の秘密は書かないこと。
# インストーラーが失敗しても Tailscale かコンソールから復旧できるよう、ユーザー・unit・Tailscale を先に用意する。

# auth key は set -x とログ出力を有効にする前に root 専用ファイルへ退避する（トレースやログに残さない）
set -euo pipefail
TS_AUTH_KEY_FILE=/root/.tailscale-authkey
(umask 077 && printf '%s' '__TAILSCALE_AUTH_KEY__' >"$TS_AUTH_KEY_FILE")

LOG=/var/log/hermes-bootstrap.log
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
set -x

HERMES_USER=hermes
CLAUDE_CODE_VERSION="__CLAUDE_CODE_VERSION__"
TS_HOSTNAME="__TAILSCALE_HOSTNAME__"
TS_TAGS="__TAILSCALE_TAGS__"
DISABLE_OPENSSH="__DISABLE_OPENSSH__"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update
apt-get "${APT_OPTS[@]}" upgrade
# libatomic1 は Hermes インストーラーが apt で入れようとするが、hermes ユーザーには sudo がないので先に入れておく
apt-get "${APT_OPTS[@]}" install git curl tar coreutils jq ca-certificates libatomic1 unattended-upgrades iptables

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

# root 以外からメタデータサービスに届かないようにする（EC2 の IMDSv2 + hop limit 1 の代わり）。
# user_data に auth key が入っているので、hermes ユーザーやエージェントのツールから読ませない。
# cloud-init は root で動くので影響しない。再起動後も効くよう oneshot の unit にする。
cat >/etc/systemd/system/block-metadata-nonroot.service <<'EOF'
[Unit]
Description=Block metadata service access for non-root users
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -w -I OUTPUT -d 169.254.169.254/32 -m owner ! --uid-owner 0 -j REJECT
ExecStart=-/usr/sbin/ip6tables -w -I OUTPUT -d fe80::a9fe:a9fe/128 -m owner ! --uid-owner 0 -j REJECT
ExecStop=-/usr/sbin/iptables -w -D OUTPUT -d 169.254.169.254/32 -m owner ! --uid-owner 0 -j REJECT
ExecStop=-/usr/sbin/ip6tables -w -D OUTPUT -d fe80::a9fe:a9fe/128 -m owner ! --uid-owner 0 -j REJECT

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# 専用ユーザー（sudo 権限なし）
if ! id "$HERMES_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$HERMES_USER"
fi
chmod 700 "/home/$HERMES_USER"
sudo -u "$HERMES_USER" -H bash -c 'mkdir -p ~/.hermes ~/.claude ~/.local/bin && chmod 700 ~/.hermes ~/.claude'

# gateway の systemd unit。`hermes gateway install` は使わない（PATH と claude の場所を明示したいので自前の unit にする）。
# unit 名は変えないこと。Hermes（v0.23）は `hermes` 起動時にこの unit を探して start しようとし、
# hermes ユーザーでは権限がなく失敗する（service_start_failed）。インストール後に enable して常時起動しておく。
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

# メタデータ遮断。失敗しても Tailscale の設定までは進める（hermes での各インストーラーより前に効かせる）
systemctl enable --now block-metadata-nonroot.service || { echo "FAILED: metadata block"; status=failed; }

# Tailscale（管理用の経路）。Hermes より先に入れて、Hermes のインストールに失敗しても入れるようにする
if curl -fsSL https://tailscale.com/install.sh | sh; then
  if [ -s "$TS_AUTH_KEY_FILE" ]; then
    ts_args=(up --auth-key="file:${TS_AUTH_KEY_FILE}" --ssh --hostname="$TS_HOSTNAME")
    if [ -n "$TS_TAGS" ]; then
      ts_args+=(--advertise-tags="$TS_TAGS")
    fi
    tailscale "${ts_args[@]}" || { echo "FAILED: tailscale up"; status=failed; }
  else
    echo "tailscale auth key is empty; skipped tailscale up"
  fi
else
  echo "FAILED: tailscale installer"
  status=failed
fi
shred -u "$TS_AUTH_KEY_FILE" 2>/dev/null || rm -f "$TS_AUTH_KEY_FILE"

# 22 番は SG で閉じているが、念のため OpenSSH も止める（管理は Tailscale SSH とコンソールで行う）
if [ "$DISABLE_OPENSSH" = "true" ]; then
  systemctl disable --now ssh.socket ssh.service || true
fi

# Hermes Agent 公式インストーラー
sudo -u "$HERMES_USER" -H bash -lc \
  'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-computer-use' \
  || { echo "FAILED: hermes installer"; status=failed; }

# Claude Code（ネイティブインストーラー、~/.local/bin/claude に入る）
sudo -u "$HERMES_USER" -H bash -lc \
  "curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION}" \
  || { echo "FAILED: claude code installer"; status=failed; }

# メッセージング設定前でも起動できる（待機状態になる）。インストーラーが成功したときだけ有効にする
if grep -q 'FAILED: \(hermes\|claude\)' "$LOG" 2>/dev/null; then
  echo "skip enabling hermes-gateway: installer failed"
else
  systemctl enable --now hermes-gateway || { echo "FAILED: enable hermes-gateway"; status=failed; }
fi

echo "$status" >/var/lib/hermes-bootstrap.status
echo "hermes bootstrap finished: $status"
