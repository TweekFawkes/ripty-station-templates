# One DigitalOcean droplet that installs the Station from Headquarters (the installer Headquarters
# serves at /connector/v1/install.sh), starts it and enrolls it with the join token. The firewall, the
# size class and the install line match deploy/aws/ripty-connector.yaml. The provider reads the API
# token from DIGITALOCEAN_TOKEN.

locals {
  # The Meeting Sites (80, 8080, 8000) and the Signal Sites (22000 ssh, 33890 RDP).
  station_ports = [80, 8080, 8000, 22000, 33890]
  has_ssh_key   = var.ssh_public_key != "" || var.ssh_key_name != ""
  has_ssh_rule  = local.has_ssh_key && var.ssh_cidr != ""
  has_dns       = var.dns_zone != ""

  station_rules = { for p in local.station_ports : "tcp-${p}" => { protocol = "tcp", port = p, cidr = var.allowed_cidr } }
  dns_rules     = { for p in ["tcp", "udp"] : "${p}-53" => { protocol = p, port = 53, cidr = var.allowed_cidr } if local.has_dns }
  ssh_rules     = { for p in ["tcp"] : "ssh-22" => { protocol = p, port = 22, cidr = var.ssh_cidr } if local.has_ssh_rule }
  ingress_rules = merge(local.station_rules, local.dns_rules, local.ssh_rules)

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
      ANSWER_IP=$(curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
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

# A key already in the account is read by name: DigitalOcean refuses to add the same key twice
# ("SSH Key is already in use on your account"), so ssh_public_key is only for a key not there yet.
resource "digitalocean_ssh_key" "station" {
  count      = var.ssh_public_key != "" && var.ssh_key_name == "" ? 1 : 0
  name       = var.station_name
  public_key = var.ssh_public_key
}

data "digitalocean_ssh_key" "station" {
  count = var.ssh_key_name != "" ? 1 : 0
  name  = var.ssh_key_name

  lifecycle {
    precondition {
      condition     = var.ssh_public_key == ""
      error_message = "Set ssh_public_key (a key to add to the account) or ssh_key_name (a key already there), not both."
    }
  }
}

resource "digitalocean_droplet" "station" {
  name      = var.station_name
  region    = var.region
  size      = var.instance_size
  image     = "ubuntu-24-04-x64"
  ssh_keys  = concat(digitalocean_ssh_key.station[*].fingerprint, data.digitalocean_ssh_key.station[*].fingerprint)
  user_data = local.user_data

  lifecycle {
    precondition {
      condition     = (var.console_pin == "") == (var.console_spki == "")
      error_message = "console_pin and console_spki go together: set both or neither."
    }
  }
}

resource "digitalocean_firewall" "station" {
  name        = var.station_name
  droplet_ids = [digitalocean_droplet.station.id]

  dynamic "inbound_rule" {
    for_each = local.ingress_rules

    content {
      protocol         = inbound_rule.value.protocol
      port_range       = tostring(inbound_rule.value.port)
      source_addresses = [inbound_rule.value.cidr]
    }
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
