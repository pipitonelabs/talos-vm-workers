terraform {
  # optional() object attributes need 1.3; the mocked tests in tests/ need OpenTofu 1.8 or Terraform 1.7.
  required_version = ">= 1.8.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.115.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}
