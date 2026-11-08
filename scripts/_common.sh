# 各スクリプトから source する共通設定
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-hermes}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
STACK_NAME="${STACK_NAME:-HermesAgentStack}"

instance_id() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text
}
