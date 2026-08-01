# Operations

## Initial setup and fresh checkpoint

1. Copy `config/local.env.example` to `config/local.env`.
2. Configure all three ISO paths and SHA-256 digests. Configure a pinned Knots
   archive, authenticated signed checksum metadata, signer fingerprint, actual
   artifact digest, normalized version, and an operator-approved RDTS profile
   name plus its digest. Configure a digest-pinned JSON checkpoint/index
   profile and maximum acceptable best-block age.
3. Run `host-setup`, `host-validate`, and `init`. Host setup installs only the
   needed Gentoo QEMU/libvirt, libguestfs, ACL, and selected EDK2/OVMF
   prerequisites and enables libvirtd.
4. Run `create ubuntu`. ISO verification is mandatory before VM creation.
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
9. Run `bootstrap-stop`, `bootstrap-verify`, and
   `bootstrap-promote --confirm-synced-clean`. Promotion accepts only evidence
   matching this bootstrap ID. It leaves the verified bootstrap unchanged,
   flattens a standalone candidate, removes transient evidence only from the
   candidate, validates and protects the installed canonical, and removes the
   bootstrap/evidence only after success. A failed install remains retryable
   without another IBD or evidence collection.

Use `bootstrap-status` through `bvml status`. An interrupted inactive bootstrap
can be removed with `bootstrap-cleanup`; attached or active state must be
cleanly stopped first.

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
configurable with `ROLLBACK_RETENTION`; an explicitly configured external
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

Back up canonical and rollback images only while every VM is shut off and no
Bitcoin disk is attached. Back up each persistent `vms/<name>` directory
separately. A retained rollback can be blockchain-sized; capacity planning must
include canonical, candidate, overlay growth, rollback, and persistent disks.
