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
./bin/bvml bootstrap-init --confirm-device-vdc
```

The bootstrap disk remains explicitly marked incomplete until authenticated
Knots, the operator-approved release-specific RDTS profile, mainnet sync,
indexes, filesystem identity, and clean shutdown evidence all validate.
`blocksxor=0` is written before the first Knots start. The Ubuntu systemd unit
requires the expected mounted filesystem and fails closed if the disk or UUID
is wrong.

An existing datadir is optional and has no default:

```bash
./bin/bvml checkpoint-import /consistent/snapshot/bitcoin --consistent-snapshot --assert-mainnet
```

Import rejects XOR block storage and requires an explicit stopped-node or
snapshot assertion. Umbrel and StartOS adapters are exact-version package
integrations: Umbrel recreates the actual app container with the overlay and a
read-only Knots release; StartOS builds an exact package override. Neither is
reported ready until its actual managed container passes verification.

See [the operations guide](docs/OPERATIONS.md), `./bin/bvml help`, and
`./bin/bvml test`.
