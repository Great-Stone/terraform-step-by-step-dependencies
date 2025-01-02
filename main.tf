data "aws_caller_identity" "current" {}

resource "aws_vpc" "example" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.example.id
  availability_zone       = data.aws_availability_zones.available.names.0
  cidr_block              = cidrsubnet(aws_vpc.example.cidr_block, 8, 0) // "10.0.0.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "public" {
  vpc_id = aws_vpc.example.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.example.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.public.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "public" {
  domain = "vpc"
}

resource "aws_nat_gateway" "public" {
  allocation_id = aws_eip.public.id
  subnet_id     = aws_subnet.public.id
}

// SG
resource "aws_security_group" "example" {
  name   = "example"
  vpc_id = aws_vpc.example.id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group_rule" "example_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.example.id
}

resource "aws_security_group_rule" "vault_http" {
  type              = "ingress"
  from_port         = 8200
  to_port           = 8200
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.example.id
}

// key pair
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "ssh_private" {
  content  = tls_private_key.ssh.private_key_pem
  filename = "${path.module}/ssh_private"
}

resource "random_id" "key_id" {
  keepers = {
    ami_id = tls_private_key.ssh.public_key_openssh
  }

  byte_length = 8
}

resource "aws_key_pair" "ssh" {
  key_name   = "key-${random_id.key_id.hex}"
  public_key = tls_private_key.ssh.public_key_openssh
}

// EC2
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "ubuntu" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.ssh.key_name
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.example.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 200
  }

  tags = {
    Name = "ubuntu"
  }
}

########################
# 1st wating
resource "terraform_data" "vault" {

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.ubuntu.public_ip
    private_key = tls_private_key.ssh.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      /* APT UPDATE */
      "echo ====== APT UPDATE ======",
      "sudo apt-get update && sudo NEEDRESTART_MODE=a apt-get -y upgrade",
      /* Vault */
      "echo ====== Vault Install ======",
      "sudo apt-get update && sudo apt-get install -y gnupg software-properties-common",
      "wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list",
      "sudo apt-get update && sudo apt-get install vault -y",
      "sudo systemctl enable vault",
      "sudo systemctl start vault",
    ]
  }
}

########################
# 2nd wating
data "http" "vault_init" {
  depends_on = [terraform_data.vault]

  url      = "https://${aws_instance.ubuntu.public_ip}:8200/v1/sys/init"
  method   = "POST"
  insecure = true

  # Optional request headers
  request_headers = {
    Accept = "application/json"
  }

  request_body = jsonencode({
    secret_shares    = 1
    secret_threshold = 1
  })

  retry {
    attempts = 1000
  }
}

resource "terraform_data" "get_vault_unseal_key" {
  depends_on = [data.http.vault_init]

  provisioner "local-exec" {
    command = <<-EOF
    echo "vault_init status code : ${data.http.vault_init.status_code}"
    if [ ${data.http.vault_init.status_code} -eq 200 ]; then
        echo ${jsondecode(data.http.vault_init.response_body).keys[0]}  > ${path.module}/vault_unseal_key
        echo ${jsondecode(data.http.vault_init.response_body).root_token}  > ${path.module}/vault_root_token
    else
        echo "Response was not 200. Not Update"
    fi
    EOF
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      rm -rf ${path.module}/vault_unseal_key
      rm -rf ${path.module}/vault_root_token
    EOF
  }
}

########################
# 3rd wating
data "external" "read_keys" {
  depends_on = [terraform_data.get_vault_unseal_key]
  program    = ["bash", "${path.module}/read_keys.sh"]
}

data "http" "vault_unseal" {
  depends_on = [data.external.read_keys]

  url      = "https://${aws_instance.ubuntu.public_ip}:8200/v1/sys/unseal"
  method   = "POST"
  insecure = true

  # Optional request headers
  request_headers = {
    Accept = "application/json"
  }

  request_body = jsonencode({
    key = data.external.read_keys.result.vault_unseal_key
  })

  retry {
    attempts = 1000
  }
}