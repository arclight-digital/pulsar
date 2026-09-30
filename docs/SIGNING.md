# Signing

Pulsar needs two unrelated signatures:

| | signs | key | when |
|---|---|---|---|
| **kernel module** | `nvidia.ko` bytes | the MOK key shipped as `MOK.der` | during the image build |
| **image** | a published image digest | a cosign key | after the push |

Only the first is Secure Boot: get it wrong and machines black-screen, and its
key can't be casually regenerated.

Both keys live on **halo** (the signing host, in `arclight-infra`). The builder
holds only a bearer token. This is the contract halo's `signd` must meet; the
client is `scripts/sign-file-oracle`.

## Why the builder never holds the module key

A compromised builder is rebuilt from this repo. A compromised module key means
a new `MOK.der` and re-enrolling **every machine, physically, at boot** through
MokManager. An ephemeral builder is the wrong place for that key.

## API

### `POST /sign-module`

Takes module **bytes**, not a digest (`sign-file` builds CMS over the content).

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

- Server: `sign-file -d <hash> <key> <cert> <module>` writes `<module>.p7s`;
  the client attaches it with `sign-file -s`. No custom crypto on either side.
- `sign-file` comes from `kernel-devel` (any version) on halo.
- Reject bodies not starting with `\x7fELF`.

### `GET /cert`

Returns halo's module-signing certificate, DER. Authenticated.

Required, not a convenience: `sign-file` takes the signer identifier from the
certificate it's given. Signing against the committed `MOK.der` would make
phase 5 of `Containerfile.nvidia` compare the file with itself and pass even if
halo held a different key. With `/cert`, phase 5 proves the signing key belongs
to the certificate users enroll.

### Transport trust

Two unrelated certificates: `/cert` returns the **module-signing** cert; the
API itself uses halo's self-signed **transport** cert (SAN = its VPC address,
`10.x`, which no public CA issues for).

- The builder gets the transport cert as `PULSAR_SIGNER_CA_FILE`
  (`/etc/pulsar/halo-ca.pem` on a build host), passed to `scripts/build.sh` as
  `--signer-ca-file`, and into the one RUN that calls halo as a secret mount
  (keeps an absolute host path out of the context and the layers).
- Installing it on the build host is **not enough**: `podman build` uses the
  base image's CA bundle. The symptom is `curl: (60) ... self-signed
  certificate` about 40 minutes in, at phase 3. `build.sh` refuses up front if
  the URL is `https:` and no readable CA file was given.
- Never `curl -k`: the connection carries the token that buys signatures. Use
  a plain-http test signer locally instead.

### `POST /sign` and `GET /healthz`

Image signing over a digest, and liveness. Specified by `arclight-infra`; the
image build doesn't call them.

## Two easy mistakes

- **The signing macro fails silently.** `kmodtool`'s
  `%__kmodtool_modsign_install_post` skips signing, with no error, unless both
  `privkey` and `pubkey` exist. So phase 3 writes a placeholder at an unused
  path, and phase 5's verification is mandatory. Don't remove either.
- **`sig_key` isn't always the SKI.** It's whatever identifier `sign-file`
  embedded (in practice the certificate serial). Phase 5 accepts either.

## Where signing happens in the build

`brp-kmodsign` signs every uncompressed `.ko` **before** the RPM compresses it
to `.ko.xz`. `scripts/sign-file-oracle` replaces `scripts/sign-file` at that
point; nothing else changes (no forked akmods, no RPM unpacking, no rpmdb
drift).

```
builder                                  halo
  unsigned .ko  ──── POST /sign-module ───▶
                ◀─── detached DER sig ────   sign-file -d  (has the key)
  sign-file -s (attaches)
  brp-kmodsign verifies the trailer
  phase 5 verifies signer == MOK.der
```

## Failure behavior

Fail closed: an unreachable, unauthorized or slow signer fails module signing,
the RPM, the image and the whole nightly, vanilla image included. Otherwise an
nvidia image with an unloadable module would ship and black-screen its
machines.

## Testing without halo

`scripts/pulsar-signer.py` is a stdlib reference implementation of
`/sign-module` and `/cert` (~200 lines), for testing the client without the
real key or host, and for checking the Go implementation against.

```
# a throwaway key -- never the enrolled one
openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=test/" -keyout key.pem -outform DER -out cert.der

PULSAR_SIGNER_KEY=key.pem PULSAR_SIGNER_CERT=cert.der \
PULSAR_SIGNER_TOKEN_FILE=token.txt \
PULSAR_SIGNER_SIGN_FILE=/usr/src/kernels/$(uname -r)/scripts/sign-file \
  scripts/pulsar-signer.py
```

Test through the real `brp-kmodsign` (it also exercises the guard and the
trailer check):

```
/usr/lib/rpm/brp-kmodsign <placeholder.priv> <cert.der> <moddir> <fakesrcdir>
```

with `<fakesrcdir>/scripts/sign-file` the shim and
`<fakesrcdir>/scripts/sign-file.real` the genuine binary.

## Rotating the module key

Requires a reboot per machine. In this order (reversed, nvidia machines lose
their display):

1. Generate the new keypair on halo; keep the old one.
2. Update `system_files/etc/pki/pulsar/MOK.der` to the new cert and merge.
   Phase 5 fails every build until it matches halo's `/cert`.
3. Build. New images ship modules signed by the new key.
4. On every machine: `mokutil --import /etc/pki/pulsar/MOK.der`, reboot, and
   enroll in MokManager, **before** booting the new image.
5. Once every machine is enrolled and booted, `mokutil --delete` the old cert
   and remove it from halo.

### Current state

`bd476ac` did step 2: the committed cert is
`O=Arclight Digital, CN=Pulsar Secure Boot Signing Key`
(SHA1 `71:c0:a5:0c:d2:21:1a:bd:e4:dd:27:c6:15:44:c3:26:3b:18:86:eb`), replacing
the akmods-generated `fedora_1784000352_fff45832`.

Steps 1 and 4 are outstanding. Until then:

- **halo must hold this keypair and serve this cert at `/cert`**, or every
  nvidia build fails at phase 5.
- **No machine has enrolled it.** Firmware holds the old akmods cert, so an
  image signed with the new key won't load its module (black screen). Do step
  4 before booting anything built since.

For `bootstrap.md` in `arclight-infra`: until step 4 runs, both keys can be
generated on halo, since neither is enrolled anywhere. After that, the module
key is import-only again: replacing it means re-enrolling every machine in
person.
