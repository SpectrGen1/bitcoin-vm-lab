# Guidance for agents

## Purpose and architecture

- This repository manages a bare-metal Gentoo KVM/libvirt lab for Bitcoin Knots.
- Three persistent VM environments are supported: Ubuntu, UmbrelOS, and StartOS.
- Multiple VMs may run concurrently within configured CPU, memory, and storage limits.
- Each VM keeps its OS and application state on its own persistent system disk.
- Reusable mainnet state lives in one protected, standalone canonical qcow2 checkpoint.
- StartOS uses one protected Btrfs qcow2 adapter backed by the ext4 canonical.
- Every active VM receives its own disposable writable qcow2 overlay.
- Each overlay has exactly one owning VM and may be attached to only that domain.
- The immutable canonical checkpoint may back several overlays simultaneously.
- The canonical image is never attached directly to a guest during normal operation.
- Generated images, manifests, owner records, evidence, and recovery state live outside Git.
- See [README.md](README.md) and [docs/OPERATIONS.md](docs/OPERATIONS.md) for operator procedures.

## Producer and consumer roles

- Ubuntu supports both checkpoint-producer and checkpoint-consumer workflows.
- Fresh IBD, compatible import, checkpoint update, verification, and promotion use Ubuntu.
- In consumer mode, Ubuntu exercises the canonical through a fresh disposable overlay, then stops cleanly and discards it.
- Consumer-mode Ubuntu runs must enter the full producer verification workflow before promotion.
- Producer evidence proves Knots, mainnet, `blocksxor=0`, RDTS, indexes, tip freshness, filesystem and overlay identity, and clean shutdown.
- The shared checkpoint profile requires the basic block filter index and `txindex`
  on every platform.
- UmbrelOS and StartOS are checkpoint consumers only.
- Index consumers: Ubuntu and Umbrel run Electrs and Fulcrum; StartOS runs both
  the official Fulcrum package and the community Electrs package on index overlays.
- Never promote, flatten, or otherwise commit an UmbrelOS or StartOS overlay.
- Consumer overlays are independently stopped cleanly and discarded.
- Call a platform operational only after a real service advances on its overlay, shuts down cleanly, and leaves canonical unchanged.

## Production fidelity

- Ubuntu must use the pinned and authenticated Bitcoin Knots release and RDTS profile.
- Its service must fail closed unless the expected Bitcoin filesystem is mounted.
- Ubuntu consumer validation must prove its overlay—not canonical or the OS disk—is the complete Knots datadir.
- It must open existing chainstate without unintended IBD or reindex, use approved arguments, advance, and leave canonical unchanged.
- Umbrel must use the official pinned `bitcoin-knots` app through `umbreld`.
- Preserve Umbrel's image, Compose topology, entrypoint, settings, sidecars, ports, RPC, ZMQ, runtime user, restart policy, and native lifecycle.
- Use Docker inspection only for runtime proof; do not make Docker Compose the controller.
- StartOS must use the pinned official `bitcoind` package, native LXC/SDK mounts,
  subcontainer, and `start-cli` lifecycle without package or binary substitution.
- StartOS overlays must back the immutable Btrfs adapter; never mount the ext4
  canonical view as its native package volume.
- StartOS remains unproven when its exact profile or real-host lifecycle cannot be proved.
- Verify the actual running Knots process, executable digest, arguments, datadir, mounts,
  user, and platform endpoints; configured intent is not runtime evidence.
- Preserve all fail-closed OS, package, profile, artifact, and image digest checks.

## Storage and lifecycle safety

- Use `bin/bvml` and existing functions in `lib/common.sh` and `scripts/vm/manage.sh`.
- Use the short global lock for canonical mutations and atomic shared-state changes.
- Use the selected VM's lifecycle lock for attach, start, stop, adapter, and recovery work.
- Never hold the global lock while a guest synchronizes, runs tests, or shuts down.
- Reuse transactional attachment, ownership, invariant, QGA/SSH, and recovery helpers.
- Treat only the exact libvirt state `shut off` as inactive; every other state is unsafe.
- Before detach, discard, promotion, rollback, formatting, or deletion, inspect domain
  state, persistent XML attachments, active processes, mounts, owner data, and manifests.
- Owner metadata is not authoritative by itself; it must agree with observed state.
- Never delete an image while domain XML or a process still references it.
- Never force-unmount a busy Bitcoin filesystem or detach an in-use disk.
- Never attach canonical or rollback images directly to any VM.
- Never attach the StartOS Btrfs adapter writable or use balance/recursive
  defragmentation on it.
- The canonical image must remain immutable and must never be attached writable.
- Never format a disk based only on `/dev/vdc` or the absence of a filesystem.
- Destructive initialization requires explicit confirmation plus serial, by-id path,
  nonce, size, partition, signature, mount, filesystem UUID, and manifest checks.
- Keep canonical ownership, ACL, mode, QEMU readability, and immutability protections.
- Remove protection only inside a controlled rotation, then restore and verify it.
- Ordinary overlays must match both canonical ID and checkpoint generation.
- Shared canonical replacement, promotion, protection changes, and in-place commit are
  blocked while any direct overlay, StartOS adapter, or transitive overlay exists.
- After any canonical generation change, rebuild the dependent StartOS Btrfs adapter
  before permitting another StartOS consumer lifecycle.
- Promotion is permitted only from current, clean, overlay-specific Ubuntu evidence.
- Validate standalone candidates before atomic installation of canonical state.
- Preserve the known-good image and recovery metadata until post-install validation passes.
- Discard removes only the disposable overlay and its evidence, never persistent VM disks.
- On partial failure, roll back in reverse order where safe; otherwise preserve the image,
  diagnostics, manifests, attachments, logs, and explicit recovery-required state.
- Reconciliation and recovery must affect only the selected VM lifecycle.
- Avoid manual or out-of-band `virsh`, mount, qemu-img, container, or disk operations.
- If recovery requires an exceptional manual action, diagnose and encode it in the
  lifecycle workflow rather than leaving an undocumented operator procedure.
- Never commit runtime images, credentials, guest evidence, or generated recovery data.

## Repository map

- `bin/bvml`: stable operator entry point and command discovery.
- `lib/common.sh`: configuration, paths, validation, locking, and shared invariants.
- `scripts/vm/manage.sh`: transactional VM/storage lifecycle and reconciliation.
- `scripts/vm/indexes.sh` and `lib/index-lifecycle.sh`: protected Electrs/Fulcrum bases and per-VM index overlays.
- `scripts/vm/status.sh` and `scripts/vm/validate.sh`: observed state and safety checks.
- `scripts/vm/create*.sh`: persistent VM definition and cleanup workflows.
- `scripts/vm/guest/`: platform adapters and synchronous guest-side operations.
- `scripts/provision.sh`: pinned media, profile, and guest provisioning workflows.
- `scripts/host/`: minimal, visible, idempotent Gentoo/libvirt host preparation.
- `config/` and `profiles/`: templates plus pinned, versioned, digest-bound inputs.
- `tests/`: mocked lifecycle regression suite.
- `tests/integration/`: opt-in destructive tests for a dedicated real-host lab.
- `docs/OPERATIONS.md`: detailed setup, lifecycle, recovery, and maintenance runbook.

## Coding conventions

- Write Bash with `#!/usr/bin/env bash` and `set -Eeuo pipefail`.
- Source shared helpers instead of duplicating locks, path logic, or state assertions.
- Use `die`, `note`, `need`, and `virshq` consistently with existing scripts.
- Quote variables, validate absolute paths and structured inputs, and reject control data.
- Prefer data formats parsed with `jq` over executable profile text.
- Keep version-specific behavior isolated in profiles and platform adapters.
- Make state changes transactional, idempotent where practical, and safe on interruption.
- Emit actionable errors without hiding the original failure or destroying diagnostics.

## Tests and validation

- Run mocked regressions with `./bin/bvml test` (or `./tests/run.sh`).
- Run host checks with `./bin/bvml host-validate`.
- Run lifecycle validation with `./bin/bvml validate` and inspect `./bin/bvml status`.
- Real-host tests use `./bin/bvml integration-test <step>` and require the explicit
  integration opt-in plus a marked, dedicated lab storage path.
- Never run destructive integration steps against unconfirmed storage.
- Any lifecycle change requires regression tests for success, rollback, and partial failure.
- Tests must assert actual state transitions, attachments, files, and protections.
- Mocked tests do not establish production platform fidelity.

## Final report

- Summarize changed behavior and identify the main files changed.
- List the exact tests and validations run, with pass, fail, or not-run status.
- State whether a real platform workflow ran; never imply it from mocked coverage.
- Report the final VM, owner, attachment, overlay, canonical, and recovery state when
  lifecycle or storage was touched.
- Call out remaining unsupported profiles, operational gaps, or recovery actions plainly.
