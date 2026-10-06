# The schematic describes the image: kernel arguments and system extensions. Its ID is a hash of the
# file's content, so the same schematic.yaml always produces the same ID.
resource "talos_image_factory_schematic" "this" {
  schematic = file("${path.module}/schematic.yaml")
}

# nocloud is the Talos platform that reads the cloud-init drive Proxmox attaches, which is how each VM
# gets its static address before it has a machine config.
data "talos_image_factory_urls" "this" {
  talos_version     = var.talos_version
  schematic_id      = talos_image_factory_schematic.this.id
  platform          = "nocloud"
  disk_image_format = "qcow2"
}

# One copy of the image per Proxmox node that hosts a VM. Proxmox downloads it straight from the Image
# Factory over its own API, so there is no template VM to build and no SSH access to the host.
resource "proxmox_download_file" "talos" {
  for_each = local.proxmox_nodes

  node_name    = each.key
  datastore_id = var.image_datastore
  content_type = "import"
  url          = data.talos_image_factory_urls.this.urls.disk_image
  file_name    = "talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}-nocloud-amd64.qcow2"

  # A version plus schematic names an immutable image, so there is nothing to re-check upstream.
  overwrite = false
  # The factory builds an image the first time it is requested, which can take a few minutes.
  upload_timeout = 1800
}
