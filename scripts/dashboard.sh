#!/usr/bin/env bash
# Hermes ダッシュボード (EC2 の 127.0.0.1:9119) を PC の localhost:9119 に転送する。
# 転送中に http://localhost:9119 を開く。終了は Ctrl+C。
source "$(dirname "$0")/_common.sh"

exec aws ssm start-session --target "$(instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=9119,localPortNumber="${LOCAL_PORT:-9119}"
