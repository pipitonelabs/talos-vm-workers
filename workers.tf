locals {
  nodes = {
    for name, node in var.nodes : name => merge(node, {
      proxmox_node = coalesce(node.proxmox_node, var.proxmox_node)
      ipv4         = split("/", node.ip)[0]
      # A stable MAC keeps the VM's identity on the network if it is ever recreated. BC:24:11 is the
      # Proxmox prefix; the rest is the low 24 bits of the VM ID.
      mac_address = upper(coalesce(node.mac_address, format(
        "BC:24:11:%02X:%02X:%02X",
        floor(node.vm_id / 65536) % 256,
        floor(node.vm_id / 256) % 256,
        node.vm_id % 256,
      )))
    })
  }

  proxmox_nodes = toset([for node in local.nodes : node.proxmox_node])
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = local.nodes

  name        = each.key
  node_name   = each.value.proxmox_node
  vm_id       = each.value.vm_id
  description = "Talos Linux worker node. Managed by OpenTofu (talos-vm-workers); do not edit by hand."
  tags        = sort(distinct(var.tags))

  # Settings recommended by the Talos guide for Proxmox: UEFI on q35 and VirtIO SCSI. The guide warns
  # that "VirtIO SCSI single" can hang Talos.
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-pci"
  boot_order    = ["scsi0"]
  tablet_device = false

  on_boot = true
  started = each.value.started

  # A Kubernetes node has to be drained before it goes down, so an apply must never reboot one by
  # itself. Changes that need a restart fail or warn instead; restart the node yourself.
  reboot_after_update = false
  # Destroy stops the VM instead of waiting for a guest shutdown. Remove the node from the cluster first.
  stop_on_destroy = true

  operating_system {
    type = "l26"
  }

  # The schematic includes qemu-guest-agent. Waiting for it to report an address would stall every
  # apply: the address is already known, and the agent is not guaranteed to answer in maintenance mode.
  agent {
    enabled = true

    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    type  = var.cpu_type
    cores = each.value.cores
  }

  # floating = 0 turns ballooning off. Talos does not support memory hotplug.
  memory {
    dedicated = each.value.memory_mb
    floating  = 0
  }

  # Without pre-enrolled keys, Secure Boot stays off, which the standard Talos image needs.
  efi_disk {
    datastore_id      = var.vm_datastore
    type              = "4m"
    pre_enrolled_keys = false
  }

  # The Talos disk image is imported as the system disk and grown to disk_gb. Talos expands its
  # EPHEMERAL partition into the extra space on first boot.
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    import_from  = proxmox_download_file.talos[each.value.proxmox_node].id
    size         = each.value.disk_gb
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = each.value.mac_address
    vlan_id     = var.vlan_id
  }

  # Proxmox renders this into a cloud-init drive. Talos reads the address, gateway, DNS servers and
  # hostname from it. It ignores the #cloud-config user data and waits in maintenance mode for a
  # machine config.
  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  # Serial console for `qm terminal <vmid>` and early boot logs.
  serial_device {}

  dynamic "watchdog" {
    for_each = var.watchdog ? [1] : []

    content {
      enabled = true
      model   = "i6300esb"
      action  = "reset"
    }
  }

  lifecycle {
    # The image only matters when a VM is first created. Talos upgrades happen inside the cluster, so
    # a new talos_version or schematic must not replace the disk of a node that is already running.
    ignore_changes = [disk[0].import_from]
  }
}
