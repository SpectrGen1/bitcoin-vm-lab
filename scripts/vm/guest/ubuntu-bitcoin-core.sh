#!/usr/bin/env bash
# Run inside the Ubuntu guest after `bin/bvml start ubuntu`.
# It initializes /dev/vdc only when it has no filesystem; existing checkpoints
# are mounted unchanged. The only bitcoin.conf options are portability options.
set -Eeuo pipefail
DEVICE="${BITCOIN_DEVICE:-/dev/vdc}"
MOUNT="${BITCOIN_MOUNT:-/srv/bitcoin}"
VERSION="${BITCOIN_VERSION:?set a pinned BITCOIN_VERSION, e.g. 29.0}"
ARCH="x86_64-linux-gnu"
[[ -b "$DEVICE" ]] || { echo "Bitcoin overlay disk not found: $DEVICE" >&2; exit 1; }
if ! blkid "$DEVICE" >/dev/null 2>&1; then
  sudo mkfs.ext4 -F -L bitcoin-mainnet "$DEVICE"
fi
uuid="$(blkid -s UUID -o value "$DEVICE")"
sudo install -d -m 0755 "$MOUNT"
grep -q "UUID=$uuid" /etc/fstab || echo "UUID=$uuid $MOUNT ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
sudo mount "$MOUNT" || true
sudo install -d -o "$USER" -g "$USER" -m 0750 "$MOUNT/data"

cd /tmp
base="bitcoin-${VERSION}-${ARCH}"
curl -fLO "https://bitcoincore.org/bin/bitcoin-core-${VERSION}/${base}.tar.gz"
curl -fLO "https://bitcoincore.org/bin/bitcoin-core-${VERSION}/SHA256SUMS"
grep " ${base}.tar.gz$" SHA256SUMS | sha256sum -c -
tar -xzf "${base}.tar.gz"
sudo install -m 0755 "${base}/bin/bitcoind" "${base}/bin/bitcoin-cli" /usr/local/bin/
install -m 0600 /dev/null "$MOUNT/data/bitcoin.conf"
printf 'datadir=%s/data\nblocksxor=0\n' "$MOUNT" >"$MOUNT/data/bitcoin.conf"
cat <<EOF
Bitcoin Core installed. Start it as your normal user:
  bitcoind -conf=$MOUNT/data/bitcoin.conf

After it reaches the network tip, stop it with bitcoin-cli and follow the
checkpoint-update procedure in the host documentation.
EOF
