#!/usr/bin/env bash
# SSM で EC2 に入り、hermes ユーザーのログインシェルを開く。
# 引数 --admin を付けると ssm-user（sudo 可）のまま入る。
source "$(dirname "$0")/_common.sh"

id="$(instance_id)"
if [ "${1:-}" = "--admin" ]; then
  exec aws ssm start-session --target "$id"
fi
exec aws ssm start-session --target "$id" \
  --document-name AWS-StartInteractiveCommand \
  --parameters command="sudo -iu hermes"
