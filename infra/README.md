# Infrastructure

Two DigitalOcean droplets in one region, on the same VPC, in different trust
domains.

| | holds | runs |
|---|---|---|
| **builder** | ghcr push credentials, a signer token | the nightly image build, the weekly ISO |
| **signer** | the Secure Boot key, the cosign key | one HTTP service, nothing else |

The split exists because the two losses are not comparable. A compromised
builder is rebuilt from this repo in an afternoon. A compromised signing key
means regenerating it, updating the committed `MOK.der`, and re-enrolling
through MokManager **at boot, physically, on every machine running Pulsar**.
So the builder — an always-on box that pulls from the internet, runs a package
manager, and executes a Containerfile — never holds the key. It asks for
signatures and gets them back.

## builder

8 vCPU / 16GB, with a block-storage volume for the container store and the OCI
layouts. Both images are ~17GB before intermediates.

Mount the volume at `/var/mnt`, not `/mnt`. This is not cosmetic. The
containers-storage library resolves the configured graphroot through symlinks
before comparing it to the path recorded in the store's database, and inside
the ostree-based tool image `/mnt` is a symlink to `var/mnt`. A store at
`/mnt/podman` on the host and a tool that resolves that to `/var/mnt/podman`
disagree, the store is refused, and `--from` responds by silently pulling the
published image from the registry instead — so the build re-chunks last
night's content and ships bytes it never built. Mounting at `/var/mnt` removes
the ambiguity entirely.

```
/etc/pulsar/build.env            root:pulsar 0640
  IMAGE=ghcr.io/arclight-digital/pulsar
  IMAGE_NVIDIA=ghcr.io/arclight-digital/pulsar-nvidia
  PULSAR_SIGNER_URL=http://10.x.x.x:8099        # the signer's PRIVATE address
  PULSAR_SIGNER_TOKEN_FILE=/etc/pulsar/signer-token
  PULSAR_BUILD_WORK=/var/mnt/pulsar-build
  PULSAR_HEALTHCHECK_URL=https://hc-ping.com/...
```

Install `infra/pulsar-build.service` and `.timer`, then
`systemctl enable --now pulsar-build.timer`.

## signer

Smallest droplet. Needs `sign-file`, which comes from `kernel-devel` — any
version will do, since it signs bytes and does not care which kernel the
module targets.

```
/etc/pulsar-signer/key.pem       pulsar-signer:pulsar-signer 0400
/etc/pulsar-signer/cert.der      0444
/etc/pulsar-signer/token         0400   (>= 32 bytes of entropy)
/etc/pulsar-signer/signer.env    0440
  PULSAR_SIGNER_BIND=10.x.x.x                   # the PRIVATE address
  PULSAR_SIGNER_TOKEN_FILE=/etc/pulsar-signer/token
  PULSAR_SIGNER_SIGN_FILE=/usr/src/kernels/*/scripts/sign-file
```

The service refuses to start on `0.0.0.0`. Put a DO cloud firewall in front of
it admitting only the builder's private IP on the service port, and restrict
SSH to your own address. The token is the third lock, not the only one.

**Back the key up offline** — encrypted, on media you hold. Not in DO
snapshots, which are a copy of the key sitting in the same account as the
thing you are protecting it from. A lost key and a leaked key cost the same
MOK re-enrolment.

## How signing works

`kmodtool`'s `%__kmodtool_modsign_install_post` runs `brp-kmodsign`, which
walks the buildroot and signs every uncompressed `.ko` before the RPM
compresses them to `.ko.xz`. `scripts/sign-file-oracle` stands in for
`scripts/sign-file` at that exact point, so nothing else in the build changes.

```
builder                            signer
  unsigned .ko  ── POST /sign-module ──▶
                ◀── detached DER sig ──   sign-file -d (has the key)
  sign-file -s (attaches it)
```

Two traps worth knowing before you touch any of this:

**The signing macro fails silent.** It guards on
`[ -e privkey ] && [ -e pubkey ]` and, if either is missing, skips signing
with no error at all — a successful build producing unsigned modules, which
black-screen the machine under Secure Boot. That is why phase 3 writes a
placeholder at a path nothing reads, and why phase 5's verification is not
optional.

**The cert must come from the signer.** `sign-file` takes the signer
identifier from whatever cert it is handed, so signing with the committed
`MOK.der` would make phase 5 compare that file against itself and pass even if
the signer held a completely different key. The build fetches `GET /cert` so
the check asserts something real.

## When the signer is down

The nightly fails, entirely, and publishes nothing — including the vanilla
image, which needs no signature. That is the chosen behaviour: one invariant,
no half-releases. Bring the signer back and re-run:

```
systemctl start pulsar-build.service
```

## Rotating the signing key

Expensive. Plan a reboot.

1. Generate a new keypair on the signer; leave the old one in place.
2. Update `system_files/etc/pki/pulsar/MOK.der` in this repo to the new cert
   and merge. Phase 5 fails the build until this matches.
3. Build. The new image ships modules signed by the new key.
4. On every machine: `mokutil --import /etc/pki/pulsar/MOK.der`, reboot, and
   enrol through MokManager. **Do this before rebooting into the new image** —
   a machine that boots an image whose modules it cannot verify loses its GPU
   driver, and with it, in the nvidia case, the display.
5. Once every machine is enrolled and booted, `mokutil --delete` the old cert
   and remove it from the signer.

## Verifying a build without publishing

The whole pipeline runs anywhere:

```
scripts/rechunk-selftest.sh                   # the rechunk path, on a toy, in minutes
scripts/build.sh --verify --variant vanilla   # build, rechunk, assert, no push
```

`scripts/diff-chunk-metadata.sh` runs inside `--verify` and blocks on
ownership, setuid/setgid, and world-writable changes across the rechunk,
reporting plain mode drift without failing. It is there because
`build-chunked-oci` writes the image through an ostree commit, and there is a
known upstream class of bug where modes and ownership come out different from
the base commit. On an image carrying an enrolled Secure Boot key, that
question gets asked rather than assumed.
