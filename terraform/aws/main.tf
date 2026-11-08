# One EC2 instance that installs the Station from Headquarters (the installer Headquarters serves at
# /connector/v1/install.sh), starts it and enrolls it with the join token. The firewall, the size and
# the install line match deploy/aws/ripty-connector.yaml.

provider "aws" {
  region = var.region
}

locals {
  # The Meeting Sites (80, 8080, 8000) and the Signal Sites (22000 ssh, 33890 RDP).
  station_ports = [80, 8080, 8000, 22000, 33890]
  has_ssh_key   = var.ssh_public_key != ""
  has_ssh_rule  = local.has_ssh_key && var.ssh_cidr != ""
  has_dns       = var.dns_zone != ""

  station_rules = { for p in local.station_ports : "tcp-${p}" => { protocol = "tcp", port = p, cidr = var.allowed_cidr } }
  dns_rules     = { for p in ["tcp", "udp"] : "${p}-53" => { protocol = p, port = 53, cidr = var.allowed_cidr } if local.has_dns }
  ssh_rules     = { for p in ["tcp"] : "ssh-22" => { protocol = p, port = 22, cidr = var.ssh_cidr } if local.has_ssh_rule }
  ingress_rules = merge(local.station_rules, local.dns_rules, local.ssh_rules)

  # With no subnet_id, the first default-VPC subnet (by ID) in an Availability Zone that offers
  # instance_size. A zone is not picked blind: us-east-1e, for one, has no t3 types.
  subnet_id = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.default[0].ids)[0]

  # The log is /var/log/ripty-install.log. The variables are checked by validation blocks in
  # variables.tf, so they hold no quote or shell character.
  user_data = <<-EOT
    #!/bin/bash
    (umask 077; : >>/var/log/ripty-install.log)
    exec >>/var/log/ripty-install.log 2>&1
    echo "ripty-install: start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    CONSOLE_URL='${var.console_url}'
    JOIN_TOKEN='${var.join_token}'
    CONSOLE_PIN='${var.console_pin}'
    CONSOLE_SPKI='${var.console_spki}'
    DNS_ZONE='${var.dns_zone}'
    if [ -n "$CONSOLE_PIN" ] && [ -z "$CONSOLE_SPKI" ]; then
      echo "ripty-install: console_pin needs console_spki too (copy both from Add Station)"
      exit 2
    fi
    if [ -z "$CONSOLE_PIN" ] && [ -n "$CONSOLE_SPKI" ]; then
      echo "ripty-install: console_spki needs console_pin too (copy both from Add Station)"
      exit 2
    fi
    set -- --role connector --console-url "$CONSOLE_URL" --join-token "$JOIN_TOKEN"
    PIN_OPTS=""
    if [ -n "$CONSOLE_PIN" ]; then
      set -- "$@" --console-pin "$CONSOLE_PIN" --console-spki "$CONSOLE_SPKI"
      PIN_OPTS="-k --pinnedpubkey $CONSOLE_SPKI"
    fi
    if [ -n "$DNS_ZONE" ]; then
      set -- "$@" --dns-zone "$DNS_ZONE"
      # A cloud host answers with its private address unless it is told its public one.
      MD_TOKEN=$(curl -fsS --max-time 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
      ANSWER_IP=$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $MD_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
      if printf '%s' "$ANSWER_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        set -- "$@" --dns-answer-ip "$ANSWER_IP"
      fi
    fi
    INSTALLER=/root/ripty-install.sh
    # The token goes to curl on its stdin, so it is on no command line. A cut transfer
    # (curl exit 18 or 56, which --retry does not retry) leaves a partial file, so curl's
    # exit status is checked as well as the file.
    if ! printf 'Authorization: Bearer %s\n' "$JOIN_TOKEN" | curl -fsS --retry 5 --retry-delay 10 --retry-connrefused $PIN_OPTS -H @- -o "$INSTALLER" "$CONSOLE_URL/connector/v1/install.sh" || [ ! -s "$INSTALLER" ]; then
      rm -f "$INSTALLER"
      echo "ripty-install: could not fetch the installer from $CONSOLE_URL/connector/v1/install.sh"
      exit 24
    fi
    bash "$INSTALLER" "$@"
    STATUS=$?
    rm -f "$INSTALLER"
    echo "ripty-install: installer exit $STATUS"
    exit $STATUS
  EOT
}

# The AMI is read from a public SSM parameter: the current Ubuntu 24.04 LTS (x86_64).
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_vpc" "default" {
  count   = var.subnet_id == "" ? 1 : 0
  default = true
}

# The Availability Zones in this region that offer instance_size.
data "aws_ec2_instance_type_offerings" "station" {
  count         = var.subnet_id == "" ? 1 : 0
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_size]
  }
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.station[0].locations
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "No subnet of the default VPC is in an Availability Zone that offers instance_size. Set subnet_id, or pick another instance_size or region."
    }
  }
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

resource "aws_key_pair" "station" {
  count           = local.has_ssh_key ? 1 : 0
  key_name_prefix = "${var.station_name}-"
  public_key      = var.ssh_public_key
}

resource "aws_security_group" "station" {
  name_prefix = "${var.station_name}-"
  description = "Ripty Station: the Meeting Sites and Signal Sites, and SSH when ssh_public_key and ssh_cidr are set"
  vpc_id      = data.aws_subnet.selected.vpc_id

  tags = {
    Name = var.station_name
  }
}

resource "aws_vpc_security_group_ingress_rule" "station" {
  for_each = local.ingress_rules

  security_group_id = aws_security_group.station.id
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.station.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "station" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_size
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.station.id]
  associate_public_ip_address = true
  key_name                    = local.has_ssh_key ? aws_key_pair.station[0].key_name : null
  user_data                   = local.user_data

  # EC2 runs user data on the first boot only, so a new token (or any other change to it) needs a
  # new server, as it does on the other three clouds.
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = var.station_name
  }

  lifecycle {
    # The SSM parameter moves to a new AMI every few weeks. A new ami would replace the enrolled
    # Station on any later apply, and the new server would boot with a spent join token.
    ignore_changes = [ami]

    precondition {
      condition     = (var.console_pin == "") == (var.console_spki == "")
      error_message = "console_pin and console_spki go together: set both or neither."
    }
  }
}
