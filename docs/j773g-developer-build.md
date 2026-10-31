# M4 Mac mini (J773g) developer build

This fork (techmore/omarchy-mac-installer, branch `elementaryos-mseries`) admits the Mac mini (M4, 2024): `apple,j773g`, device class `j773gap`, chip T8132 (`0x8132`). The board is a `developer` entry of `scripts/supported-models.json`, so only a developer build's sealed catalog can enable it; channel catalogs and the public trust root are unchanged.

What the branch changes: the engine admits `j773gap` on 26.6.2 (25G83) OS firmware with a 6 GB stub, boots it from Aurora's raw Stage 1 (`esp/aurora/stage1-j773g.bin`), enrolls it with `bputil -nca` (Aura `aura-proxy`/`aura-debug` boot arguments), collects its BCM4388 Wi-Fi and Bluetooth inputs (`omarchy_j773g_radio`), and records install timing; the image builder stages the J773g Stage 1, requires `t8132-j773g.dtb`, and adds the Linux timing milestones and first-login Claude Code step. `Engine/source-lock.json` pins the engine built from all of it.

## Developer catalog key

The developer catalog is signed by its own Ed25519 key, not Omacom's. Only the public half is in the repository: `Release/developer-j773g/trust-root.ed25519.pub`, with `Release/developer-j773g/release.json` (`scripts/make-release-descriptor --adhoc`, fingerprint `sha256:e983d95d1fa6e82ae6bdb10c5fef77e13a4c074e6d370b4aeaecafbb29c3e379`). The private key was generated with `swift scripts/catalog-signing.swift generate` outside the repository and must never enter it. `Release/` itself keeps Omacom's trust root, so `test/all` and every other build are unaffected; the developer build takes this directory as its release directory instead.

## Building the J773g payload

The image is built from a signed candidate set by the unchanged builder, with the developer trust directory `image-builder/builder/candidate-trust-j773g-developer/` selected by `MAC_IMAGE_CANDIDATE_TRUST=j773g-developer` (the importer and `build-mac-image` take only a committed sibling `candidate-trust-<name>/`; without the variable nothing changes). That directory pins:

- our package-signing key, `02BDBB8ABD0FE89754E516D7F845D9C64C9B2A80` (Ed25519, `public.asc` sha256 `e9e5e162b1041f3c500b840809bf1336d649284a6fa845853ddae3d13ea28ffe`). The private key is in a GnuPG home outside the repository (`~/.config/omarchy-dev-keys/pkg-signing/` on the owner's Mac);
- `boot_repository` `techmore/omarchy-pkgs`: `linux-aurora`/`-headers` and `mesa-aurora`/`vulkan-aurora` from `elementaryos-mseries` 524d2ca8 (kernel techmore/linux-m1pro-touchid fa26b0f, Mesa aurora-silicon/mesa 8990cdb), `m1n1-aurora` from 34c27c6e (techmore/m1n1 9347c18), `omarchy-mlx-vulkan-aurora` from `elementaryos-mseries-mlx` ab549f15 and `omarchy-trial-boot` from `elementaryos-mseries-safeboot` 0184a422, the last two added to `support_packages`;
- those versions as `minimum_versions` (`linux-aurora` 7.3.0.aurora90-1, `m1n1-aurora` 1.6.1.aurora90-1, Mesa 1:26.3.0_devel.20261031…), so inspection fails if the channel's builds slip in.

The runtime comes from omacom/omarchy `v4.5.0-rc2` (5978d93ae7da): `omarchy` and `omarchy-settings` 4.5.0rc2-1.1 are rebuilt from the rc PKGBUILDs (techmore/omarchy-pkgs `elementaryos-mseries-runtime`, 6d15bc7d) only to add the `source-revision` file the importer requires; `omarchy-mac` 0.2.3-1 is the edge archive, declared as a platform package (omacom/omarchy-mac-pkgs 60d03b73); `omarchy-mac-boot`, `uboot-aurora`, `limine-mkinitcpio-hook` and the other Aurora support packages are edge archives, each checked against the Omarchy key before it is re-signed. `ane-h16-experimental` and `omarchy-mlx-m4-bench` (which pulls the 740 MB `omarchy-mlx`) are in the package repository only, opt-in.

`image-builder/developer/make-candidate-set` writes and signs the set (it stands in for omarchy-mac's candidate-set tool, which is not public). On the Mac, with the archives in `all/` and the plan in `plan.json`:

```sh
image-builder/developer/make-candidate-set --plan plan.json --packages all/ \
  --gnupghome ~/.config/omarchy-dev-keys/pkg-signing --fingerprint 02BDBB8ABD0FE89754E516D7F845D9C64C9B2A80 \
  --public-key image-builder/builder/candidate-trust-j773g-developer/public.asc --output set/
MAC_IMAGE_CANDIDATE_TRUST=j773g-developer python3 image-builder/builder/candidate_set.py describe --input set/
```

Then, on an aarch64 Linux host with Docker (the build ran in the owner's Lima VM `kbuild`):

```sh
export MAC_IMAGE_CANDIDATE_TRUST=j773g-developer
image-builder/bin/mac-image-inputs resolve inputs --candidates set/ --cache cache/
sudo --preserve-env=MAC_IMAGE_CANDIDATE_TRUST image-builder/bin/build-mac-image --inputs inputs --candidates set/ --cache cache/ out/
image-builder/bin/mac-image-check payload edge out/<payload>.zip out/installer_data.json
```

`INSPECTION` must pass, and the payload must carry `esp/aurora/stage1-j773g.bin` and a `m1n1/boot.bin` holding `t8132-j773g.dtb`. The image's profile is `test` (a candidate-only set), so its pacman.conf keeps the runtime with the marked test pin, and it never passes the public release guard.

The same signed archives are published as the pacman repository `omarchy-j773g` (database and packages signed by the same key) for installing the opt-in packages and later updates by hand; the image does not list it in `/etc/pacman.conf`.

### Lab shortcut (fallback)

Until the signed repository exists, repack a published edge payload instead. This skips the builder's inspection, so treat the result as a lab image:

1. Unzip the edge payload; loop-mount `root.img` (btrfs, subvolume `@`) and `boot.img`, and bind the ESP tree at `/boot/efi`.
2. In a chroot (`arch-chroot`), `pacman -U` our `linux-aurora`, `linux-aurora-headers`, `m1n1-aurora`, `mesa-aurora` and `vulkan-aurora` archives, then `mkinitcpio -P`, `update-m1n1` (it rebuilds `/boot/efi/m1n1/boot.bin` with every DTB, `t8132-j773g.dtb` included) and the Limine/UKI refresh the boot package's hook runs.
3. Copy `/usr/share/m1n1-aurora/stage1/m1n1-raw.bin` to `esp/aurora/stage1-j773g.bin` in the payload tree, and copy `image-builder/builder/install-timing/*` into the root as `stage_install_timing` does if the timing is wanted.
4. Unmount, re-zip with the same member layout, and run `image-builder/bin/mac-image-check payload edge PAYLOAD.zip installer_data.json` on it. Its `@factory` seal and `PROVENANCE` still describe the edge build: do not publish it.

## Sealed developer catalog, app and package

`Packaging/build-j773g-developer.sh PAYLOAD_DIRECTORY OUTPUT_DIRECTORY` does the rest: it copies the engine archive (`Engine/prepare-engine.py` builds it when missing), the payload and its `.partNN` files and `installer_data.json` (also as `installer_data-j773g.json`) into `OUTPUT/assets`, fills a copy of `scripts/release-inputs-j773g-developer.template.json` (payload name, `downstream_revision` = `HEAD`), runs `make-unsigned-catalog.py --developer`, signs the catalog with the developer key (`scripts/catalog-signing.swift sign`) and verifies it against `Release/developer-j773g/trust-root.ed25519.pub`, then builds the app with `OMARCHY_DEVELOPER_BUILD=1`.

Settings (environment variables; none is a secret):

| Variable | Default | Meaning |
|---|---|---|
| `OMARCHY_J773G_CATALOG_KEY` | `~/.config/omarchy-dev-keys/j773g-developer-catalog.ed25519` | private catalog key, mode 0600, never in the repository |
| `OMARCHY_J773G_BASE_URL` | none (required online) | https base the app downloads the payload and its parts from |
| `OMARCHY_OFFLINE_BUILD` | `0` | `1` embeds the payload in the app instead |
| `OMARCHY_APP_SIGNING_IDENTITY` | `-` (ad hoc) | `Developer ID Application: NAME (TEAMID)` or the certificate's SHA-1 |
| `OMARCHY_TEAM_ID` | from the identity's `(TEAMID)` | the signing team; the helper requirement and `release.json` name it |
| `OMARCHY_NOTARY_PROFILE` | none | `xcrun notarytool` keychain profile; with a Developer ID identity the app is notarized and stapled |

**Ad hoc (default, works now).** The app is ad hoc signed (`codesign --sign -`, no timestamp) and wrapped in an unsigned developer `.pkg` (`Packaging/build-developer-pkg.sh`), which binds the root helper to the app's exact code hash. Gatekeeper blocks both on first open: right-click the `.pkg` → Open, or allow it in System Settings → Privacy & Security ("Open Anyway"). Only for the owner's Mac.

```sh
OMARCHY_J773G_BASE_URL=https://github.com/techmore/omarchy-mac-installer/releases/download/j773g-dev-<date> \
  Packaging/build-j773g-developer.sh out/ /private/tmp/j773g-app
```

**Developer ID (signed and notarized).** Needs a "Developer ID Application" certificate with its private key in the login keychain (`security find-identity -v -p codesigning` lists it) and notary credentials stored once with `xcrun notarytool store-credentials omarchy-notary --apple-id … --team-id …` (it prompts for the app-specific password; nothing here reads or stores it). Then:

```sh
OMARCHY_APP_SIGNING_IDENTITY="Developer ID Application: NAME (TEAMID)" \
OMARCHY_NOTARY_PROFILE=omarchy-notary \
OMARCHY_J773G_BASE_URL=https://github.com/techmore/omarchy-mac-installer/releases/download/j773g-dev-<date> \
  Packaging/build-j773g-developer.sh out/ /private/tmp/j773g-app-signed
```

`build-app.sh` signs every nested binary and the app with `codesign --force --sign "$identity" --timestamp --options runtime` (hardened runtime, secure timestamp), and the helper, client and decoder requirements name the team. The descriptor is regenerated for the team (`scripts/make-release-descriptor --public-key Release/developer-j773g/trust-root.ed25519.pub`) over the same developer trust root. `Packaging/notarize-app.sh` then zips the app, runs `xcrun notarytool submit --keychain-profile omarchy-notary --wait`, `xcrun stapler staple` and `stapler validate`, and checks `spctl --assess`; `make-download-zip.sh` writes `Omarchy-J773g-developer.zip`. No `.pkg` is made in this mode: the signed app installs its helper itself, and a signed `.pkg` would need a separate "Developer ID Installer" certificate.

Installing it registers the privileged helper and the install changes the disk and boot policy, so both need the owner at the Mac.

## Debug SSH

The image enables key-only SSH at first boot for the first user, with the public keys of GitHub user `techmore` (`ssh_debug_github_user` in `image-builder/bin/build-mac-image`), and mDNS, so `ssh <user>@<hostname>.local` works from the LAN once `ssh_ready` is logged. Opt out with `/etc/omarchy/no-ssh-debug`, or `omarchy-no-ssh-debug` at the ESP root before the first boot; see [Debug SSH](../image-builder/README.md#debug-ssh-developer-image).

## Known gaps

- Bluetooth and full-power Wi-Fi need their factory calibration in the device tree: `hci_bcm4377` refuses to probe without `brcm,taurus-bf-cal-blob`, and `brcmfmac` loads `brcm,cal-blob` when present. The J773g ADT carries neither, so the engine packages them as `brcm/brcmbt4388-<address>-bf.bin` and `brcm/brcmfmac4388-<address>-cal.bin`. Neither uboot-aurora nor our kernel reads those files yet; GravityLinux's U-Boot injects them. One of the two needs that loader.
- No display (DCP) driver for T8132 yet: the desktop runs on the framebuffer m1n1 preserves.
- Unverified on hardware: our raw Stage 1 on 26.6.2 iBoot, the app on macOS 27, and the kernel/Mesa UAPI match.
