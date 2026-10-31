# M4 Mac mini (J773g) developer build

This fork (techmore/omarchy-mac-installer, branch `elementaryos-mseries`) admits the Mac mini (M4, 2024): `apple,j773g`, device class `j773gap`, chip T8132 (`0x8132`). The board is a `developer` entry of `scripts/supported-models.json`, so only a developer build's sealed catalog can enable it; channel catalogs and the public trust root are unchanged.

What the branch changes: the engine admits `j773gap` on 26.6.2 (25G83) OS firmware with a 6 GB stub, boots it from Aurora's raw Stage 1 (`esp/aurora/stage1-j773g.bin`), enrolls it with `bputil -nca` (Aura `aura-proxy`/`aura-debug` boot arguments), collects its BCM4388 Wi-Fi and Bluetooth inputs (`omarchy_j773g_radio`), and records install timing; the image builder stages the J773g Stage 1, requires `t8132-j773g.dtb`, and adds the Linux timing milestones and first-login Claude Code step. `Engine/source-lock.json` pins the engine built from all of it.

## Developer catalog key

The developer catalog is signed by its own Ed25519 key, not Omacom's. Only the public half is in the repository: `Release/developer-j773g/trust-root.ed25519.pub`, with `Release/developer-j773g/release.json` (`scripts/make-release-descriptor --adhoc`, fingerprint `sha256:e983d95d1fa6e82ae6bdb10c5fef77e13a4c074e6d370b4aeaecafbb29c3e379`). The private key was generated with `swift scripts/catalog-signing.swift generate` outside the repository and must never enter it. `Release/` itself keeps Omacom's trust root, so `test/all` and every other build are unaffected; the developer build takes this directory as its release directory instead.

## Building the J773g payload

The image needs a candidate set with our kernel (`linux-aurora` from techmore/linux-m1pro-touchid, which ships `t8132-j773g.dtb`), our `m1n1-aurora` (techmore/m1n1, which installs the raw Stage 1 at `usr/share/m1n1-aurora/stage1/m1n1-raw.bin`) and an M4-admitting `mesa-aurora`/`vulkan-aurora` (aurora-silicon/mesa `aurora-wip`). The candidate importer (`image-builder/builder/candidate_set.py`) trusts only `image-builder/builder/candidate-trust/`, so pointing it at our package repository is three edits in `policy.json` plus one file, once that repository exists:

1. `boot_repository`: the repository the boot and support packages' signed manifest names as their `source.repository` (for example `techmore/omarchy-pkgs`, the fork carrying the re-pinned PKGBUILDs). Each boot or support package must name it with a 40-hex commit, or come from the Omarchy channel.
2. `primary_fingerprint`, `signing_fingerprint` and `public_key_sha256`: our candidate signing key's (`gpg --with-colons --fingerprint KEY`, and `sha256sum` of the armored export).
3. Replace `public.asc` with that key's armored public key (`gpg --armor --export KEY`). Keep the private key outside the repository, like the catalog key.
4. If our runtime packages are not built from omacom/omarchy, add our repository to `source_repositories` (or `platform_repositories` for `omarchy-mac`/`omarchy-mac-boot`); otherwise build them from an omacom/omarchy commit as the policy expects.

Raise `minimum_versions` only if our packages' versions sort above the channel's (they should, so a `pacman -Syu` on the Mac never replaces them). Then, on an aarch64 Linux host with Docker:

```sh
image-builder/bin/mac-image-inputs resolve inputs --candidates set/ --cache cache/
image-builder/bin/build-mac-image --inputs inputs --candidates set/ --cache cache/ out/
image-builder/bin/mac-image-check payload edge out/<payload>.zip out/installer_data.json
```

`INSPECTION` must pass, and the payload must carry `esp/aurora/stage1-j773g.bin` and a `m1n1/boot.bin` holding `t8132-j773g.dtb`.

### Lab shortcut (fallback)

Until the signed repository exists, repack a published edge payload instead. This skips the builder's inspection, so treat the result as a lab image:

1. Unzip the edge payload; loop-mount `root.img` (btrfs, subvolume `@`) and `boot.img`, and bind the ESP tree at `/boot/efi`.
2. In a chroot (`arch-chroot`), `pacman -U` our `linux-aurora`, `linux-aurora-headers`, `m1n1-aurora`, `mesa-aurora` and `vulkan-aurora` archives, then `mkinitcpio -P`, `update-m1n1` (it rebuilds `/boot/efi/m1n1/boot.bin` with every DTB, `t8132-j773g.dtb` included) and the Limine/UKI refresh the boot package's hook runs.
3. Copy `/usr/share/m1n1-aurora/stage1/m1n1-raw.bin` to `esp/aurora/stage1-j773g.bin` in the payload tree, and copy `image-builder/builder/install-timing/*` into the root as `stage_install_timing` does if the timing is wanted.
4. Unmount, re-zip with the same member layout, and run `image-builder/bin/mac-image-check payload edge PAYLOAD.zip installer_data.json` on it. Its `@factory` seal and `PROVENANCE` still describe the edge build: do not publish it.

## Sealed developer catalog

Once the payload exists, with `$K` the private catalog key and the engine archive from `python3 Engine/prepare-engine.py --output Engine/artifacts`:

```sh
assets=$(mktemp -d)
cp Engine/artifacts/installer-v0.9.2-omarchy.*.tar.gz "$assets/"
cp out/omarchy-*-j773g-os-package.zip "$assets/"         # the name in the inputs' payload_name
cp out/installer_data.json "$assets/installer_data.json"
cp out/installer_data.json "$assets/installer_data-j773g.json"
# Set downstream_revision to the pushed commit and the payload name and dates in a copy of the template.
cp scripts/release-inputs-j773g-developer.template.json "$assets/inputs.json"
python3 scripts/make-unsigned-catalog.py --developer \
  --base-url https://example.invalid/omarchy-j773g \
  --assets-dir "$assets" --inputs "$assets/inputs.json" --output "$assets/catalog.json"
swift scripts/catalog-signing.swift sign "$K" "$assets/catalog.json" "$assets/catalog.json.sig"
swift scripts/catalog-signing.swift verify Release/developer-j773g/trust-root.ed25519.pub \
  "$assets/catalog.json" "$assets/catalog.json.sig"
```

The template's main group and the J773g group share the one J773g payload (`make-unsigned-catalog.py` allows groups to share a payload), so no edge payload is needed; each group has its own metadata file. The base URL is informational for an offline build: the app uses the embedded files.

## Developer app and package

```sh
release=$(mktemp -d)
cp Release/developer-j773g/release.json Release/developer-j773g/trust-root.ed25519.pub \
  "$assets/catalog.json" "$assets/catalog.json.sig" "$release/"
mkdir "$release/offline-artifacts"
cp "$assets"/installer-v0.9.2-omarchy.*.tar.gz "$assets"/*.zip "$assets"/installer_data*.json "$release/offline-artifacts/"
OMARCHY_DEVELOPER_BUILD=1 OMARCHY_OFFLINE_BUILD=1 Packaging/build-app.sh "$release" "$PWD/dist"
Packaging/build-developer-pkg.sh "$PWD/dist/Omarchy Installer.app" "$PWD/dist/Omarchy-J773g-developer.pkg"
```

The app is ad hoc signed and the package unsigned: local hardware testing only. Installing it registers the privileged helper and the install changes the disk and boot policy, so both need the owner at the Mac.

## Debug SSH

The image enables key-only SSH at first boot for the first user, with the public keys of GitHub user `techmore` (`ssh_debug_github_user` in `image-builder/bin/build-mac-image`), and mDNS, so `ssh <user>@<hostname>.local` works from the LAN once `ssh_ready` is logged. Opt out with `/etc/omarchy/no-ssh-debug`, or `omarchy-no-ssh-debug` at the ESP root before the first boot; see [Debug SSH](../image-builder/README.md#debug-ssh-developer-image).

## Known gaps

- Bluetooth and full-power Wi-Fi need their factory calibration in the device tree: `hci_bcm4377` refuses to probe without `brcm,taurus-bf-cal-blob`, and `brcmfmac` loads `brcm,cal-blob` when present. The J773g ADT carries neither, so the engine packages them as `brcm/brcmbt4388-<address>-bf.bin` and `brcm/brcmfmac4388-<address>-cal.bin`. Neither uboot-aurora nor our kernel reads those files yet; GravityLinux's U-Boot injects them. One of the two needs that loader.
- No display (DCP) driver for T8132 yet: the desktop runs on the framebuffer m1n1 preserves.
- Unverified on hardware: our raw Stage 1 on 26.6.2 iBoot, the app on macOS 27, and the kernel/Mesa UAPI match.
