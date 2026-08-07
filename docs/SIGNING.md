# Signing

Pulsar needs two different signatures, and they are not variations of one
thing:

| | signs | key | when |
|---|---|---|---|
| **kernel module** | `nvidia.ko` bytes | the MOK key shipped as `MOK.der` | during the image build |
| **image** | a published image digest | a cosign key | after the push |

Only the first is Secure Boot. It is the one that black-screens a machine when
it is wrong, and the one whose key cannot be regenerated casually.

Both keys live on **halo** (the signing host, in `arclight-infra`). The builder
holds a bearer token and neither key. This document is the contract halo's
`signd` must satisfy for Pulsar; the client half lives here, in
`scripts/sign-file-oracle`.

## Why the builder never holds the module key

A compromised builder is rebuilt from this repo in an afternoon. A compromised
module-signing key means regenerating it, updating the committed `MOK.der`, and
re-enrolling through MokManager **at boot, physically, on every machine running
Pulsar**. Those are not the same kind of loss, and an ephemeral builder spawned
from templated user-data is the worst available home for the second one.

## API

### `POST /sign-module`

The one Pulsar's build depends on, and the one not in the original signd spec.
It takes module **bytes**, not a digest: `sign-file` builds a CMS structure
over the module content, so a hash is not sufficient.

```
Authorization: Bearer <token>
Content-Type: application/octet-stream
X-Pulsar-Hash-Algo: sha256          # sha256 | sha384 | sha512
X-Pulsar-Module: nvidia.ko          # advisory, for the audit log
<body: the uncompressed .ko>

200 application/octet-stream        # detached DER signature (~408 bytes)
401                                 # bad or missing token
413                                 # body over the limit
400                                 # not an ELF object, or unsupported hash
```

Server side this is `sign-file -d <hash> <key> <cert> <module>`, which writes
`<module>.p7s` and leaves the module untouched. The client attaches it with
`sign-file -s`. Both are upstream options; neither side implements crypto.

`sign-file` comes from `kernel-devel`. Any version works — it signs bytes and
does not care which kernel the module targets. That is a runtime dependency on
halo, which is the cost of not reimplementing the kernel's module-signature
format.

Reject bodies that do not start with `\x7fELF`. This service signs kernel
modules; anything else is a caller doing something it should not be.

### `GET /cert`

Returns halo's module-signing certificate, DER. Authenticated.

**Load-bearing, not a convenience.** `sign-file` takes the signer identifier
from whatever certificate it is handed. If the build signed using the committed
`MOK.der`, phase 5 of `Containerfile.nvidia` would compare that file against
itself and pass **even if halo held a completely different key**. Fetching the
cert makes the check assert something real: that the key which signed belongs
to the certificate users are told to enrol.

### `POST /sign` and `GET /healthz`

Image signing over a digest, and liveness. Specified by `arclight-infra`; the
image build does not call them.

## Two traps

**The signing macro fails silent.** `kmodtool`'s
`%__kmodtool_modsign_install_post` guards on
`[ -e privkey ] && [ -e pubkey ]` and, when either is missing, skips signing
with **no error at all** — a green build producing unsigned modules. That is
why phase 3 writes a placeholder at a path nothing reads, and why phase 5's
verification is not optional. Neither is dead code; do not tidy them away.

**`sig_key` is not always the SKI.** It is whichever identifier `sign-file`
embedded, in practice the certificate serial. Phase 5 accepts either; a check
that assumes one will fail on a perfectly good build.

## Where signing happens in the build

`brp-kmodsign` walks the buildroot and signs every uncompressed `.ko` **before**
the RPM compresses them to `.ko.xz`. `scripts/sign-file-oracle` stands in for
`scripts/sign-file` at exactly that point, so nothing else changes: no forked
akmods, no unpacking the built RPM, no rpmdb digest drift.

```
builder                                  halo
  unsigned .ko  ──── POST /sign-module ───▶
                ◀─── detached DER sig ────   sign-file -d  (has the key)
  sign-file -s (attaches)
  brp-kmodsign verifies the trailer
  phase 5 verifies signer == MOK.der
```

## Failure behaviour

Fail closed, everywhere. An unreachable, unauthorised, or slow signer fails
module signing, which fails the RPM build, which fails the image build, which
fails the nightly — including the vanilla image, which needs no signature at
all. One invariant, no half-releases.

Deliberate: the alternative is publishing an nvidia image whose module will not
load, and the machine that pulls it loses its display.

## Testing without halo

`scripts/pulsar-signer.py` is a reference implementation of `/sign-module` and
`/cert` in ~200 lines of stdlib Python. It exists so the client half can be
tested without the real key or the real host, and it is what the Go
implementation should be checked against.

```
# a throwaway key -- never the enrolled one
openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=test/" -keyout key.pem -outform DER -out cert.der

PULSAR_SIGNER_KEY=key.pem PULSAR_SIGNER_CERT=cert.der \
PULSAR_SIGNER_TOKEN_FILE=token.txt \
PULSAR_SIGNER_SIGN_FILE=/usr/src/kernels/$(uname -r)/scripts/sign-file \
  scripts/pulsar-signer.py
```

Then drive it through the real `brp-kmodsign` rather than calling the shim
directly — that is what proved the contract in the first place, and it
exercises the guard and the trailer check too:

```
/usr/lib/rpm/brp-kmodsign <placeholder.priv> <cert.der> <moddir> <fakesrcdir>
```

with `<fakesrcdir>/scripts/sign-file` being the shim and
`<fakesrcdir>/scripts/sign-file.real` the genuine binary.

## Rotating the module key

Expensive. Plan a reboot, and do it in this order — backwards costs you the
display on an nvidia machine.

1. Generate the new keypair on halo; leave the old one in place.
2. Update `system_files/etc/pki/pulsar/MOK.der` here to the new cert and merge.
   Phase 5 fails every build until this matches what halo serves at `/cert`.
3. Build. The new image ships modules signed by the new key.
4. On every machine: `mokutil --import /etc/pki/pulsar/MOK.der`, reboot, and
   enrol through MokManager — **before** booting the new image.
5. Once every machine is enrolled and booted, `mokutil --delete` the old cert
   and remove it from halo.

### Where this rotation currently stands

`bd476ac` did step 2: the committed cert is no longer the akmods-generated
`fedora_1784000352_fff45832` but a purpose-made
`O=Arclight Digital, CN=Pulsar Secure Boot Signing Key`
(SHA1 `71:c0:a5:0c:d2:21:1a:bd:e4:dd:27:c6:15:44:c3:26:3b:18:86:eb`).

Steps 1 and 4 are outstanding, and until they are done:

- **halo must hold this keypair and serve this cert at `/cert`.** Phase 5
  compares the module's signer against the committed `MOK.der`, so a halo
  holding anything else fails every nvidia build. Loudly, which is the good
  case.
- **no machine has enrolled it.** The old akmods cert is what is in firmware.
  An image signed with the new key builds, pushes, and then does not load its
  module — which on an nvidia machine is a black screen. Do step 4 before
  booting anything built after this.

Note for `bootstrap.md` in `arclight-infra`: **both** keys can now be
generated on halo, because neither is enrolled anywhere yet — the module key
stopped being a thing that had to be imported the moment it was rotated to one
firmware has never seen. That is only true until step 4 runs. Once this cert
is enrolled on real machines, a future rotation is back to import-only:
generating a replacement on halo would mean re-enrolling every machine by
hand, at boot, in person.
