# bitcoin-vm-lab

Persistent Ubuntu, UmbrelOS, and StartOS KVM/libvirt machines sharing one
**sequentially attached** Bitcoin mainnet data set. Each run receives a
disposable qcow2 overlay backed by a protected canonical checkpoint.

The entry point is `./bin/bvml`; begin with:

```bash
./bin/bvml host-setup
./bin/bvml init
./bin/bvml create ubuntu
./bin/bvml start ubuntu
```

Read [docs/OPERATIONS.md](docs/OPERATIONS.md) before creating or updating the
checkpoint. It describes guest-side synchronization and verification steps.

## Storage model

```
storage/
  canonical/bitcoin-mainnet.qcow2       immutable, read-only checkpoint
  overlays/<vm>/bitcoin-mainnet.qcow2   disposable active overlay
  vms/<vm>/system.qcow2                 persistent guest OS
  vms/<vm>/application.qcow2            persistent application data
  run/bitcoin-data.owner                active attachment record
```

The canonical disk is never attached to a VM. `start` first takes an exclusive
lock and creates a new overlay. `stop` releases the owner record only after
libvirt confirms the domain is inactive.

## Commands

`./bin/bvml help` lists commands. Important commands are `create`, `start`,
`stop`, `discard`, `reset`, `checkpoint-update`, `validate`, and `status`.

## Scope and assumptions

The scripts target an amd64 Gentoo host and libvirt's `qemu:///system`
connection. Guest installation ISOs are supplied locally and selected and
checksummed by the operator. See `config/local.env.example`.
