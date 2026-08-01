# bitcoin-vm-lab

`bitcoin-vm-lab` runs persistent Ubuntu, UmbrelOS, and StartOS guests
sequentially under Gentoo's system libvirt. The guests share one protected
Bitcoin mainnet checkpoint through exactly one disposable qcow2 overlay.

Generated storage defaults to `/var/lib/libvirt/images/bitcoin-vm-lab`, outside
the repository and the user's home directory:

```text
canonical/bitcoin-mainnet.qcow2          protected checkpoint
canonical/bitcoin-mainnet.rollback.qcow2 previous checkpoint, when available
active/bitcoin-mainnet-overlay.qcow2     the only disposable overlay
active/manifest.env                      retained overlay/checkpoint identity
run/owner.env                            live attachment owner
vms/{ubuntu,umbrel,startos}/             persistent system/application disks
```

The canonical image is never attached. `start` creates the single overlay,
attaches it to one exactly-shut-off domain, records ownership, and boots.
`stop` waits for exact `shut off`, detaches it, and retains it. No other guest
can start until the overlay is discarded or promoted.

Start here:

```bash
cp config/local.env.example config/local.env
sudo ./bin/bvml host-setup
./bin/bvml host-validate
./bin/bvml init
./bin/bvml create ubuntu
./bin/bvml checkpoint-import
./bin/bvml start ubuntu
```

The normal initial import reads the existing clean datadir at
`~/projects/bitcoin-knots-dev/bitcoin`; it does not perform IBD. It streams only
blocks, chainstate, indexes, and block-format metadata into an image sized from
actual data plus configured headroom. A live source lock or non-zero
`blocks/xor.dat` aborts the import.

Ubuntu uses pinned Bitcoin Knots with explicit, release-validated RDTS
arguments. UmbrelOS and StartOS use isolated release profiles that bind the
complete overlay datadir and pinned Knots binary into the packaged application.
An adapter is not considered configured until its exact package paths/version
are declared and its in-guest `verify` operation passes.

See [docs/OPERATIONS.md](docs/OPERATIONS.md) for the full import, guest setup,
testing, promotion, rollback, recovery, and backup procedures. Run
`./bin/bvml help` for the command list and `./bin/bvml test` for lifecycle tests.
