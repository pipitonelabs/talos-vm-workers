# talos-vm-workers

OpenTofu configuration that creates [Talos Linux](https://www.talos.dev) worker VMs on Proxmox VE, ready to
join an existing Kubernetes cluster.

It creates the machines and nothing else. Each VM boots a Talos image at a static address and waits in
maintenance mode; the machine config that makes it join the cluster is applied from wherever that config
already lives. No cluster secret ever enters this repo or its state.

> **Status.** Applied to a real Proxmox VE host: two VMs were created, joined an existing Talos 1.14 /
> Kubernetes cluster as workers and passed a workload test (pod networking, DNS, Ceph RBD and NFS volumes).
> Offline checks (`tofu validate` and the mocked tests in `tests/`) run in CI.

## How it works

```
schematic.yaml ──▶ Image Factory ──▶ Proxmox downloads the nocloud disk image (API, no SSH)
                                              │
workers.auto.tfvars ──▶ one VM per node ◀─────┘   static IP + hostname via the cloud-init drive
                              │
                              ▼
                 Talos in maintenance mode on <ip>:50000
                              │   talosctl apply-config --insecure   (your machine config, your secrets)
                              ▼
                     worker joins the cluster
```

- **No template VM and no Packer.** Proxmox downloads the `nocloud` disk image straight from the Talos Image
  Factory and imports it as the VM's system disk.
- **Static addresses from the inventory.** Proxmox writes each VM's address, gateway, DNS servers and name to
  a cloud-init drive. Talos reads the network settings from it, ignores the `#cloud-config` user data, and
  waits for a real machine config. No DHCP reservation is needed.
- **Stable MAC addresses**, derived from the VM ID (`BC:24:11` plus the low 24 bits) unless you set one.
- **An apply never reboots a node.** A change that needs a restart warns or fails instead, so you can drain
  the node first.

## Requirements

**Workstation:** [OpenTofu](https://opentofu.org) 1.8+ (or Terraform 1.8+), [just](https://just.systems), `jq`,
and the [1Password CLI](https://developer.1password.com/docs/cli/) if you keep the credentials there.

**Proxmox VE** 8.4 or newer (9.x is what the provider targets):

- **A datastore that allows the Import content type** for the image (`image_datastore`, default `local`).
  Check with `pvesm status --content import`. To add it, list the storage's current content types and
  include `import`, because the command replaces the whole list:

  ```sh
  pvesm set local --content iso,vztmpl,backup,import
  ```

- **A datastore for VM disks** (`vm_datastore`, default `local-lvm`). SSD-backed and thin-provisioned is the
  sensible choice; see [Storage](#storage).
- **A bridge on the node network** (`bridge`, default `vmbr0`), with `vlan_id` set if that network is tagged.
  The VMs must be able to reach the cluster's API endpoint and the other nodes. If the cluster's CNI routes
  pod traffic natively between nodes, the VMs have to sit in the same layer-2 network as the existing nodes.
- **An API token.** No SSH access to the host is needed. Start from the role in the
  [provider's documentation](https://registry.terraform.io/providers/bpg/proxmox/latest/docs#api-token-authentication)
  and trim it. This configuration creates VMs, writes to two datastores, downloads a file by URL and uses a
  bridge, which should come down to roughly: `VM.Allocate`, `VM.Audit`, `VM.PowerMgmt`, `VM.GuestAgent.Audit`,
  `VM.Config.CPU`, `VM.Config.Memory`, `VM.Config.Disk`, `VM.Config.Network`, `VM.Config.Options`,
  `VM.Config.HWType`, `VM.Config.Cloudinit`, `VM.Config.CDROM`, `Datastore.Audit`, `Datastore.AllocateSpace`,
  `Datastore.AllocateTemplate`, `Sys.Audit`, `Sys.AccessNetwork`, `SDN.Use`. That exact list was enough to create,
  change and restart the VMs on a live host; privilege names can differ between PVE 8 and 9. See
  [Creating the API user and token](#creating-the-api-user-and-token) for the permission paths and a gotcha.

## Credentials

Nothing secret is stored in this repo. The provider reads its settings from the environment:

| Variable | Example |
|---|---|
| `PROXMOX_VE_ENDPOINT` | `https://pve.example.com:8006/` |
| `PROXMOX_VE_API_TOKEN` | `terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `PROXMOX_VE_INSECURE` | `true`, only for a self-signed certificate |

`just plan`, `just apply` and `just destroy` run OpenTofu through `op run --env-file=op.env`, which resolves
the 1Password references in [`op.env`](op.env) at run time. Point those references at your own item. To skip
1Password, export the variables yourself and set `TF_RUNNER=""`:

```sh
export PROXMOX_VE_ENDPOINT=... PROXMOX_VE_API_TOKEN=...
TF_RUNNER="" just plan
```

Never save a plan to a file you might commit (`-out`): a saved plan embeds the token in plain text. The
`.gitignore` blocks the usual names, but the safe habit is not to create one inside the repo.

### Creating the API user and token

Use a dedicated user with a least-privilege role and a **privilege-separated** token, never `root@pam`. Run this
once in the Proxmox shell (adjust the node name, storage IDs and expiry):

```sh
pveum role add TalosWorkers -privs "VM.Allocate VM.Audit VM.PowerMgmt VM.GuestAgent.Audit VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network VM.Config.Options VM.Config.HWType VM.Config.Cloudinit VM.Config.CDROM Datastore.Audit Datastore.AllocateSpace Datastore.AllocateTemplate Sys.Audit Sys.AccessNetwork SDN.Use"
pveum user add tofu@pve --comment "OpenTofu worker VMs"
pveum user token add tofu@pve provider --privsep 1 --expire "$(date -d '+30 days' +%s)"   # prints the secret once
for path in /vms /storage/local /storage/<vm-datastore> /sdn/zones/localnetwork /nodes/<node>; do
  pveum aclmod "$path" -user 'tofu@pve' -role TalosWorkers      # see the gotcha below
  pveum aclmod "$path" -token 'tofu@pve!provider' -role TalosWorkers
done
```

- **Grant the role to the user as well as the token.** With privilege separation a token's effective permissions
  are the *intersection* of the token's and its user's permissions. A token with the role but an unprivileged user
  authenticates fine (`/version` returns 200) and then has no permissions at all.
- **The full token value** is `user@realm!tokenid=<uuid>`, and the token ID must match the name you created
  (`provider` above). The secret is shown only once; if you lose it, remove and recreate the token (this also
  deletes its ACLs).
- A 401 means the token itself is wrong; a working token with an empty `GET /access/permissions` means missing ACLs.
- **TLS:** the provider verifies the Proxmox certificate. For a self-signed or private CA, trust it on your
  workstation (for example add `/etc/pve/pve-root-ca.pem` to the system trust store) or set
  `PROXMOX_VE_INSECURE=true` on a trusted network only.

## Usage

```sh
just init      # download the providers
just check     # formatting, validation and the mocked tests; needs no credentials
just plan      # review
just apply     # create the VMs
just nodes     # name, address, MAC, VM ID
just wait w0   # block until w0 answers on the Talos API port
```

Everything you normally edit is in [`workers.auto.tfvars`](workers.auto.tfvars):

```hcl
talos_version = "v1.14.0"   # version of the image new VMs start from

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
```

Per-node settings: `vm_id` and `ip` are required; `cores` (4), `memory_mb` (8192), `disk_gb` (100),
`mac_address` (derived), `nic_queues` (twice `cores`, at most 64), `proxmox_node` (the default node) and `started`
(`true`) are optional.
[`schematic.yaml`](schematic.yaml) sets the system extensions baked into the image.

## From zero to a working worker

1. **Proxmox:** the API user and token above; a datastore that allows the Import content type; a VM datastore;
   a VLAN-aware bridge if `vlan_id` is set. Put the endpoint and token in the secret store `op.env` points at.
2. **Create the VMs:** edit `workers.auto.tfvars`, then `just init`, `just check`, `just plan`, `just apply`. The VMs
   boot into Talos maintenance mode at their static address (`just wait w0` blocks until the API answers).
3. **Cluster-side prerequisites** (these live in your cluster repo, not here):
   - The CNI must use the VM's NIC (`eth0`), for example Cilium `devices: [bond+, eth+]`.
   - If a descheduler balances load, an empty worker makes it evict pods from busy nodes. Scope its node selector
     to the existing nodes until you want that balancing.
   - Keep Ceph daemons (mon, mgr, MDS, OSD) off the VMs with a node affinity; the VMs are Ceph clients only.
   - If the router peers over BGP per node, add the new addresses as neighbors.
4. **Join:** apply the worker machine config (see below). The node registers and goes `Ready` within about 30
   seconds; DaemonSets start on it.
5. **Verify:** `kubectl get nodes` shows the node `Ready`; a pod pinned to it (`nodeName`) can resolve DNS, reach
   pods on other nodes in both directions and mount your storage.
6. **Optional role label:** `kubectl get nodes` shows `<none>` for the role of a worker. The ROLES column is built
   from `node-role.kubernetes.io/<role>` labels, and a worker's kubelet may not set that prefix on itself
   (Kubernetes `NodeRestriction`; Talos applies labels with the kubelet's credentials on workers, with
   control-plane credentials on control-plane nodes). Add it as an admin:
   `kubectl label node w0 node-role.kubernetes.io/worker=`. It is cosmetic, but you must re-add it if the node is
   ever deleted and re-registered.

## Joining a node to the cluster

A new VM sits in maintenance mode until it gets a machine config. Apply your cluster's **worker** config to
its address:

```sh
talosctl apply-config --insecure --nodes 192.168.10.13 --file worker.yaml
```

`--insecure` is needed only for this first apply. There is nothing to install (Talos is already on the disk)
and no bootstrap step for a worker: once it has the config, the node registers with the cluster.

What the worker config has to account for on these VMs:

- **Install image.** Set it to `just installer-image`
  (`factory.talos.dev/nocloud-installer/<schematic>:<version>`). Upgrades then keep this schematic and the
  `nocloud` platform. An installer for another schematic or platform would drop the extensions, or stop
  reading the cloud-init drive that carries the node's address.
- **Network.** The NIC is `eth0` and already has its address from cloud-init, so do not configure that
  interface in the machine config. A hostname set in the config overrides the VM name.
- **CNI device selection.** If your CNI is told which devices to use (for example Cilium's `devices`), make
  sure the pattern matches `eth0`.
- **Hardware-specific settings.** Leave out anything that belongs to physical machines: bonds, NIC ring sizes,
  CPU frequency tuning, GPU labels. `/dev/watchdog0` exists when `watchdog = true` (the default), so a
  `WatchdogTimerConfig` works.

### Network queues

Each VM's virtio NIC gets `2 x cores` queues (capped at Proxmox's limit of 64). A CNI that attaches XDP programs to
the NIC, such as Cilium with `loadBalancer.acceleration: best-effort`, needs one extra TX queue per vCPU. With a
single-queue NIC the Talos kernel logs `virtio_net ... XDP request 9 queues but max is 1. XDP_TX and XDP_REDIRECT
will operate in a slower locked tx mode.` The VM still works, only slower for XDP forwarding. Set `nic_queues` on a
node to override the default. Changing the queue count takes effect after the VM restarts, so drain a node that is
already in the cluster first.

## Storage

Each VM gets **one disk**: the Talos system disk, `disk_gb` in size. Talos keeps its own partitions small and
gives the rest to `EPHEMERAL` (`/var`), which holds container images, logs, `emptyDir` volumes and anything
provisioned from the node's filesystem (hostPath-style local volumes).

- **Size it for what lands on the node, not for Talos.** Talos itself needs under 10 GB. 100 GB is a sensible
  floor; go higher if databases or caches use node-local volumes.
- **Put it on SSD-backed, thin-provisioned storage** (LVM-thin or ZFS). The disk is created with `discard=on`
  and SSD emulation so freed blocks can be returned to the pool.
- **The disk is disposable.** Nothing on it is needed to rebuild the node, so worker VMs do not need to be in
  a backup job.

### With Rook/Ceph (or any CSI storage)

A worker that only **consumes** cluster storage needs no extra disk and no Proxmox-side preparation. For
Rook/Ceph:

- The Talos kernel has the RBD and CephFS clients built in, so the Ceph CSI node plugin can map and mount
  volumes on the VM as it does on any other node.
- The CSI node-plugin DaemonSets must be able to schedule there. If you taint the workers, add matching
  tolerations to the CSI driver.
- The VM needs network reach to the Ceph monitors and OSDs. In a cluster whose Ceph daemons use the pod
  network, that follows from the node being able to route to pod addresses.
- With `useAllNodes: true`, Rook runs an OSD-prepare job on each new node. It creates an OSD only if a device
  matches the cluster's device filter, and this configuration attaches no data disks, so it finds nothing.
  An explicit node list in the `CephCluster` avoids even the job.

**Ceph with msgr2.** If your Ceph cluster requires msgr2 (`requireMsgr2: true`), CephFS kernel mounts need
`ms_mode=prefer-crc` (or `secure`), because the kernel client defaults to msgr v1 and the mons close the connection
(`libceph: ... (con state V1_BANNER)`, then "no mds (Metadata Server) is up"). That is a cluster setting, not a VM
setting. With the ceph-csi-operator, Rook reads it from `CephCluster.spec.csi.cephfs.kernelMountOptions`. RBD is not
affected.

Running **Ceph OSDs inside these VMs** is a different project and is not configured here. If you go that way:
give the OSD whole physical disks (pass through the disks or the HBA, never a virtual disk on top of ZFS,
LVM or RAID); keep to one OSD VM per physical host, or model the host in the CRUSH map, because Ceph treats
every VM as a separate host and could otherwise place all replicas of some data on one machine; and expect
the slowest OSD and its network link to set the pace for writes across the pool.

## Upgrades and day-two changes

- **Talos and Kubernetes upgrades happen in the cluster** (`talosctl upgrade`, or an upgrade controller), using
  the node's install image. Changing `talos_version` or `schematic.yaml` here never touches a running VM: it
  only changes the image that **new** VMs start from. Keep `talos_version` at the version the cluster runs.
- **Add a node:** add an entry to `nodes`, `just apply`, then apply the worker config to it.
- **Remove a node:** drain it and delete it from Kubernetes, remove its entry from `nodes`, then `just apply`.
- **Change cores or memory:** edit the entry and `just apply`. Nothing restarts by itself: the change is either
  left pending or refused with an error. Drain the node, stop and start the VM, and apply again if needed.
- **Grow the disk:** raise `disk_gb` and `just apply`. Check that Talos has grown `EPHEMERAL` after the next
  reboot (`talosctl get volumestatus`). Shrinking is not possible.
- **Recreate a node:** `just destroy -target='proxmox_virtual_environment_vm.worker["w0"]'`, then `just apply`.
  It comes back with the same address and MAC, in maintenance mode.

### Applying a hardware-level change to a running node

Changes such as the NIC queue count are stored as *pending* in Proxmox and only take effect after the VM restarts
(a restart from inside the guest is not enough). For a node that is already in the cluster:

```sh
kubectl drain w0 --ignore-daemonsets --delete-emptydir-data
# Proxmox "reboot" shuts the VM down and starts it again, applying pending changes (needs VM.PowerMgmt):
curl -s -X POST -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "${PROXMOX_VE_ENDPOINT}api2/json/nodes/<node>/qemu/<vm_id>/status/reboot"
kubectl uncordon w0
```

A configured Talos node boots back with its stored config and rejoins on its own. A node still in maintenance mode
can simply be restarted.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `x509: certificate is not trusted` during `plan` or `apply` | The workstation does not trust the Proxmox certificate; trust its CA (see [Credentials](#creating-the-api-user-and-token)). |
| `401` / "Authentication failed" | Wrong token value or token ID; recreate the token. A working token with no permissions needs the role on the user as well (see above). |
| VM boots but is unreachable | Wrong `vlan_id`, or the bridge is not VLAN-aware. Changing `vlan_id` is applied live. |
| Kernel log: `XDP request N queues but max is 1` | A single-queue virtio NIC with a CNI that attaches XDP. This module sets `2 x cores` queues by default; restart the VM after changing it. |
| Node `Ready` but ROLES is `<none>` | Cosmetic; see step 6 of [From zero to a working worker](#from-zero-to-a-working-worker). |
| CephFS volume stays `ContainerCreating` with "no mds is up" | msgr2 and the kernel mount option; see the Ceph note under [Storage](#storage). |

## State

State is local by default (`terraform.tfstate`, ignored by git). It holds VM IDs, addresses and MACs, but no
credentials. Losing it is recoverable with `tofu import`, but a remote backend is safer. Add one in a
`backend_override.tf`, which git ignores:

```hcl
terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "talos-vm-workers.tfstate"
    region = "us-east-1"
    endpoints = { s3 = "https://s3.example.com" }

    use_path_style              = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}
```

Avoid keeping this state inside the cluster the VMs belong to: you want to be able to manage the machines
when the cluster is down.

## Layout

| File | Purpose |
|---|---|
| `workers.auto.tfvars` | Environment settings and the node inventory |
| `schematic.yaml` | Image Factory schematic (system extensions) |
| `image.tf` | Schematic ID, image URL, download to Proxmox |
| `workers.tf` | The VMs |
| `variables.tf`, `outputs.tf`, `versions.tf`, `providers.tf` | Inputs, outputs, provider pins |
| `tests/` | Mocked tests, run by `just check` and CI |
| `op.env` | 1Password references for the Proxmox endpoint and token |
