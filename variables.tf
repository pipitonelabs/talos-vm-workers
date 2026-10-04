variable "talos_version" {
  description = "Talos version of the disk image that new VMs are created from. Running nodes are upgraded in the cluster, not by changing this."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_version))
    error_message = "talos_version must look like v1.14.0."
  }
}

variable "proxmox_node" {
  description = "Proxmox node that hosts the VMs, unless a node sets its own proxmox_node."
  type        = string
}

variable "image_datastore" {
  description = "Datastore the Talos disk image is downloaded to. It must allow the Import content type."
  type        = string
  default     = "local"
}

variable "vm_datastore" {
  description = "Datastore for the VM system disk, the EFI vars disk and the cloud-init drive."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Proxmox bridge the VM NIC attaches to."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the VM NIC. Leave null when the bridge is already on the node network untagged."
  type        = number
  default     = null
}

variable "gateway" {
  description = "IPv4 default gateway handed to every VM through cloud-init."
  type        = string
}

variable "dns_servers" {
  description = "DNS servers handed to every VM through cloud-init."
  type        = list(string)
}

variable "cpu_type" {
  description = "Emulated CPU type. Talos needs x86-64-v2 or newer, so the Proxmox default kvm64 does not boot. host is fastest but prevents live migration between different CPUs."
  type        = string
  default     = "host"
}

variable "watchdog" {
  description = "Attach a virtual i6300esb watchdog (/dev/watchdog0) that resets the VM if Talos stops feeding it. It only arms once the machine config has a WatchdogTimerConfig."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Proxmox tags applied to every VM."
  type        = list(string)
  default     = ["kubernetes", "talos", "worker"]
}

variable "nodes" {
  description = "Worker VMs, keyed by name. The name becomes the VM name and the hostname cloud-init hands to Talos."
  type = map(object({
    vm_id        = number
    ip           = string
    cores        = optional(number, 4)
    memory_mb    = optional(number, 8192)
    disk_gb      = optional(number, 100)
    mac_address  = optional(string)
    proxmox_node = optional(string)
    started      = optional(bool, true)
  }))

  validation {
    condition     = alltrue([for name in keys(var.nodes) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name))])
    error_message = "Node names must be lowercase DNS labels (letters, digits and hyphens)."
  }

  validation {
    condition     = alltrue([for node in values(var.nodes) : length(split("/", node.ip)) == 2 && can(cidrhost(node.ip, 0))])
    error_message = "Each node ip must be an address in CIDR notation, for example 192.168.10.13/24."
  }

  validation {
    condition     = length(distinct([for node in values(var.nodes) : split("/", node.ip)[0]])) == length(var.nodes)
    error_message = "Each node needs its own ip."
  }

  validation {
    condition     = alltrue([for node in values(var.nodes) : node.vm_id >= 100 && node.vm_id == floor(node.vm_id)])
    error_message = "vm_id must be a whole number of 100 or more."
  }

  validation {
    condition     = length(distinct([for node in values(var.nodes) : node.vm_id])) == length(var.nodes)
    error_message = "Each node needs its own vm_id."
  }

  validation {
    condition     = alltrue([for node in values(var.nodes) : node.mac_address == null || can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", node.mac_address))])
    error_message = "mac_address must look like BC:24:11:00:00:71."
  }

  validation {
    condition     = alltrue([for node in values(var.nodes) : node.cores >= 1 && node.memory_mb >= 2048 && node.disk_gb >= 10])
    error_message = "Each node needs at least 1 core, 2048 MB of memory and a 10 GB disk."
  }
}
