# One Azure VM that installs the Station from Headquarters (the installer Headquarters serves at
# /connector/v1/install.sh), starts it and enrolls it with the join token. The firewall, the size
# class and the install line match deploy/aws/ripty-connector.yaml.

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id == "" ? null : var.subscription_id
}

locals {
  # The Meeting Sites (80, 8080, 8000) and the Signal Sites (22000 ssh, 33890 RDP).
  station_ports = [80, 8080, 8000, 22000, 33890]
  has_ssh_key   = var.ssh_public_key != ""
  has_ssh_rule  = local.has_ssh_key && var.ssh_cidr != ""
  has_dns       = var.dns_zone != ""

  # Azure wants one unique priority per inbound rule. Each rule has a fixed one (station ports
  # 100-104, DNS 110-111, SSH 120), so setting dns_zone or ssh_cidr later never moves the others.
  station_rules = { for i, p in local.station_ports : "tcp-${p}" => { protocol = "Tcp", port = p, cidr = var.allowed_cidr, priority = 100 + i } }
  dns_rules     = { for i, p in ["Tcp", "Udp"] : "${lower(p)}-53" => { protocol = p, port = 53, cidr = var.allowed_cidr, priority = 110 + i } if local.has_dns }
  ssh_rules     = { for p in ["Tcp"] : "ssh-22" => { protocol = p, port = 22, cidr = var.ssh_cidr, priority = 120 } if local.has_ssh_rule }
  ingress_rules = merge(local.station_rules, local.dns_rules, local.ssh_rules)

  # Azure needs an SSH key for the VM. With none given, the VM gets a throwaway one that nothing uses.
  admin_key = trimspace(local.has_ssh_key ? var.ssh_public_key : tls_private_key.unused[0].public_key_openssh)

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
      # A cloud host answers with its private address unless it is told its public one. The
      # Standard SKU address is Static and Terraform knows it before the VM exists (Azure's
      # metadata service does not report a Standard SKU address).
      set -- "$@" --dns-zone "$DNS_ZONE" --dns-answer-ip '${azurerm_public_ip.station.ip_address}'
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

resource "tls_private_key" "unused" {
  count     = local.has_ssh_key ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_resource_group" "station" {
  name     = var.station_name
  location = var.region
}

resource "azurerm_virtual_network" "station" {
  name                = var.station_name
  location            = azurerm_resource_group.station.location
  resource_group_name = azurerm_resource_group.station.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "station" {
  name                 = var.station_name
  resource_group_name  = azurerm_resource_group.station.name
  virtual_network_name = azurerm_virtual_network.station.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "station" {
  name                = var.station_name
  location            = azurerm_resource_group.station.location
  resource_group_name = azurerm_resource_group.station.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "station" {
  name                = var.station_name
  location            = azurerm_resource_group.station.location
  resource_group_name = azurerm_resource_group.station.name
}

resource "azurerm_network_security_rule" "station" {
  for_each = local.ingress_rules

  name                        = each.key
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = each.value.cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.station.name
  network_security_group_name = azurerm_network_security_group.station.name
}

resource "azurerm_network_interface" "station" {
  name                = var.station_name
  location            = azurerm_resource_group.station.location
  resource_group_name = azurerm_resource_group.station.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.station.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.station.id
  }
}

resource "azurerm_network_interface_security_group_association" "station" {
  network_interface_id      = azurerm_network_interface.station.id
  network_security_group_id = azurerm_network_security_group.station.id
}

resource "azurerm_linux_virtual_machine" "station" {
  name                            = var.station_name
  location                        = azurerm_resource_group.station.location
  resource_group_name             = azurerm_resource_group.station.name
  size                            = var.instance_size
  admin_username                  = "ripty"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.station.id]
  custom_data                     = base64encode(local.user_data)

  admin_ssh_key {
    username   = "ripty"
    public_key = local.admin_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  # Ubuntu 24.04 LTS, x86_64.
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  depends_on = [azurerm_network_interface_security_group_association.station]

  lifecycle {
    precondition {
      condition     = (var.console_pin == "") == (var.console_spki == "")
      error_message = "console_pin and console_spki go together: set both or neither."
    }
  }
}
