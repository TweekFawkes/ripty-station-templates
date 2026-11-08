variable "console_url" {
  type        = string
  description = <<-EOT
    The Station address of Headquarters, for example https://203.0.113.7:12199. The instance's
    subnet must reach it on that port, and the address must be one the instance can resolve and dial.
  EOT

  validation {
    condition     = can(regex("^https://[A-Za-z0-9._~:/\\[\\]-]*[A-Za-z0-9._~:\\[\\]-]$", var.console_url))
    error_message = "console_url must be an https address with no trailing slash."
  }
}

variable "join_token" {
  type        = string
  sensitive   = true
  description = <<-EOT
    The join token from Add Station (rtt_ plus 43 characters). It works once and expires after one
    day; enrollment spends it. Terraform keeps it in the state file and in the instance's user data
    until it is spent, so keep both private. Create a new join command in Headquarters if it expired.
  EOT

  validation {
    condition     = can(regex("^rtt_[A-Za-z0-9_-]{43}$", var.join_token))
    error_message = "join_token must be rtt_ followed by 43 letters, digits, underscores or hyphens."
  }
}

variable "console_pin" {
  type        = string
  default     = ""
  description = <<-EOT
    The certificate pin from Add Station (sha256: plus 64 hex digits). Leave it empty when the
    Station address of Headquarters has a public certificate. Set it together with console_spki.
  EOT

  validation {
    condition     = can(regex("^$|^sha256:[0-9a-f]{64}$", var.console_pin))
    error_message = "console_pin must be empty, or sha256 and a colon, then 64 lowercase hex digits."
  }
}

variable "console_spki" {
  type        = string
  default     = ""
  description = <<-EOT
    The public key pin from Add Station (sha256// plus 43 characters and an equals sign). Leave it
    empty when console_pin is empty. Set it together with console_pin.
  EOT

  validation {
    condition     = can(regex("^$|^sha256//[A-Za-z0-9+/]{43}=$", var.console_spki))
    error_message = "console_spki must be empty, or sha256// followed by 43 base64 characters and an equals sign."
  }
}

variable "dns_zone" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional. A DNS callback zone, for example oob.example.com. When set, the Station also answers
    DNS for that zone, and the firewall opens UDP and TCP port 53 to allowed_cidr.
  EOT

  validation {
    condition = can(regex(
      "^$|^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$",
      var.dns_zone
    ))
    error_message = "dns_zone must be empty, or a lower-case DNS name with no trailing dot."
  }
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "The Google Cloud region. The VM goes in the first available zone of it."
}

variable "instance_size" {
  type        = string
  default     = "e2-small"
  description = "The machine type. e2-small has 2 GiB of memory, above the Station's 1.5 GiB floor. The Station binary is linux-x64, so choose an x86_64 type."
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Optional. An SSH public key for the ripty user, put in the VM's metadata. Leave it empty for no key; the SSH rule needs this variable and ssh_cidr both."
}

variable "project_id" {
  type        = string
  default     = ""
  description = <<-EOT
    The Google Cloud project for the VM. Leave it empty to use GOOGLE_PROJECT. Infrastructure Manager
    needs it set (see README.md).
  EOT
}

variable "allowed_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = <<-EOT
    Who may reach the Meeting Sites on ports 80, 8080 and 8000 and the Signal Sites on 22000 (ssh) and
    33890 (RDP). The default, 0.0.0.0/0, faces whoever can reach the host, like a default install. For
    an internal deception host, narrow it to your internal ranges.
  EOT

  validation {
    condition     = can(cidrnetmask(var.allowed_cidr))
    error_message = "allowed_cidr must be an IPv4 CIDR range, for example 10.0.0.0/8."
  }
}

variable "ssh_cidr" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional. The range allowed to SSH in (port 22). There is no SSH rule unless both ssh_public_key
    and ssh_cidr are set.
  EOT

  validation {
    condition     = var.ssh_cidr == "" || can(cidrnetmask(var.ssh_cidr))
    error_message = "ssh_cidr must be empty, or an IPv4 CIDR range."
  }
}

variable "station_name" {
  type        = string
  default     = "ripty-station"
  description = "The name tag of the resources. Change it to run a second Station in one account."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.station_name))
    error_message = "station_name must be lower-case letters, digits and hyphens, starting with a letter."
  }
}
