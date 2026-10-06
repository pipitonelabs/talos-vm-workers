#!/usr/bin/env -S just --justfile

set positional-arguments
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# OpenTofu by default. Set TF_BIN=terraform to use Terraform instead.
tf := env('TF_BIN', 'tofu')

# Command prefix that puts PROXMOX_VE_* into the environment. The default resolves the 1Password
# references in op.env. Set TF_RUNNER="" if you export the variables yourself.
runner := env('TF_RUNNER', 'op run --env-file=op.env --')

[private]
default:
    just --list

[doc('Download the providers')]
init *args:
    {{ tf }} init "$@"

[doc('Format every file')]
fmt:
    {{ tf }} fmt -recursive

[doc('Offline checks: formatting, validation and the mocked tests (no credentials needed)')]
check:
    {{ tf }} fmt -check -recursive
    {{ tf }} validate
    {{ tf }} test

[doc('Run the mocked tests')]
test *args:
    {{ tf }} test "$@"

[doc('Show what would change')]
plan *args:
    {{ runner }} {{ tf }} plan "$@"

[doc('Create or update the VMs')]
apply *args:
    {{ runner }} {{ tf }} apply "$@"

[confirm('Destroy the worker VMs? Drain and delete the nodes from the cluster first. [y|N]')]
[doc('Destroy VMs (pass e.g. -target to pick one)')]
destroy *args:
    {{ runner }} {{ tf }} destroy "$@"

[doc('List the VMs with their address, MAC and VM ID')]
nodes:
    {{ tf }} output -json nodes | jq -r 'to_entries[] | [.key, .value.ipv4, .value.mac_address, (.value.vm_id | tostring), .value.proxmox_node] | @tsv' | column -t

[doc('Print the installer image to put in the worker machine config')]
installer-image:
    {{ tf }} output -raw installer_image

[doc('Wait until a VM answers on the Talos API port (maintenance mode or configured)')]
wait name:
    #!/usr/bin/env bash
    set -euo pipefail
    ip="$({{ tf }} output -json nodes | jq -r --arg n '{{ name }}' '.[$n].ipv4 // empty')"
    [[ -n "$ip" ]] || { echo "No VM named {{ name }} in the state" >&2; exit 1; }
    until nc -z -w 2 "$ip" 50000 2>/dev/null; do
        echo "Waiting for the Talos API on ${ip}:50000 ..."
        sleep 3
    done
    echo "{{ name }} is answering on ${ip}:50000"
