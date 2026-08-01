# Operations

## Initial setup and fresh checkpoint

1. Copy `config/local.env.example` to `config/local.env`.
2. Configure all three ISO paths and SHA-256 digests. Configure a pinned Knots
   archive, authenticated signed checksum metadata, signer fingerprint, actual
   artifact digest, and an operator-approved RDTS profile plus its digest.
3. Run `host-setup`, `host-validate`, and `init`. Host setup installs only the
   needed Gentoo QEMU/libvirt, libguestfs, ACL, and selected EDK2/OVMF
   prerequisites and enables libvirtd.
4. Run `create ubuntu`. ISO verification is mandatory before VM creation.
5. Run `checkpoint-bootstrap`. This creates an empty qcow2, marks it
   `fresh-ibd-incomplete`, attaches it exclusively to Ubuntu, records ownership,
   and boots Ubuntu. It does not format the disk.
6. Install the guest script at
   `/usr/local/libexec/bvml/ubuntu-knots-rdts.sh`, configure `/etc/bvml/knots.env`,
   and run `bootstrap-init --confirm-device-vdc`. The guest independently
   verifies `/dev/vdc` is an empty whole disk before formatting it and records
   its filesystem UUID.
7. Run the guest script's `install`, then `start`. Authenticated checksums,
   signer fingerprint, pinned archive digest, installed binary identity/version,
   and the digest-pinned release-specific RDTS profile are checked. The service
   has `RequiresMountsFor`, `ConditionPathIsMountPoint`, and a UUID check. It
   cannot fall back to `/srv/bitcoin` on the OS disk.
8. Complete mainnet IBD. Run guest `verify-shutdown`. It captures actual Knots
   version/digest, chain, heights, best hash, tip time, IBD state, indexes and
   per-index sync, effective RDTS profile/arguments, filesystem UUID, and a new
   shutdown event, then stops Knots cleanly.
9. Run `bootstrap-stop`, `bootstrap-verify`, and
   `bootstrap-promote --confirm-synced-clean`. Promotion accepts only evidence
   matching this bootstrap ID, validates a standalone non-XOR mainnet datadir,
   removes transient evidence, installs the first canonical, and protects it.

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

`start` requires every domain to be exactly `shut off`, no owner, no retained
overlay, and a protected canonical. It creates a unique overlay ID, invalidates
old evidence, validates the backing generation, attaches, writes ownership,
and starts. Failed attach, owner write, or VM start is rolled back in reverse
order; no image is deleted while domain XML references it.

`stop` calls the platform clean-application hook through the QEMU guest agent,
requests guest shutdown, waits for exact `shut off`, detaches with `--config`,
confirms the attachment and process reference are gone, clears active ownership,
and retains the overlay. Every other libvirt state—including paused, blocked,
in shutdown, pmsuspended, crashed, unknown, or unavailable—is unsafe.

`discard` deletes only a detached disposable overlay and its current evidence.
`reset VM` performs the complete stop when active and then discards. A retained
overlay must be discarded or promoted before another VM starts. `reconcile`
clears stale owner metadata only after all guests are exactly shut off, no
attachment/process reference exists, and the manifest agrees.

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
Knots/RDTS/mainnet/non-XOR/filesystem/index state, and clean shutdown. It reports
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
specific OS and Bitcoin package release. The Umbrel adapter generates a Compose
override for the actual Bitcoin service, recreates its container, mounts the
complete overlay datadir, mounts the pinned Knots release read-only, and proves
the live container command, mounts, and binary digest. The StartOS adapter
requires versioned package source containing `bvml/apply-package-override`,
builds/installs that package, and proves the managed container's datadir,
read-only Knots mount, arguments, and digest.

Missing or mismatched versions fail closed. Host-level guessed bind mounts are
not accepted. These integrations are not operational until populated profiles
and the actual package/container `verify` commands pass.

## Protection, recovery, space, and backups

Canonical protection is applied in this order: ownership/group, mode, ACL,
system-QEMU traversal/read test, immutable bit, immutable verification.
Controlled rotation explicitly removes immutability and restores every
protection before success.

After interrupted startup, failed detach, stale owner state, promotion, or
rollback, run `status` then `validate`. Do not delete metadata manually.
Active/attached failures intentionally retain images and ownership. Automatic
promotion/rollback recovery is recorded under `run/recovery.env`. If space is
insufficient, stop before conversion, free unrelated space or configure
rollback retention/destination, then retry.

Back up canonical and rollback images only while every VM is shut off and no
Bitcoin disk is attached. Back up each persistent `vms/<name>` directory
separately. A retained rollback can be blockchain-sized; capacity planning must
include canonical, candidate, overlay growth, rollback, and persistent disks.
