# Operations guide

## Initial host and VM setup

1. Copy `config/local.env.example` to `config/local.env`, pin a Bitcoin Core
   version, and provide checksummed local ISO paths.
2. Run `sudo ./bin/bvml host-setup`; log out/in so the `libvirt` and `kvm`
   groups apply. Verify `virt-host-validate` and `virsh -c qemu:///system list`.
3. Run `./bin/bvml init`, then `./bin/bvml create ubuntu`, `create umbrel`, and
   `create startos`, completing each installer once. Their system and
   application disks are persistent and never reset by this project.
4. Run `./bin/bvml checkpoint-create`, then `./bin/bvml start ubuntu`. In the
   guest, transfer and run `scripts/vm/guest/ubuntu-bitcoin-core.sh`. It formats
   the first empty overlay, pins the selected Core binary, and writes exactly:

   ```ini
   datadir=/srv/bitcoin/data
   blocksxor=0
   ```

   `blocksxor=0` is required: an XOR-enabled block store is not portable across
   the target applications. Do not add performance, networking, wallet, RPC, or
   pruning settings to the canonical configuration.

## Normal testing

Run `./bin/bvml start <ubuntu|umbrel|startos>`. It creates one fresh overlay
from the canonical qcow2 and records an exclusive owner. Only one VM can start.
Use the appropriate `guest/*-data-adapter.sh` to mount/package the disk in
UmbrelOS or StartOS; those release-specific integrations stay outside the host
storage lifecycle.

Before stopping, shut down Bitcoin cleanly within the guest (for Core use
`bitcoin-cli -conf=/srv/bitcoin/data/bitcoin.conf stop`). Then run
`./bin/bvml stop <vm>`. This waits for ACPI shutdown before releasing ownership.

`./bin/bvml discard <vm>` removes only its Bitcoin overlay. `reset <vm>` is the
same guarded reset operation: it refuses to run while the VM is active. Neither
command touches persistent OS/application disks.

## Updating the checkpoint

Only promote an Ubuntu overlay. Start Ubuntu fresh, synchronize it fully, and
ensure Core is stopped cleanly. Confirm `blocksxor=0`, check the node's best
block/tip, and keep a copy of `bitcoin.conf` with the operation record. Stop
the VM, then run:

```bash
./bin/bvml validate
./bin/bvml checkpoint-update
./bin/bvml validate
./bin/bvml discard ubuntu
```

Promotion converts the stopped Ubuntu overlay to a standalone qcow2, verifies
it with `qemu-img check`, replaces the checkpoint, and reapplies chmod and (if
available) the filesystem immutable bit. It is intentionally not automatic:
the operator must establish that the overlay is a clean, synchronized mainnet
state first. Discard any stopped UmbrelOS or StartOS overlays before their next
start as well: overlays are intentionally tied to the checkpoint they were
created from and must never survive a checkpoint replacement.

## Recovery and maintenance

If power loss leaves an owner record, first use `virsh list --all` to prove the
listed VM is shut off. Then inspect its overlay with `qemu-img check`; after
that, remove the stale `storage/run/bitcoin-data.owner` manually or use `stop`
if the domain still owns it. Never delete or make the canonical image writable
while a domain might be running.

Run `./bin/bvml status` routinely and `./bin/bvml validate` before/after every
checkpoint promotion. Back up the canonical qcow2 while it remains read-only;
also back up the three persistent VM directories separately.
