# Infrastructure Manager runs Terraform 1.5.7 at most and the google provider, so this module needs no
# newer Terraform feature and no other provider.
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
