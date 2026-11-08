output "instance_id" {
  description = "サーバーの UUID"
  value       = conohavps_instance.hermes.id
}

output "instance_status" {
  description = "サーバーの状態"
  value       = conohavps_instance.hermes.status
}

output "addresses" {
  description = "サーバーに割り当てられたアドレス。inbound は全閉なので、ここに直接つなぐことはない"
  value       = conohavps_instance.hermes.addresses
}

output "boot_volume_id" {
  description = "ブートボリュームの UUID（自動バックアップの有効化やイメージ保存で使う）"
  value       = conohavps_volume.boot.id
}

output "security_group_name" {
  description = "付与したセキュリティグループ"
  value       = conohavps_securitygroup.hermes.name
}

# キーが空かどうかだけを nonsensitive で取り出す（キーそのものは出さない）
output "tailscale_ssh" {
  description = "管理用の接続コマンド（Tailscale を設定した場合）"
  value       = nonsensitive(var.tailscale_auth_key == "") ? "Tailscale 未設定。ConoHa のコントロールパネルのコンソールから入る" : "tailscale ssh hermes@${var.tailscale_hostname}"
}
