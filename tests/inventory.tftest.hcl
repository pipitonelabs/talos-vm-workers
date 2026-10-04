# Offline tests: both providers are mocked, so nothing here needs Proxmox, the Image Factory or
# credentials. Run with `just test`.

# The mocks return fixed, realistic values for the attributes the providers normally compute.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = {
      id = "local:import/talos-v1.14.0-29d123fd-nocloud-amd64.qcow2"
    }
  }
}

mock_provider "talos" {
  mock_resource "talos_image_factory_schematic" {
    defaults = {
      id = "29d123fd0e746fccd5ff52d37c0cdbd2d653e10ae29c39276b6edb9ffbd56cf4"
    }
  }

  mock_data "talos_image_factory_urls" {
    defaults = {
      urls = {
        disk_image = "https://factory.talos.dev/image/29d123fd0e746fccd5ff52d37c0cdbd2d653e10ae29c39276b6edb9ffbd56cf4/v1.14.0/nocloud-amd64.qcow2"
        installer  = "factory.talos.dev/nocloud-installer/29d123fd0e746fccd5ff52d37c0cdbd2d653e10ae29c39276b6edb9ffbd56cf4:v1.14.0"
      }
    }
  }
}

variables {
  talos_version = "v1.14.0"
  proxmox_node  = "pve"
  gateway       = "192.168.10.1"
  dns_servers   = ["192.168.10.1"]

  nodes = {
    w0 = { vm_id = 113, ip = "192.168.10.13/24", cores = 8, memory_mb = 32768, disk_gb = 200 }
    w1 = { vm_id = 70000, ip = "192.168.10.14/24", mac_address = "bc:24:11:aa:bb:cc", proxmox_node = "pve2" }
  }
}

run "one_vm_per_node_with_static_address" {
  command = plan

  assert {
    condition     = length(proxmox_virtual_environment_vm.worker) == 2
    error_message = "Expected one VM per entry in nodes."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].initialization[0].ip_config[0].ipv4[0].address == "192.168.10.13/24"
    error_message = "The node ip must reach cloud-init unchanged."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].initialization[0].ip_config[0].ipv4[0].gateway == "192.168.10.1"
    error_message = "The gateway must reach cloud-init."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].cpu[0].cores == 8 && proxmox_virtual_environment_vm.worker["w0"].memory[0].dedicated == 32768
    error_message = "cores and memory_mb must reach the VM."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w1"].cpu[0].cores == 4 && proxmox_virtual_environment_vm.worker["w1"].memory[0].dedicated == 8192
    error_message = "Omitted sizes must fall back to the defaults."
  }
}

run "mac_address_is_stable" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].network_device[0].mac_address == "BC:24:11:00:00:71"
    error_message = "VM 113 (0x71) must derive BC:24:11:00:00:71."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w1"].network_device[0].mac_address == "BC:24:11:AA:BB:CC"
    error_message = "An explicit mac_address must win and be upper-cased."
  }

  assert {
    condition     = output.nodes["w0"].mac_address == "BC:24:11:00:00:71" && output.nodes["w0"].ipv4 == "192.168.10.13"
    error_message = "The nodes output must report the address without the prefix length."
  }
}

run "image_is_downloaded_once_per_proxmox_node" {
  command = plan

  assert {
    condition     = toset(keys(proxmox_download_file.talos)) == toset(["pve", "pve2"])
    error_message = "Expected one image download per Proxmox node that hosts a VM."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w1"].node_name == "pve2"
    error_message = "A node's proxmox_node must override the default."
  }
}

run "safe_for_kubernetes_nodes" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].reboot_after_update == false
    error_message = "An apply must never reboot a node by itself."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].memory[0].floating == 0
    error_message = "Ballooning must stay off; Talos does not support memory hotplug."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["w0"].scsi_hardware == "virtio-scsi-pci"
    error_message = "VirtIO SCSI single is known to hang Talos."
  }
}

run "rejects_duplicate_vm_id" {
  command = plan

  variables {
    nodes = {
      w0 = { vm_id = 113, ip = "192.168.10.13/24" }
      w1 = { vm_id = 113, ip = "192.168.10.14/24" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_duplicate_ip" {
  command = plan

  variables {
    nodes = {
      w0 = { vm_id = 113, ip = "192.168.10.13/24" }
      w1 = { vm_id = 114, ip = "192.168.10.13/24" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_ip_without_prefix" {
  command = plan

  variables {
    nodes = {
      w0 = { vm_id = 113, ip = "192.168.10.13" }
    }
  }

  expect_failures = [var.nodes]
}

run "rejects_invalid_name" {
  command = plan

  variables {
    nodes = {
      Worker_0 = { vm_id = 113, ip = "192.168.10.13/24" }
    }
  }

  expect_failures = [var.nodes]
}
