# bitcoin-vm-lab

`bitcoin-vm-lab` manages persistent Ubuntu, UmbrelOS, and StartOS guests
sequentially under Gentoo system libvirt. One protected Bitcoin mainnet
checkpoint backs exactly one disposable qcow2 overlay. The canonical image is
never attached directly.

Runtime storage defaults to `/var/lib/libvirt/images/bitcoin-vm-lab`, outside
the repository:

```text
canonical/bitcoin-mainnet.qcow2          protected checkpoint
canonical/bitcoin-mainnet.rollback.qcow2 optional full-size rollback (disabled by default)
active/bitcoin-mainnet-bootstrap.qcow2   incomplete first-IBD image, when used
active/bitcoin-mainnet-overlay.qcow2     only disposable test/update overlay
run/owner.env                            active attachment transaction
vms/{ubuntu,umbrel,startos}/             persistent OS/application disks
```

Fresh Bitcoin Knots mainnet IBD is the normal initialization path:

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
mainnet sync, required indexes, best-block freshness, filesystem identity, and
clean shutdown evidence all validate.
`blocksxor=0` is written before the first Knots start. The Ubuntu systemd unit
requires the expected mounted filesystem and fails closed if the disk or UUID
is wrong.

Formatting is bound to the bootstrap image, not merely `/dev/vdc`: libvirt
supplies an image-specific serial, and the guest requires its by-id device,
exact manifest size, host nonce, no child partitions or mounts, and no
filesystem/partition/RAID/LVM signatures before formatting.

An existing datadir is optional and has no default:

```bash
./bin/bvml checkpoint-import /consistent/snapshot/bitcoin --consistent-snapshot --assert-mainnet
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

StartOS remains version-gated and unavailable until its package profile is
implemented and verified. Neither platform may promote a checkpoint.

See [the operations guide](docs/OPERATIONS.md), `./bin/bvml help`, and
`./bin/bvml test`.
