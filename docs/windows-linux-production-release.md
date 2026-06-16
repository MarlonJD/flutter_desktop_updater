# Windows And Linux Production Release Options

This document covers production-trust choices for Windows and Linux releases
that use `desktop_updater` or a native package channel.

It is release-engineering guidance, not legal advice. Signing availability,
store policies, sanctions, export controls, and certificate rules change over
time. Re-check the official provider documentation before a production launch.

## Quick Recommendation

For `desktop_updater` direct zip updates:

- Windows: sign the built `.exe` and `.dll` files with Authenticode before
  packaging the update zip, timestamp the signatures, and verify signatures in
  CI before `release publish` exposes the update.
- Linux: decide whether a direct zip updater is appropriate for your audience.
  For public production distribution, add a publisher-authenticity layer for the
  update descriptors, or use a native package channel that already has repository
  signing and update policy.
- Keep HTTPS, stable package identity, short cache TTLs for `app-archive.json`,
  and immutable cache TTLs for versioned release files and artifacts.
- Treat `release.json` SHA-256 as artifact integrity, not publisher identity.
  The hash proves the downloaded zip matches the descriptor. The descriptor also
  needs to come from a trusted channel or be signed by a pinned publisher key.

## Windows Options

### Direct Zip Plus Authenticode

This is the closest fit for the current `desktop_updater` publish flow.

Recommended release order:

1. Build the Windows Release bundle.
2. Sign the application `.exe` and any signable `.dll` files.
3. Timestamp the signatures with an RFC 3161 timestamp server.
4. Verify the signatures and fail CI if verification fails.
5. Run `dart run desktop_updater:release publish --platform windows`.
6. Run `dart run desktop_updater:release validate ...` against the hosted
   package.

Example signing shape:

```powershell
signtool sign /fd SHA256 /tr https://timestamp.example.com /td SHA256 `
  /n "Example Publisher" build\windows\x64\runner\Release\example.exe

signtool verify /pa /all build\windows\x64\runner\Release\example.exe
```

Notes:

- Microsoft SignTool is part of the Windows SDK and can sign, timestamp, and
  verify files.
- Modern SignTool requires file digest and timestamp digest options such as
  `/fd SHA256` and `/td SHA256`.
- Authenticode helps Windows identify the publisher and detect tampering of the
  signed executable. It does not by itself prove that the update metadata came
  from your server.
- SmartScreen reputation is separate from a valid signature. A new publisher or
  newly issued certificate can still see warnings until reputation builds.

### Microsoft Artifact Signing

Microsoft Artifact Signing is a managed signing service. It is useful when you
want certificate lifecycle and private key custody managed through Azure instead
of a local PFX or USB token.

Good fit when:

- Your team already uses Azure.
- You want cloud-managed key protection and auditability.
- Your country, organization type, and certificate need are supported.

Important restrictions to confirm before choosing it:

- Public Trust is currently available to organizations in the USA, Canada, the
  European Union, and the United Kingdom, and to individual developers in the
  USA and Canada.
- That Public Trust country restriction does not apply to Private Trust
  certificates.
- Artifact Signing resources are available only in supported Azure regions.

### Public CA Code Signing Certificate

This is the classic Windows desktop path.

Good fit when:

- You need broadly trusted Windows desktop signatures.
- You want vendor portability across CI providers.
- You can satisfy the certificate authority identity and key-protection process.

Notes:

- Public code signing certificate issuance depends on the CA's supported
  countries, identity verification process, payment processors, and sanctions
  rules. There is no single global country list across all CAs.
- CA/Browser Forum Code Signing Baseline Requirements require private keys for
  public code signing certificates to be generated, stored, and used in suitable
  hardware crypto modules or compliant signing services.
- Certificates issued on or after 2026-03-01 have a maximum validity period of
  460 days under the current CA/B Forum baseline.
- EV code signing can help publisher reputation in some Windows workflows, but
  it is not a replacement for update metadata authenticity.

### MSIX Or Microsoft Store

MSIX and Microsoft Store distribution are separate from the direct zip updater
model.

Good fit when:

- You want Windows-managed install, update, and package identity behavior.
- Your app can live within MSIX packaging constraints.
- You prefer Store or enterprise deployment policy over an app-owned updater.

Notes:

- MSIX packages are signed with SignTool or by the store pipeline.
- A Store/MSIX channel should normally own updates for that install channel. Do
  not mix an app-owned self-updater into a store-governed install without a clear
  policy reason.
- Windows Package Manager (`winget`) is another distribution channel. It uses
  manifests and points users to installer packages. It does not replace signing
  the installer or binary itself.

### Enterprise Or Private Trust

For internal apps, public trust may not be required.

Options include:

- Private enterprise CA plus Group Policy or MDM trust deployment.
- Microsoft Artifact Signing Private Trust.
- Intune, Configuration Manager, winget private/source workflows, or a private
  package feed.

This can be a strong route for corporate apps, but it only works inside the
managed trust boundary. It does not create public Windows publisher trust for
unmanaged users.

## Linux Options

Linux has no single OS-wide equivalent of macOS notarization or Windows public
Authenticode trust. Production trust depends on the chosen distribution channel.

### Direct Zip Plus Descriptor Signing

This is the closest fit for the current `desktop_updater` Linux flow.

Recommended release order:

1. Build the Linux Release bundle.
2. Create the update zip and `release.json`.
3. Sign `release.json` or a higher-level update index with a publisher key.
4. Publish the signature or Sigstore bundle next to the descriptor.
5. Make the app verify the descriptor signature against a pinned public key
   before trusting the artifact URL and SHA-256.
6. Run hosted validation.

Options:

- GPG or minisign signatures for `release.json`.
- Sigstore `cosign sign-blob` for `release.json` or the zip artifact.
- A TUF-style metadata layer if you need rollback, freeze, and mirror compromise
  protections.

Current `desktop_updater` validates artifact length and SHA-256 from
`release.json`. For production authenticity, add descriptor signing in the app or
ship through a native package channel until first-class descriptor signatures are
implemented.

Possible future config shape:

```yaml
linux:
  signature:
    enabled: true
    provider: cosign
    bundle: release.json.sigstore.json
```

That YAML is a design direction, not currently supported config.

### deb And apt Repository

Good fit when:

- Your users are on Debian, Ubuntu, or derivatives.
- You want OS-native install, update, downgrade, dependency, and policy behavior.
- You can maintain an apt repository and key rotation process.

Notes:

- APT verifies repository Release metadata signatures. Current APT versions
  refuse unsigned repositories by default.
- Repository signing protects the archive metadata and package checksums. It is
  different from per-package signatures.
- If users cannot acquire your repository key securely, the trust chain is weak.

### rpm, yum, dnf, And zypper Repositories

Good fit when:

- Your users are on Fedora, RHEL, AlmaLinux, Rocky Linux, openSUSE, SUSE, or
  derivatives.
- You want native enterprise Linux package policy.

Recommended production shape:

- Build `.rpm` packages.
- Sign packages with GPG.
- Sign repository metadata where supported by your repository tooling.
- Publish install instructions that pin the correct repository key.
- Test on each supported distro family and version.

### Flatpak

Good fit when:

- You want a cross-distro desktop package format.
- Your app works within Flatpak sandboxing and portal constraints.
- You want either Flathub distribution or a self-hosted Flatpak repository.

Notes:

- A Flatpak repository can be hosted on a web server.
- A `.flatpakrepo` file includes the repository URL and GPG key needed to add
  the repository.
- Static deltas can reduce update download size.
- If you use Flathub, follow Flathub review and policy requirements. If you
  self-host, you own key distribution and repository availability.

### Snap

Good fit when:

- Ubuntu is a primary target.
- You want Snap Store channels and automatic update behavior.
- Your app works within snap confinement expectations.

Notes:

- Snap Store distribution is governed by Canonical account, store, review, and
  policy requirements.
- Check Canonical's current store terms and country/payment availability before
  relying on it for production distribution.
- A snap channel should normally own updates for snap installs. Avoid layering a
  direct zip self-updater inside a snap unless you have a clear confinement and
  policy model.

### AppImage

Good fit when:

- You need a portable, single-file Linux artifact.
- Your users are comfortable downloading and running an app outside a package
  manager.

Notes:

- AppImage does not create a universal OS trust decision by itself.
- Add an external signature, checksum, or Sigstore bundle and document how users
  or your app verify it.
- Desktop integration, sandboxing, update policy, and rollback are app-owned.

## Country, Sanctions, And Availability Notes

Country restrictions are mostly provider-specific. Treat these as launch
checkpoints, not one-time setup facts.

### Windows Signing

- Microsoft Artifact Signing Public Trust has explicit current availability:
  organizations in the USA, Canada, EU, and UK; individual developers in the USA
  and Canada. Private Trust is not subject to that Public Trust country limit.
- Public CA code signing certificate issuance depends on the CA. Expect identity
  verification, business registry checks, payment checks, sanctions screening,
  and hardware-backed key custody or a compliant signing service.
- If your publisher entity is outside the supported countries for one provider,
  evaluate another public CA, Microsoft Private Trust for enterprise use, or a
  store/enterprise channel that matches your distribution model.

### Linux Channels

- Native package stores and repositories have their own policies. Flathub,
  Snapcraft, distro repositories, package hosting, payment processors, and CI
  providers can each have different country and account restrictions.
- For self-hosted deb/rpm/Flatpak repositories, you still need to check hosting,
  CDN, payment, export-control, and sanctions rules for your company and users.
- For open-source or free public software, some hosted services may allow broader
  access than paid services, but that is provider-specific and can change.

### Hosting, CI, And Export Controls

- GitHub states that GitHub.com, GitHub Enterprise Server, and uploaded content
  may be subject to trade control rules including the U.S. EAR.
- GitHub.com does not provide country-based repository access controls for ITAR
  data.
- GitHub Enterprise Server currently cannot be sold, exported, or re-exported to
  EAR Country Group E:1 destinations or Crimea, Donetsk, and Luhansk; GitHub's
  current list includes Cuba, Iran, North Korea, Syria, Russia, and Belarus, and
  the list can change.
- OFAC sanctions programs can be comprehensive or selective and can use asset
  blocking and trade restrictions. Always check the current official sanctions
  list for the countries, entities, and users involved.

## Diagnostics And Support Logs

Native helper diagnostics are support evidence, not a trust layer. They can help
you understand where a Windows or Linux update failed after the Flutter process
exited, such as backup, copy, rollback, cleanup, or relaunch, but they do not
replace Authenticode, descriptor signing, repository signing, or hosted
validation.

Keep diagnostics app-owned:

- Default package behavior writes no files and uploads no logs.
- Use in-memory problem reports for ordinary UI support flows.
- Add `UpdateDiagnosticsRecorder(sink: ...)` only when your app chooses a
  durable Dart lifecycle log path and retention policy.
- Add `diagnosticsLogPath` plus an app-owned recovery store only when support
  needs post-exit helper evidence.

Recommended support wording:

```text
Open Settings > Updates > Copy update report. If the app cannot open that
screen, attach the update log from the location your app shows in Settings.
```

Avoid documenting a package-level Windows or Linux log path. If your app chooses
one, show it in your own support UI and ask the user before sharing it.

## What desktop_updater Should Own

Current behavior:

- Build, package, manifest, upload, and hosted validation.
- macOS Developer ID notarization when explicitly enabled.
- Windows and Linux release mechanics with artifact length and SHA-256
  verification.

Recommended app-owned gates before `release publish`:

- Windows Authenticode signing and `signtool verify`.
- Linux descriptor signing or native package repository signing.
- CI policy that fails if the production trust gate is missing.
- Hosted `release validate` after upload.

Possible future `desktop_updater` UX:

```yaml
windows:
  authenticode:
    enabled: true
    subjectName: "Example Publisher"
    timestampUrl: https://timestamp.example.com
    digestAlgorithm: SHA256

linux:
  signature:
    enabled: true
    provider: cosign
    identity: https://github.com/example/app/.github/workflows/release.yml
```

That YAML is not currently supported. Keep signing secrets out of
`desktop_updater.yaml`; store credentials in the OS certificate store, hardware
token, cloud signing service, keychain, CI secret store, or provider-native
identity system.

## References

- Microsoft Artifact Signing overview:
  <https://learn.microsoft.com/en-us/azure/artifact-signing/overview>
- Microsoft Artifact Signing quickstart and current country/region availability:
  <https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart>
- Microsoft SignTool reference:
  <https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool>
- Microsoft MSIX SignTool package signing:
  <https://learn.microsoft.com/en-us/windows/msix/package/sign-app-package-using-signtool>
- Windows Package Manager package submission:
  <https://learn.microsoft.com/en-us/windows/package-manager/package/>
- CA/Browser Forum Code Signing Baseline Requirements:
  <https://cabforum.org/working-groups/code-signing/requirements/>
- Ubuntu `apt-secure` manpage:
  <https://manpages.ubuntu.com/manpages/noble/man8/apt-secure.8.html>
- Flatpak repository hosting:
  <https://flatpak-docs.readthedocs.io/en/latest/hosting-a-repository.html>
- Snapcraft release documentation:
  <https://snapcraft.io/docs/releasing-your-app>
- Snapcraft channel documentation:
  <https://snapcraft.io/docs/channels>
- Sigstore Cosign signing blobs:
  <https://docs.sigstore.dev/cosign/signing/signing_with_blobs/>
- The Update Framework specification:
  <https://theupdateframework.github.io/specification/latest/>
- GitHub trade controls:
  <https://docs.github.com/en/site-policy/other-site-policies/github-and-trade-controls>
- OFAC sanctions programs and country information:
  <https://ofac.treasury.gov/sanctions-programs-and-country-information>
