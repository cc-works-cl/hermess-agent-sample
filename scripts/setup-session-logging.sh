#!/usr/bin/env bash
# Session Manager のセッションログを CloudWatch Logs (/hermes/ssm-sessions) に出す。
# 注意: この設定は「アカウント × リージョン」全体に効く（SSM-SessionManagerRunShell ドキュメント）。
# 同じアカウントで他のインスタンスにも SSM を使っている場合は、その影響を確認してから実行すること。
source "$(dirname "$0")/_common.sh"

LOG_GROUP="${LOG_GROUP:-/hermes/ssm-sessions}"
content="$(cat <<EOF
{
  "schemaVersion": "1.0",
  "description": "Session Manager preferences",
  "sessionType": "Standard_Stream",
  "inputs": {
    "cloudWatchLogGroupName": "${LOG_GROUP}",
    "cloudWatchEncryptionEnabled": false,
    "cloudWatchStreamingEnabled": true,
    "s3BucketName": "",
    "idleSessionTimeout": "60",
    "runAsEnabled": false,
    "shellProfile": { "linux": "" }
  }
}
EOF
)"

if aws ssm describe-document --name SSM-SessionManagerRunShell >/dev/null 2>&1; then
  echo "既存の SSM-SessionManagerRunShell を更新します"
  aws ssm get-document --name SSM-SessionManagerRunShell --query Content --output text
  read -r -p "上書きしてよいですか? [y/N] " ans
  [ "$ans" = "y" ] || exit 1
  aws ssm update-document --name SSM-SessionManagerRunShell \
    --content "$content" --document-version '$LATEST' --document-format JSON
  ver="$(aws ssm describe-document --name SSM-SessionManagerRunShell --query Document.LatestVersion --output text)"
  aws ssm update-document-default-version --name SSM-SessionManagerRunShell --document-version "$ver"
else
  aws ssm create-document --name SSM-SessionManagerRunShell \
    --document-type Session --document-format JSON --content "$content"
fi
echo "done"
