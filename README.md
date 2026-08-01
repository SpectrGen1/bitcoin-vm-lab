# bitcoin-vm-lab

`bitcoin-vm-lab` manages persistent Ubuntu, UmbrelOS, and StartOS guests
sequentially under Gentoo system libvirt. One protected Bitcoin mainnet
checkpoint backs exactly one disposable qcow2 overlay. The canonical image is
never attached directly.

Runtime storage defaults to `/var/lib/libvirt/images/bitcoin-vm-lab`, outside
the repository:

```text
canonical/bitcoin-mainnet.qcow2          protected checkpoint
canonical/bitcoin-mainnet.rollback.qcow2 optional full-size rollback
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
./bin/bvml init
./bin/bvml create ubuntu
./bin/bvml checkpoint-bootstrap
./bin/bvml bootstrap-init --confirm-bootstrap-format
```

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
snapshot assertion. Umbrel and StartOS adapters require exact-version,
digest-pinned implementation scripts that preserve package entrypoints,
health/dependency interfaces, and integration behavior. Both locate and inspect
the actual in-container Knots process rather than assuming PID 1. Neither is
reported ready until its managed package passes verification and the host
records that guest profile metadata.

See [the operations guide](docs/OPERATIONS.md), `./bin/bvml help`, and
`./bin/bvml test`.
