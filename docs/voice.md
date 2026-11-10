# Voice samples

Passages by the project's owner, quoted word for word, for matching tone when
writing copy. See `.claude/rules/prose.md`.

**Authorship is presumed, not confirmed.** Every passage below comes from
`README.md` as of commit `18ea3028` ("Add MIT license, rewrite README",
Nick Duncan, 2026-08-04), the only prose commit in the history with no AI
co-author trailer. AI-assisted commits with trailers began the same day, so
the owner should confirm these are his before they are relied on. None of
them survive in the current README.

## 1. Opening

Source: `README.md` @ 18ea3028, lines 5-10.

> A personal Fedora Silverblue 44 spin, built as a bootc image. Pure Fedora —
> no Universal Blue inheritance. Built and signed in CI; the laptop only pulls.
>
> Tuned for an Arrow Lake-HX / RTX 5080 Max-Q laptop, but nothing in the vanilla
> image is hardware-bound.

## 2. What's in it

Source: `README.md` @ 18ea3028, "What's in it", first paragraph.

> Branding, Host Grotesk + JetBrains Mono, a plymouth theme, and the papercuts
> already fixed. `scx_lavd` runs the scheduler — Arrow Lake-HX is 8 P-cores and
> 16 E-cores with no SMT, which is exactly where stock EEVDF places threads
> badly. Unfiltered Flathub, shipped as an image-native remote so it survives a
> rebase. Split-lock mitigation off and `vm.max_map_count` raised, because
> several games need both.

## 3. What belongs in the image

Source: `README.md` @ 18ea3028, "What's in it", second and third paragraphs.

> System-level capability only: `gamescope`, `gamemode`, `mangohud`,
> `steam-devices`, `distrobox`, `libvirt`, `android-tools`, `gnome-tweaks`.
> Anything you merely *run* is a Flatpak. This image is the OS.
>
> The nvidia variant builds `nvidia-open` against the image's exact kernel and
> signs it. Blackwell has no closed-driver option, which is fine — the open
> module is the better one now anyway.

## 4. The signing key

Source: `README.md` @ 18ea3028, "Two variants, one key", second paragraph.

> `system_files/etc/pki/pulsar/MOK.der` is the public half. It ships in **both**
> images so the key can be enrolled before the driver is in play. The nvidia
> build fails if the module's signer doesn't match that cert — a stale cert
> becomes a red CI run instead of a black screen at boot.

## 5. A warning to forkers

Source: `README.md` @ 18ea3028, "Two variants, one key", third paragraph.

> **Running this yourself?** Fork it and use your own key. Enrolling my cert
> means your machine permanently trusts modules I sign, which is not a
> relationship you want with a stranger's laptop. The vanilla image needs no
> keys at all.

## 6. Install steps

Source: `README.md` @ 18ea3028, "Install", the MokManager paragraphs.

> The next boot stops in **MokManager**, a blue firmware screen:
> `Enroll MOK` → `View key 0` → `Continue` → `Yes` → password → reboot.

> Miss the MokManager prompt and nothing breaks — the enrollment just doesn't
> happen. Run `mokutil --import` again.

## 7. Updates

Source: `README.md` @ 18ea3028, "Updates".

> Stock Silverblue behaviour, on purpose. GNOME Software notices and tells you;
> it installs when you choose to restart. bootc's `fetch-apply-updates.timer` is
> left disabled deliberately — it reboots on its own.
>
> CI rebuilds nightly, so kernels, security updates, and driver bumps arrive as
> a normal update notification. Impatient: `sudo bootc upgrade`.

## 8. Working on it

Source: `README.md` @ 18ea3028, "Working on it", paragraph after the layout block.

> Push to `main` and CI does the rest. `build.sh` is only for checking a
> Containerfile edit before it gets there, and it needs root — the nvidia
> variant derives `FROM` the vanilla image, and rootless and rootful podman
> keep separate storage.
