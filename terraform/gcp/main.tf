# One Compute Engine VM that installs the Station from Headquarters (the installer Headquarters serves
# at /connector/v1/install.sh), starts it and enrolls it with the join token. The firewall, the size
# class and the install line match deploy/aws/ripty-connector.yaml. Google's Infrastructure Manager
# runs this module too (README.md).

provider "google" {
  project = var.project_id == "" ? null : var.project_id
  region  = var.region
}

locals {
  # The Meeting Sites (80, 8080, 8000) and the Signal Sites (22000 ssh, 33890 RDP).
  station_ports = [80, 8080, 8000, 22000, 33890]
  has_ssh_key   = var.ssh_public_key != ""
  has_ssh_rule  = local.has_ssh_key && var.ssh_cidr != ""
  has_dns       = var.dns_zone != ""
  zone          = sort(data.google_compute_zones.available.names)[0]

  # The log is /var/log/ripty-install.log. The variables are checked by validation blocks in
  # variables.tf, so they hold no quote or shell character. Compute Engine runs a startup script at
  # every boot, so the script stops at once after an install that succeeded.
  user_data = <<-EOT
    #!/bin/bash
    if [ -e /var/lib/ripty-install.done ]; then exit 0; fi
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
      ANSWER_IP=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
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
    if [ "$STATUS" -eq 0 ]; then touch /var/lib/ripty-install.done; fi
    exit $STATUS
  EOT
}

data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}

resource "google_compute_network" "station" {
  name                    = var.station_name
  auto_create_subnetworks = true
}

resource "google_compute_firewall" "station" {
  name          = "${var.station_name}-sites"
  network       = google_compute_network.station.name
  direction     = "INGRESS"
  source_ranges = [var.allowed_cidr]
  target_tags   = [var.station_name]

  allow {
    protocol = "tcp"
    ports    = [for p in local.station_ports : tostring(p)]
  }
}

resource "google_compute_firewall" "dns" {
  count         = local.has_dns ? 1 : 0
  name          = "${var.station_name}-dns"
  network       = google_compute_network.station.name
  direction     = "INGRESS"
  source_ranges = [var.allowed_cidr]
  target_tags   = [var.station_name]

  allow {
    protocol = "tcp"
    ports    = ["53"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }
}

resource "google_compute_firewall" "ssh" {
  count         = local.has_ssh_rule ? 1 : 0
  name          = "${var.station_name}-ssh"
  network       = google_compute_network.station.name
  direction     = "INGRESS"
  source_ranges = [var.ssh_cidr]
  target_tags   = [var.station_name]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_instance" "station" {
  name         = var.station_name
  machine_type = var.instance_size
  zone         = local.zone
  tags         = [var.station_name]

  # Ubuntu 24.04 LTS, x86_64.
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = google_compute_network.station.id

    # An empty access_config gives the VM an ephemeral public IPv4 address.
    access_config {}
  }

  metadata = local.has_ssh_key ? { "ssh-keys" = "ripty:${trimspace(var.ssh_public_key)}" } : {}

  metadata_startup_script = local.user_data

  lifecycle {
    precondition {
      condition     = (var.console_pin == "") == (var.console_spki == "")
      error_message = "console_pin and console_spki go together: set both or neither."
    }
  }
}
