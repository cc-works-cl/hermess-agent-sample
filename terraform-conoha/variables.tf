# ---------------------------------------------------------------------------
# ConoHa の接続先
# ---------------------------------------------------------------------------

variable "region" {
  description = "ConoHa VPS 3.0 のリージョン。公開 API ドキュメントの例はすべて c3j1（東京）"
  type        = string
  default     = "c3j1"
}

variable "identity_endpoint" {
  description = "Identity API のエンドポイント"
  type        = string
  default     = "https://identity.c3j1.conoha.io/v3"
}

# ---------------------------------------------------------------------------
# VM とボリューム
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "セキュリティグループとボリュームの名前の接頭辞"
  type        = string
  default     = "hermes"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,64}$", var.name_prefix))
    error_message = "name_prefix は英数字・ハイフン・アンダースコアの 1〜64 文字にしてください。"
  }
}

variable "instance_name_tag" {
  description = "コントロールパネルに表示されるサーバー名（ネームタグ）"
  type        = string
  default     = "hermes-agent"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,255}$", var.instance_name_tag))
    error_message = "instance_name_tag は英数字・ハイフン・アンダースコアの 1〜255 文字にしてください。"
  }
}

variable "flavor_id" {
  description = "フレーバー（プラン）の UUID。名前ではなく ID を渡す。4GB プランは g2l-t-c4m4 など。lookup-ids.sh で調べる"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.flavor_id))
    error_message = "flavor_id は UUID 形式で指定してください（フレーバー名ではなく ID）。"
  }
}

variable "image_id" {
  description = "ブートボリュームの元になる Ubuntu 24.04 イメージの UUID。lookup-ids.sh で調べる。変更しても既存ボリュームは作り直さない（ignore_changes）"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.image_id))
    error_message = "image_id は UUID 形式で指定してください。"
  }
}

variable "boot_volume_size" {
  description = "ブートボリュームの容量 (GB)。512MB プラン以外は 100 / 200 / 500 のいずれか"
  type        = number
  default     = 100

  validation {
    condition     = contains([100, 200, 500], var.boot_volume_size)
    error_message = "boot_volume_size は 100, 200, 500 のいずれかにしてください。"
  }
}

variable "boot_volume_type" {
  description = "ブートボリュームのボリュームタイプ"
  type        = string
  default     = "c3j1-ds02-boot"
}

variable "admin_pass" {
  description = "root のパスワード。Tailscale が使えないときに、ConoHa のコントロールパネルのコンソールから入るための非常口。tfstate に平文で残る"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_pass) >= 9 && length(var.admin_pass) <= 70
    error_message = "admin_pass は 9〜70 文字にしてください。"
  }

  validation {
    condition     = can(regex("[A-Z]", var.admin_pass)) && can(regex("[a-z]", var.admin_pass)) && can(regex("[0-9]", var.admin_pass)) && can(regex("[^A-Za-z0-9]", var.admin_pass))
    error_message = "admin_pass には大文字・小文字・数字・記号をそれぞれ 1 文字以上含めてください。"
  }
}

variable "power_state" {
  description = "サーバーの電源状態。ACTIVE（起動）または SHUTOFF（停止）"
  type        = string
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "SHUTOFF"], var.power_state)
    error_message = "power_state は ACTIVE か SHUTOFF にしてください。"
  }
}

# ---------------------------------------------------------------------------
# cloud-init に渡す値
# ---------------------------------------------------------------------------

variable "claude_code_version" {
  description = "Claude Code のネイティブインストーラーに渡すバージョン。stable / latest / x.y.z。2.1.284 以上が必要"
  type        = string
  default     = "stable"

  validation {
    condition     = can(regex("^(stable|latest|[0-9]+\\.[0-9]+\\.[0-9]+)$", var.claude_code_version))
    error_message = "claude_code_version は stable / latest / x.y.z のいずれかにしてください。"
  }
}

variable "tailscale_auth_key" {
  description = "Tailscale の auth key（tskey-auth-...）。1 回限り・事前承認・タグ付き・短い有効期限のキーを推奨。空文字にすると Tailscale を設定しない（コンソールからしか入れなくなる）。user_data・メタデータ・tfstate に残る"
  type        = string
  sensitive   = true

  validation {
    condition     = var.tailscale_auth_key == "" || can(regex("^tskey-[A-Za-z0-9_-]+$", var.tailscale_auth_key))
    error_message = "tailscale_auth_key は tskey- で始まる auth key か、空文字にしてください。"
  }
}

variable "tailscale_hostname" {
  description = "tailnet 上のノード名（MagicDNS 名になる）"
  type        = string
  default     = "hermes-agent"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.tailscale_hostname))
    error_message = "tailscale_hostname は英小文字・数字・ハイフンの 1〜63 文字にしてください。"
  }
}

variable "tailscale_tags" {
  description = "ノードに付けるタグ。auth key を作るときに指定したタグと一致させ、tailnet policy の tagOwners に登録しておく。空リストならタグなし"
  type        = list(string)
  default     = ["tag:hermes"]

  validation {
    condition     = alltrue([for t in var.tailscale_tags : can(regex("^tag:[A-Za-z0-9-]+$", t))])
    error_message = "tailscale_tags の各要素は tag:<名前> の形式にしてください。"
  }
}

variable "disable_openssh" {
  description = "true なら OpenSSH サーバーを止めて無効化する。管理は Tailscale SSH とコンソールで行うので通常は不要"
  type        = bool
  default     = true
}
