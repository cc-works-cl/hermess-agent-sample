#!/usr/bin/env bash
# EC2 の起動・停止・状態確認。使い方: scripts/instance.sh start|stop|status
source "$(dirname "$0")/_common.sh"

id="$(instance_id)"
case "${1:-status}" in
  start) aws ec2 start-instances --instance-ids "$id" --query 'StartingInstances[0].CurrentState.Name' --output text ;;
  stop) aws ec2 stop-instances --instance-ids "$id" --query 'StoppingInstances[0].CurrentState.Name' --output text ;;
  status) aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 1 ;;
esac
