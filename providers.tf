# Credentials are read from the environment and never written to a file in this repo or to state:
#
#   PROXMOX_VE_ENDPOINT   https://pve.example.com:8006/
#   PROXMOX_VE_API_TOKEN  user@realm!tokenid=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   PROXMOX_VE_INSECURE   true (only for a self-signed Proxmox certificate)
#
# `just plan` and `just apply` inject them with `op run --env-file=op.env`. See the README.
provider "proxmox" {}

# Only used for the Image Factory resources (schematic ID and image URLs). It needs no configuration
# and never talks to the cluster.
provider "talos" {}
