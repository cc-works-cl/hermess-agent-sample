#!/usr/bin/env bash
# ConoHa VPS 3.0 の公開 API から、terraform.tfvars に書く flavor_id と image_id を調べる。
# 公式プロバイダー（v0.1.0）にはデータソースがないので、UUID は API で引く必要がある。
#
# 使い方:
#   export CONOHAVPS_USER_ID=...  CONOHAVPS_PASSWORD=...  CONOHAVPS_TENANT_ID=...
#   ./lookup-ids.sh
#
# 必要なもの: curl, jq
set -euo pipefail

: "${CONOHAVPS_USER_ID:?CONOHAVPS_USER_ID を設定してください}"
: "${CONOHAVPS_PASSWORD:?CONOHAVPS_PASSWORD を設定してください}"
: "${CONOHAVPS_TENANT_ID:?CONOHAVPS_TENANT_ID を設定してください}"
REGION="${CONOHAVPS_REGION:-c3j1}"
IDENTITY="${CONOHAVPS_IDENTITY_ENDPOINT:-https://identity.${REGION}.conoha.io/v3}"

# パスワードをコマンドライン引数に出さないよう、リクエストボディは標準入力から渡す
TOKEN="$(
  jq -n --arg u "$CONOHAVPS_USER_ID" --arg p "$CONOHAVPS_PASSWORD" --arg t "$CONOHAVPS_TENANT_ID" \
    '{auth:{identity:{methods:["password"],password:{user:{id:$u,password:$p}}},scope:{project:{id:$t}}}}' |
    curl -fsS -o /dev/null -D - -H 'Content-Type: application/json' --data @- "${IDENTITY}/auth/tokens" |
    awk 'tolower($1) == "x-subject-token:" { print $2 }' | tr -d '\r'
)"
if [ -z "$TOKEN" ]; then
  echo "トークンを取得できませんでした" >&2
  exit 1
fi

echo "== メモリ 4GB のフレーバー（id / name / vcpus / ram MB）"
curl -fsS -H "X-Auth-Token: ${TOKEN}" "https://compute.${REGION}.conoha.io/v2.1/flavors/detail" |
  jq -r '.flavors[] | select(.ram == 4096) | [.id, .name, .vcpus, .ram] | @tsv'

echo
echo "== Ubuntu の公開イメージ（id / name / min_disk GB）"
curl -fsS -H "X-Auth-Token: ${TOKEN}" "https://image-service.${REGION}.conoha.io/v2/images?limit=200&visibility=public" |
  jq -r '.images[] | select(.name | test("ubuntu"; "i")) | [.id, .name, (.min_disk | tostring)] | @tsv'
