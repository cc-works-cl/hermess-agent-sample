locals {
  # templatefile() は bash の ${...} を Terraform の補間として解釈してしまうので、
  # CDK 版と同じく __PLACEHOLDER__ を replace() で差し替える。
  # auth key は最後に差し込む（user_data 以降の値は sensitive 扱いになる）。
  ud_template   = file("${path.module}/cloud-init/user-data.sh")
  ud_step1      = replace(local.ud_template, "__CLAUDE_CODE_VERSION__", var.claude_code_version)
  ud_step2      = replace(local.ud_step1, "__TAILSCALE_HOSTNAME__", var.tailscale_hostname)
  ud_step3      = replace(local.ud_step2, "__TAILSCALE_TAGS__", join(",", var.tailscale_tags))
  ud_step4      = replace(local.ud_step3, "__DISABLE_OPENSSH__", var.disable_openssh ? "true" : "false")
  user_data     = replace(local.ud_step4, "__TAILSCALE_AUTH_KEY__", var.tailscale_auth_key)
  user_data_b64 = base64encode(local.user_data)
}

# inbound ルールは 1 つも作らない。
# ConoHa（OpenStack Neutron）は新しいセキュリティグループに IPv4 / IPv6 の egress 全許可ルールを
# 自動で付ける（公開 API のセキュリティグループ作成のレスポンス例で確認）。
# ここで egress ルールを重ねて作ると重複エラーになるので、ルールのリソースは置かない。
resource "conohavps_securitygroup" "hermes" {
  name        = "${var.name_prefix}-egress-only"
  description = "Hermes Agent: no inbound, egress only"
}

# ブートボリューム。~/.hermes と ~/.claude が乗るので消さない・作り直さない。
# EC2 版の「AMI ID の固定」と「DeleteOnTermination: false」に相当する。
resource "conohavps_volume" "boot" {
  name        = "${var.name_prefix}-boot"
  size        = var.boot_volume_size
  volume_type = var.boot_volume_type
  image_ref   = var.image_id
  description = "Hermes Agent boot volume"

  lifecycle {
    prevent_destroy = true

    # イメージを新しくしても既存のボリュームは作り直さない
    ignore_changes = [image_ref]
  }
}

resource "conohavps_instance" "hermes" {
  instance_name_tag = var.instance_name_tag
  admin_pass        = var.admin_pass
  flavor_id         = var.flavor_id
  power_state       = var.power_state
  user_data         = local.user_data_b64

  block_device = [
    {
      uuid = conohavps_volume.boot.id
    },
  ]

  # ここで指定したグループだけが付く（省略すると default グループが付く）
  security_group = [
    {
      name = conohavps_securitygroup.hermes.name
    },
  ]

  lifecycle {
    # user_data と admin_pass は変更するとサーバーが作り直される（プロバイダーの仕様）。
    # cloud-init は初回起動時にしか効かないので、Tailscale のキーを差し替えたときなどに
    # VM が作り直されないよう無視する。
    ignore_changes = [user_data, admin_pass]

    precondition {
      # ConoHa の user_data はエンコード前で 16 KiB まで。base64 後の長さで判定する
      # （length() は文字数を数えるので、日本語コメントを含む元の文字列では判定できない）。
      condition     = nonsensitive(length(local.user_data_b64) <= 21848)
      error_message = "cloud-init のスクリプトが 16 KiB を超えています。コメントを減らしてください。"
    }
  }
}
