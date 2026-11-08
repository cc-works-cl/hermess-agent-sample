terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # ConoHa 公式のプロバイダー（VPS Ver.3.0 専用、ベータ版）
    # https://registry.terraform.io/providers/gmo-internet/conohavps/latest/docs
    # ベータ版で予告なく挙動が変わりうるので、バージョンは固定する。
    conohavps = {
      source  = "gmo-internet/conohavps"
      version = "= 0.1.0"
    }
  }
}

# 認証情報（user_id / password / tenant_id）はここに書かず、環境変数で渡す。
#   CONOHAVPS_USER_ID / CONOHAVPS_PASSWORD / CONOHAVPS_TENANT_ID
# 環境変数とこのブロックの両方に値があると、環境変数が優先される（プロバイダーの仕様）。
provider "conohavps" {
  region            = var.region
  identity_endpoint = var.identity_endpoint
}
