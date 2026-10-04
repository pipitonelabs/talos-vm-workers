# Environment settings and the worker inventory. Nothing in this file is secret: the Proxmox endpoint
# and API token come from the environment (see op.env).

# Keep this equal to the Talos version the cluster runs. It only affects VMs created from now on.
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version = "v1.14.0"

proxmox_node    = "pve"
image_datastore = "local"
vm_datastore    = "local-lvm"
bridge          = "vmbr0"
vlan_id         = null

gateway     = "192.168.10.1"
dns_servers = ["192.168.10.1"]

nodes = {
  w0 = { vm_id = 113, ip = "192.168.10.13/24", cores = 8, memory_mb = 32768, disk_gb = 200 }
  w1 = { vm_id = 114, ip = "192.168.10.14/24", cores = 8, memory_mb = 32768, disk_gb = 200 }
}
