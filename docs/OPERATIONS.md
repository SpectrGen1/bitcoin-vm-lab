# Operations

## Initial setup and fresh checkpoint

1. Copy `config/local.env.example` to `config/local.env`.
2. For unattended Ubuntu, set `UBUNTU_IMAGE_MODE=cloud`, an absolute media
   destination, an HTTPS cloud-image URL, its pinned SHA-256, the Ubuntu cloud
   user, and an absolute SSH public-key path. Configure UmbrelOS and StartOS
   ISO paths and SHA-256 digests separately. Configure a pinned Knots
   archive, authenticated signed checksum metadata, signer fingerprint, actual
   artifact digest, normalized version, and an operator-approved RDTS profile
   name plus its digest. Configure a digest-pinned JSON checkpoint/index
   profile and maximum acceptable best-block age.
3. Run `host-setup`, `host-validate`, and `storage-prepare`. Host setup installs only the
   needed Gentoo QEMU/libvirt, libguestfs, ACL, and selected EDK2/OVMF
   prerequisites and enables libvirtd. `storage-prepare` configures only the
   selected storage path, verifies system-QEMU traversal, and checks that free
   space can accommodate the configured bootstrap capacity.
4. Run `media-fetch ubuntu`, `profiles-install`, and `create ubuntu`.
   `media-fetch` refuses an unpinned artifact and always validates its digest,
   standalone qcow2 structure, image check, and read-only staging for both
   existing and downloaded files. Invalid files are quarantined and failed
   `.part` downloads are removed. `profiles-install` accepts signed metadata and a
   trusted signer key from absolute local paths or HTTPS, requires the exact
   configured `VALIDSIG`, binds the archive to its authenticated digest, and
   imports/fingerprints the key in a temporary keyring, and atomically switches
   a complete root-owned `/etc/bvml/active` profile generation. `create ubuntu` performs offline
   cloud-image customization with the direct libguestfs appliance, injects the
   SSH public key, QEMU guest agent, guest bootstrap script, signed metadata,
   RDTS profile, checkpoint profile, and fail-closed mount configuration. It
   verifies the standalone output disk and required guest files, explicitly
   adds the QGA Virtio channel, validates its XML, and defines `bvml-ubuntu`
   without booting it. Package installation through
   `virt-customize --network --install` remains online and is not fully
   reproducible unless package snapshots and versions are pinned.
5. Run `checkpoint-bootstrap`. This creates an empty qcow2, marks it
   `fresh-ibd-incomplete`, attaches it exclusively to Ubuntu, records ownership,
   and boots Ubuntu. It does not format the disk.
6. Use the schemas under `templates/knots/`. Install the guest script at
   `/usr/local/libexec/bvml/ubuntu-knots-rdts.sh`, configure the root-owned,
   non-group-writable `/etc/bvml/knots.env`, and run
   `bootstrap-init --confirm-bootstrap-format`. The host stages the bootstrap
   ID, libvirt serial, byte size, and nonce. The guest requires the matching
   `/dev/disk/by-id/virtio-*` device, exact size, no children or mounts, and no
   filesystem, partition-table, RAID, LVM, or other signatures before
   formatting and recording its UUID.
7. Run the guest script's `install`, then `start`. Authenticated checksums,
   signer fingerprint, pinned archive digest, installed binary identity/version,
   and the digest-pinned release-specific RDTS profile are checked. Supported
   options are checked before start; effectiveness is proven afterward from the
   actual `bitcoind` process command line, with missing, changed, conflicting,
   or duplicated profiled values rejected. The service
   has `RequiresMountsFor`, `ConditionPathIsMountPoint`, and a UUID check. It
   cannot fall back to `/srv/bitcoin` on the OS disk.
8. Complete mainnet IBD. Run guest `verify-shutdown`. It captures actual Knots
   normalized version/digest, chain, heights, best hash, best-block and median
   times, calculated tip age, IBD state, structured required-index state,
   observed RDTS arguments/profile digest, filesystem UUID, and a new shutdown
   event, then stops Knots cleanly.
9. Set `ROLLBACK_RETENTION=none`, then run `bootstrap-stop`, `bootstrap-verify`, and
   `bootstrap-promote --confirm-synced-clean`. Promotion accepts only evidence
   matching this bootstrap ID and exact host/guest profile generation. First
   promotion saves a small recovery bundle, flushes metadata, removes transient
   in-image evidence, computes the full image SHA-256, and atomically renames
   the already-standalone bootstrap on the same filesystem. It never copies or
   converts the blockchain. A protection/validation failure renames it back and
   restores the saved evidence.

Use `bootstrap-status` through `bvml status`. An interrupted inactive bootstrap
can be removed with `bootstrap-cleanup`; attached or active state must be
cleanly stopped first.

### Provisioning safety and recovery

Provisioning commands hold the lifecycle lock. Profile mutation is refused
while any bootstrap, canonical, overlay, verification, or recovery state
exists. `guest-repair ubuntu --scripts-only` is the narrow repair path: it
proves all installed profile digests and changes lifecycle code only. Failed
downloads remove `.part` files; invalid media is quarantined. A failed
cloud conversion/customization or domain definition retains the persistent VM
disks for inspection and never creates or attaches Bitcoin storage. After
inspection, `create-cleanup VM --confirm-remove-partial` removes only known
disks for an undefined VM.

`guest-provision ubuntu` is for repairing an already-created Ubuntu guest. It
requires Ubuntu to be exactly `running`, UmbrelOS and StartOS to be exactly
`shut off`, and no owner or Bitcoin attachment. It uses synchronous QEMU
guest-agent execution, installs the same verified assets, and reports the
guest command's real exit status. It is intentionally unavailable once
`checkpoint-bootstrap` or an overlay lifecycle has begun.

## Optional compatible import

There is no source default and normal validation has no source dependency:

```bash
./bin/bvml checkpoint-import /snapshot/bitcoin --consistent-snapshot --assert-mainnet
# or, only after proving a clean stop and absence of a stale .lock:
./bin/bvml checkpoint-import /data/bitcoin --assert-source-stopped --assert-mainnet
```

Import requires `blocks/` and `chainstate/`; `indexes/` is optional unless the
configured checkpoint index profile requires it. It rejects nonzero
`blocks/xor.dat`. `blocksxor=0` never converts already encoded block files.
Selected paths are measured first, absolute bytes plus configured headroom are
passed to `virt-make-fs`, ownership/permissions are normalized, and the
candidate is validated before canonical state changes.

## Normal sequential testing

```bash
./bin/bvml start umbrel
./bin/bvml adapter-status umbrel
# test the real packaged application
./bin/bvml stop umbrel
./bin/bvml discard umbrel
```

The normal `start umbrel`/`start startos` path requires previously recorded
successful guest adapter metadata. For the first exact-package integration,
use the explicit `start VM --adapter-setup` mode, immediately run
`adapter-setup VM` and `adapter-validate VM`, then stop/discard. This exception
is visible and exists only to bootstrap the persistent platform adapter; it
does not mark the adapter ready by itself.

`start` requires every domain to be exactly `shut off`, no owner, no retained
overlay, and a protected canonical. Its fast canonical preflight checks
ID/generation/profile, qcow2 and standalone state, `qemu-img`, datadir layout,
non-XOR metadata, mode, immutability, system-QEMU access, process references,
and direct attachments. It creates a unique overlay ID, invalidates old
evidence, validates both canonical ID and generation, attaches with a serial,
writes ownership, and starts. Bootstrap and ordinary startup share the same
reverse-order transaction. Failed attachment identity, owner write, or VM
start is rolled back; no image is deleted while XML or a process references it.

`stop` calls the platform clean-application hook through a synchronous QEMU
guest-agent runner that waits for completion, decodes output, propagates
stderr/nonzero status, and distinguishes transport failures. An absent,
never-started, or already-stopped application is success; an installed
application that fails to stop blocks detachment. It then requests guest
shutdown, waits for exact `shut off`, detaches with `--config`, confirms the
attachment and process reference are gone, clears active ownership, and retains
the overlay. Every other libvirt state—including paused, blocked, in shutdown,
pmsuspended, crashed, unknown, or unavailable—is unsafe.

`discard` deletes only a detached disposable overlay and its current evidence.
`reset VM` performs the complete stop when active and then discards. A retained
overlay must be discarded or promoted before another VM starts. `reconcile`
clears stale ordinary-overlay or bootstrap ownership only after all guests are
exactly shut off, the owner-kind image is detached and unopened, its manifest
identity agrees, and no conflicting Bitcoin state exists.

## Ubuntu update verification and promotion

For a checkpoint update, start Ubuntu, run guest `start`, synchronize, then run
guest `verify-shutdown`, host `stop ubuntu`, and `checkpoint-verify`. The host
binds extracted evidence to the current overlay ID and checkpoint generation.
Evidence is invalidated on overlay creation/start/ownership changes and removed
from flattened candidates.

```bash
./bin/bvml checkpoint-promote --confirm-synced-clean
```

Promotion requires all domains exactly shut off, no attachment, no owner,
exactly one Ubuntu overlay, a valid backing chain, current evidence, matching
normalized Knots/RDTS profile digest and observed arguments,
mainnet/non-XOR/filesystem/index-profile state, a fresh best-block timestamp,
and clean shutdown. It reports
candidate and rollback space, flattens and validates a standalone candidate,
then rotates on the canonical filesystem. Any post-install failure
automatically restores and reprotects the previous canonical. The overlay is
removed only after success.

A full rollback consumes nearly another checkpoint allocation. Retention is
disabled by default with `ROLLBACK_RETENTION=none`; status reports
`rollback: disabled by storage policy` and `disaster recovery: re-IBD`.
An explicitly configured external
destination must have adequate space. Remove an obsolete rollback only with:

```bash
./bin/bvml rollback-remove --confirm-remove
```

`checkpoint-rollback` independently validates the rollback before swapping. If
the installed rollback fails validation, the swap is automatically reversed,
the known-good canonical is reprotected, and recovery metadata is written.

## UmbrelOS and StartOS

Populate the exact templates under `templates/` only after inspecting a
specific OS and Bitcoin package release. Install profiles root-owned and
non-group/world-writable with SHA-256 sidecars. Umbrel also requires a
digest-pinned versioned transformation script. It must verify the stock image,
entrypoint, command, environment, mounts, runtime user, health, and endpoints;
preserve the package integration behavior; then inject the read-only Knots
release and complete overlay datadir. StartOS requires a digest-pinned versioned
package implementation with fixed `apply`, `build`, `install`,
interface/health, and competing-datadir verification actions. Profiles cannot
supply arbitrary build/install command strings.

Both adapters locate the actual executable-backed Knots PID inside the managed
container (PID 1 is not assumed), read that PID's command line inside the
container, and verify binary digest, runtime user, mainnet, `blocksxor=0`,
datadir, and exact RDTS values. After synchronous validation, the host records
OS/package versions, profile and binary digests, adapter implementation
version, result, and timestamp. `adapter-status` and full validation use this
guest-derived metadata.

Missing or mismatched versions fail closed. Host-level guessed bind mounts are
not accepted. These integrations are not operational until populated profiles
and the actual package/container `verify` commands pass.

## Opt-in real-host integration tests

The default suite is mocked. Real-host stages are individually gated:

```bash
sudo touch /dedicated/lab/path/.bvml-dedicated-integration-lab
BVML_INTEGRATION=1 \
BVML_INTEGRATION_STORAGE=/dedicated/lab/path \
./bin/bvml integration-test preflight
```

Available stages are `cloud`, `bootstrap-finalize`, `ubuntu-smoke`, `umbrel`,
and `startos`. Bootstrap finalization additionally requires
`BVML_CONFIRM_DESTRUCTIVE_INTEGRATION=1`. The suite refuses unmarked storage,
checks canonical immutability/fingerprints around disposable adapter tests, and
is never part of `bvml test`.

## Protection, recovery, space, and backups

Canonical protection is applied in this order: ownership/group, mode, ACL,
system-QEMU traversal/read test, immutable bit, immutable verification.
Controlled rotation explicitly removes immutability and restores every
protection before success.

After interrupted startup, failed detach, stale owner state, promotion,
bootstrap, or rollback, run `status` then `validate`. Status reports actual
image-to-domain pairs and uses the same lifecycle invariants as destructive
commands. Do not delete metadata manually.
Active/attached failures intentionally retain images and ownership. Automatic
promotion/rollback recovery is recorded under `run/recovery.env`. If space is
insufficient, stop before conversion, free unrelated space or configure
rollback retention/destination, then retry.

Inspect any recovery record before continuing. For a recognized automatic
restore/reverse or preserved-bootstrap result, use
`recovery-ack --confirm-reviewed`. It removes only failed transient candidates
and the recovery marker while preserving the known-good canonical, rollback,
retained overlay, or verified bootstrap. Unrecognized recovery states remain
fail-closed for forensic repair.

The low-space promotion recovery bundle is evidence, not a cold backup. It
protects against lifecycle mistakes, not physical disk failure or unrecoverable
qcow2 corruption; without an external backup, recovery is a new IBD.
Back up canonical and rollback images only while every VM is shut off and no
Bitcoin disk is attached. Back up each persistent `vms/<name>` directory
separately. A retained rollback can be blockchain-sized; capacity planning must
include canonical, candidate, overlay growth, rollback, and persistent disks.
