# bitcoin-vm-lab

`bitcoin-vm-lab` manages persistent Ubuntu, UmbrelOS, and StartOS guests under
Gentoo system libvirt. One protected Bitcoin signet checkpoint may back one
independent disposable qcow2 overlay per VM, allowing resource-limited
concurrent consumer testing. The canonical image is never attached directly.

Runtime storage defaults to `/var/lib/libvirt/images/bitcoin-vm-lab`, outside
the repository:

```text
canonical/bitcoin-signet.qcow2          protected checkpoint
canonical/bitcoin-signet.rollback.qcow2 optional full-size rollback (disabled by default)
adapters/startos/bitcoin-signet-btrfs.qcow2 protected Btrfs filesystem adapter
active/bitcoin-signet-bootstrap.qcow2   incomplete first-IBD image, when used
active/{ubuntu,umbrel,startos}/          per-VM disposable overlays
run/lifecycles/{ubuntu,umbrel,startos}/  owner, manifest, evidence, lock, recovery
indexes/{electrs,fulcrum}/base.qcow2     protected reusable Electrum index state
vms/{ubuntu,umbrel,startos}/             persistent OS/application disks
```

Fresh Bitcoin Knots signet IBD is the normal initialization path:

```bash
cp config/local.env.example config/local.env
sudo ./bin/bvml host-setup
./bin/bvml host-validate
./bin/bvml storage-prepare
./bin/bvml media-fetch ubuntu
./bin/bvml profiles-install
./bin/bvml create ubuntu
./bin/bvml checkpoint-bootstrap
./bin/bvml bootstrap-init --confirm-bootstrap-format
```

With `UBUNTU_IMAGE_MODE=cloud`, these commands replace the formerly manual
Ubuntu bridge. `media-fetch` applies the same pinned SHA-256, standalone-qcow2,
`qemu-img check`, and read-only validation to existing and downloaded images;
invalid pinned files are quarantined and failed `.part` downloads are removed.
`profiles-install` verifies the exact configured
signer over Knots' signed checksum metadata, proves that metadata binds the
selected archive digest, normalizes the trusted keyring, and atomically installs
a complete root-owned, generation-bound release/RDTS/checkpoint profile set.
`storage-prepare` creates the configured storage hierarchy, grants only
traversal where system QEMU needs it, verifies access, and checks bootstrap
capacity. `create ubuntu` then clones the cloud image, provisions QEMU guest
agent and all digest-pinned guest assets offline, injects the configured SSH
public key, and defines the domain in exact `shut off` state without running
Knots or attaching Bitcoin storage.

All four provisioning commands take the repository lifecycle lock. They refuse
to run while an owner record, Bitcoin attachment, or active VM exists.
`guest-provision ubuntu` is an explicit QGA-based repair/update path for a
running Ubuntu guest only when no Bitcoin lifecycle exists; it waits for the
guest command and propagates failures.
`guest-repair {ubuntu|umbrel} --scripts-only` updates lifecycle code only after
proving all guest profile digests are unchanged. Umbrel adapter assets live
beneath its persistent data directory, not its immutable `/etc` or `/usr/local`
trees. Profile replacement is refused once
bootstrap, canonical, overlay, verification, or recovery state exists.

The bootstrap disk remains explicitly marked incomplete until authenticated
Knots, the operator-approved digest-pinned release-specific RDTS profile,
signet sync, required indexes, best-block freshness, filesystem identity, and
clean shutdown evidence all validate.
`blocksxor=0` is written before the first Knots start. The Ubuntu systemd unit
requires the expected mounted filesystem and fails closed if the disk or UUID
is wrong.

The default reusable checkpoint profile requires the synchronized
`basic block filter index`. Ubuntu creates and maintains it with
`blockfilterindex=basic`; the pinned Umbrel and StartOS package profiles enable
the same index instead of rebuilding incompatible per-platform state.

Electrs and Fulcrum use the same storage model without mixing their databases
into the Bitcoin datadir. Ubuntu builds one protected Btrfs base for each
indexer from the canonical checkpoint. Ubuntu and Umbrel receive independent
Electrs and Fulcrum overlays; StartOS receives a Fulcrum overlay. The official
appliance packages mount these children at their native data-volume paths and
extend them in place. Consumer setup fails closed unless the mounted overlay
already contains the promoted database (`db/bitcoin` / `fulc2_db`) and the live
Electrum height is at or above the protected base tip. Index bases are bound to
the Bitcoin canonical ID and generation, so they block canonical replacement
until deliberately rebuilt.

Electrum ports: Ubuntu/Umbrel Electrs `50001`, Fulcrum `50002`. StartOS Fulcrum
listens on **in-subcontainer** `50001` (preferred external publish may be
`50002`).

```bash
# Ubuntu shut off with a retained Bitcoin overlay:
./bin/bvml index-bootstrap electrs
./bin/bvml resume ubuntu
./bin/bvml guest-index-provision ubuntu
./bin/bvml index-bootstrap-init electrs --confirm-index-format
./bin/bvml index-bootstrap-start electrs
# Repeat create/init/start for Fulcrum; after both synchronize:
./bin/bvml index-bootstrap-verify electrs
./bin/bvml stop ubuntu
./bin/bvml index-bootstrap-promote electrs --confirm-index-synced
# Consumer (after both bases exist):
./bin/bvml start ubuntu   # creates missing index overlays automatically
./bin/bvml index-adapter-setup ubuntu
./bin/bvml index-adapter-validate ubuntu
```

Formatting is bound to the bootstrap image, not merely `/dev/vdc`: libvirt
supplies an image-specific serial, and the guest requires its by-id device,
exact manifest size, host nonce, no child partitions or mounts, and no
filesystem/partition/RAID/LVM signatures before formatting.

An existing datadir is optional and has no default:

```bash
./bin/bvml checkpoint-import /consistent/snapshot/bitcoin --consistent-snapshot --assert-signet
```

Import rejects XOR block storage and requires an explicit stopped-node or
snapshot assertion.

UmbrelOS is a pinned, unattended target:

```bash
./bin/bvml credentials-init umbrel
./bin/bvml media-fetch umbrel
./bin/bvml create umbrel
./bin/bvml guest-provision umbrel
./bin/bvml start umbrel
./bin/bvml adapter-setup umbrel
./bin/bvml adapter-validate umbrel
./bin/bvml stop umbrel
./bin/bvml discard umbrel
```

The immutable profile pins umbrelOS 1.7.4 and official app
`bitcoin-knots` 1.2.12-patch.1, including installer, app-store commit,
package files, OCI images, bundled Knots executable, settings schema, and
production Compose contract. The installer is driven only after OCR prompt,
disk serial, model, and capacity checks. Onboarding uses the pinned public
`user.register` RPC and installs a dedicated SSH key without logging
credentials. `guest-provision` installs the official app through `umbreld`.
The adapter mounts the disposable overlay at Umbrel's normal
`app-data/bitcoin-knots/data/bitcoin`; the unchanged parent bind exposes it as
`/data/bitcoin`. App start, restart, and stop use `umbreld`; Docker is
inspection-only. Any version, package, mount, process, binary, RDTS, index,
sidecar, or tip-freshness mismatch fails closed and preserves the overlay.

StartOS has an automated, fail-closed consumer workflow:

```bash
./bin/bvml startos-adapter-build --confirm-convert
./bin/bvml startos-adapter-validate
./bin/bvml credentials-init startos
./bin/bvml media-fetch startos
./bin/bvml create startos
./bin/bvml guest-provision startos
./bin/bvml start startos
./bin/bvml adapter-setup startos
./bin/bvml adapter-validate startos
./bin/bvml stop startos
./bin/bvml discard startos
```

The profile pins StartOS 0.4.0.1 and official package
`bitcoind` `#knots:29.3.1:16`. The adapter preserves the native package, LXC,
SDK mounts, `bitcoind-sub`, and `start-cli` lifecycle. It dynamically resolves
the package `main` volume, bind-mounts only the disposable overlay over it, and
proves the same filesystem at `/media/startos/volumes/main` and
`/root/.bitcoin`. StartOS is not called operational until the opt-in real-host
stage passes. The pinned package also requires its datadir filesystem to
support Btrfs and `chattr +C`. A one-time immutable qcow2 filesystem-adapter
layer is created by running a full ext4 check and `btrfs-convert` against a
copy-on-write child of the canonical. StartOS overlays back this Btrfs layer;
Ubuntu and Umbrel overlays continue to back the ext4 canonical directly. The
conversion workflow rejects excessive allocation, removes the conversion
rollback subvolume only after validation, and never balances or recursively
defragments the adapter.

Neither appliance may promote a checkpoint. Ubuntu, Umbrel, and StartOS
consumer lifecycles may run concurrently, but each must use its own overlay.
Canonical mutation is blocked until all dependent overlays have been discarded.
The immutable StartOS adapter and its transitive children also count as
canonical dependencies, so replacing the canonical requires an explicit
adapter migration or removal workflow.

On storage-constrained hosts with `ROLLBACK_RETENTION=none`, an explicit update
uses `profiles-migrate`, `checkpoint-profile-migrate-guest`, clean Ubuntu
verification, and `checkpoint-commit --confirm-no-rollback`. This commits the
verified overlay into canonical in place and intentionally provides no local
rollback; disaster recovery is re-IBD. The StartOS Btrfs adapter must be removed
beforehand and rebuilt immediately from the new canonical generation.

See [the operations guide](docs/OPERATIONS.md), `./bin/bvml help`, and
`./bin/bvml test`.
