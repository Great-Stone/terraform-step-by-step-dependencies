output "info" {
  value = {
    client_ip  = "ssh -i ./ssh_private ubuntu@${aws_instance.ubuntu.public_ip}"
    vault_addr = "https://${aws_instance.ubuntu.public_ip}:8200"
  }
}