# Operations

## Host and persistent guests

Copy `config/local.env.example` to `config/local.env`. Supply absolute ISO
paths and SHA-256 values, a pinned Knots release (or binary), authenticated
release metadata, and the exact RDTS arguments documented for that release.
The scripts deliberately do not guess an RDTS option.

`sudo ./bin/bvml host-setup` shows and installs the small project USE file,
QEMU/libvirt, libguestfs, ACL tools, and EDK2/OVMF. It enables and starts only
`libvirtd`. Run `host-validate`, then `init`. The latter creates configurable
storage under `/var/lib/libvirt/images` and grants the system QEMU account only
the traversal/read/write ACLs required for each image role.

Create each VM once with `create ubuntu`, `create umbrel`, and `create startos`.
ISO checksums are mandatory. System and application disks persist independently
of the disposable Bitcoin overlay.

## Initial checkpoint import

The default source is:

```text
~/projects/bitcoin-knots-dev/bitcoin
```

That path must be a cleanly stopped mainnet datadir. The importer tests its lock.
Alternatively, point `--source` at a consistent filesystem snapshot and pass
`--snapshot`:

```bash
./bin/bvml checkpoint-import
./bin/bvml checkpoint-import --source /snapshot/bitcoin --snapshot
```

The import includes `blocks/`, `chainstate/`, and `indexes/` when present.
Wallets, cookies, PID/lock files, logs, peer/ban/anchor state, mempool state,
settings, and the source configuration are excluded because they are transient,
private, or machine-specific.

Bitcoin block XOR is a storage format, not a configuration preference. A
non-zero `blocks/xor.dat` means existing block files are encoded. Merely adding
`blocksxor=0` does not convert them, so import stops. Migrate deliberately by
running the source format with its compatible Knots release and rebuilding or
reindexing into a separate non-XOR datadir; cleanly stop it, verify its XOR key
is absent/zero, then import that new datadir.

The importer streams the selected state through libguestfs into an ext4 qcow2
with percentage headroom, checks the image and required directories, installs
it on the same filesystem, and applies read-only plus immutable protection.

## Ubuntu Knots with RDTS

Copy `scripts/vm/guest/ubuntu-knots-rdts.sh` and a populated
`/etc/bvml/knots.env` into Ubuntu. The script accepts either an explicitly
configured Knots binary or an archive whose checksum list and detached
signature are verified against a pinned signer fingerprint. It checks that the
binary identifies as Knots and that every configured RDTS option appears in
that release's debug help.

After `./bin/bvml start ubuntu`, run:

```bash
sudo /path/to/ubuntu-knots-rdts.sh install
sudo /path/to/ubuntu-knots-rdts.sh start
```

The attached filesystem is mounted at `/srv/bitcoin` as the complete datadir.
The otherwise stock configuration contains only:

```ini
datadir=/srv/bitcoin
blocksxor=0
```

RDTS remains an explicit service command-line argument because it is
release-specific. Knots reuses the imported state and synchronizes any remaining
blocks. If IBD is ever necessary, this same Knots/RDTS service performs it.

When synchronized:

```bash
sudo /path/to/ubuntu-knots-rdts.sh verify-shutdown
sudo shutdown -h now
./bin/bvml stop ubuntu
./bin/bvml checkpoint-verify
```

The guest command verifies mainnet, IBD status, verification progress, indexes,
RDTS option support, and a clean Knots stop. The host extracts that evidence
from the stopped overlay; it is not accepted while the image is attached.

## UmbrelOS and StartOS adapters

These integrations are version-gated rather than pretending all releases use
the same package layout. Install the corresponding script, shared adapter
library, a pinned Knots binary, and an exact profile based on
`templates/{umbrel,startos}/profile.env.example` inside the guest.

The profile declares the detected/supported platform version, application
service, host-visible packaged datadir, packaged `bitcoind` path, and Knots
binary. `install` stops the application, persistently mounts `/dev/vdc`, bind
mounts the entire overlay over the package's actual datadir, bind mounts Knots
over its node binary, and adds a systemd mount prerequisite. This prevents a
second chain from being initialized while leaving package configuration and
other application state on the persistent application disk.

Run inside the guest:

```bash
sudo umbrel-adapter.sh install
sudo umbrel-adapter.sh verify
# before host stop:
sudo umbrel-adapter.sh stop
```

Use the equivalent `startos-adapter.sh` commands. `verify` compares actual mount
sources and binaries; a missing profile, release mismatch, competing datadir,
or non-Knots binary fails. `./bin/bvml adapter-status` reports which host-side
release declarations remain unconfigured.

## Normal sequential tests

```bash
./bin/bvml start umbrel
# run adapter verification and tests; cleanly stop packaged Bitcoin in guest
./bin/bvml stop umbrel
./bin/bvml discard umbrel
```

`stop` treats every state except exact `shut off` as active. It requests ACPI
shutdown, waits, detaches the disk with a configuration-only libvirt operation,
then removes runtime ownership. The retained overlay blocks all starts.
`discard` requires all guests shut off and no attachments. `reset VM` performs
the stop when needed and then discards. Persistent system/application disks and
the canonical image are untouched.

## Promotion and rollback

Only a stopped, detached Ubuntu overlay with imported Knots/RDTS verification
can be promoted:

```bash
./bin/bvml validate
./bin/bvml checkpoint-promote --confirm-synced-clean
./bin/bvml validate
```

Promotion checks all three domains for exact `shut off`, all block attachments,
owner consistency, overlay checkpoint identity/backing chain, qcow2 integrity,
guest evidence, required datadir directories, and XOR metadata. It flattens the
complete overlay view into a standalone candidate on the canonical filesystem
and validates it before touching the current checkpoint. The current checkpoint
becomes the protected rollback image, the candidate is atomically installed and
protected, and only then is the overlay removed.

To exchange the current and rollback checkpoints:

```bash
./bin/bvml checkpoint-rollback
```

Rollback refuses overlays, owners, attachments, or non-shut-off domains and
keeps both generations. Back up both images before a risky maintenance event.

## Interrupted-operation recovery and maintenance

Run `status`, then `validate`. Never manually delete an owner record first.
Validation compares owner metadata to actual domain state and actual block
devices, detects direct canonical attachment, multiple attachments, stale
ownership, extra overlays, old checkpoint identities, inaccessible storage,
missing UEFI, missing Knots/RDTS configuration, and absent adapters.

If startup failed while the domain remained active, the script intentionally
retains attachment and ownership. Cleanly stop that domain with `stop`. If a
crash left inconsistent metadata, preserve the images, collect `virsh
domblklist --details` and `qemu-img info --backing-chain`, and repair only after
proving all domains are exactly shut off. Normal failures roll back
automatically and should not require owner-file editing.

Back up canonical and rollback images only while no guest is attached. Back up
each `vms/<name>` directory separately for persistent OS/application recovery.
Run `validate` before and after checkpoint maintenance and `test` after script
changes.
