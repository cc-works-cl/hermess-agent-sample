#!/usr/bin/env bash
# Ubuntu 24.04 LTS (amd64) の最新 AMI ID を表示する。infra/cdk.json の context "amiId" に設定して使う。
source "$(dirname "$0")/_common.sh"

aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text
