output "schematic_id" {
  description = "Image Factory schematic ID built from schematic.yaml."
  value       = talos_image_factory_schematic.this.id
}

output "installer_image" {
  description = "Installer image for these VMs. Set it as the install image in the worker machine config so upgrades keep this schematic and platform."
  value       = data.talos_image_factory_urls.this.urls.installer
}

output "disk_image_url" {
  description = "Disk image that new VMs are created from."
  value       = data.talos_image_factory_urls.this.urls.disk_image
}

output "nodes" {
  description = "Worker VMs: where each one runs and how to reach it."
  value = {
    for name, vm in proxmox_virtual_environment_vm.worker : name => {
      vm_id        = vm.vm_id
      proxmox_node = vm.node_name
      ipv4         = local.nodes[name].ipv4
      mac_address  = local.nodes[name].mac_address
    }
  }
}
