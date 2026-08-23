# Desktop stable release secret inventory

Candidate builds are unsigned and require no secrets. A public stable release is
blocked unless the release environment provides every applicable signing value.
Values must stay in GitHub environment secrets and must never be committed.

- `DESKTOP_ED25519_PRIVATE_KEY_B64` - signs the canonical release manifest.
- `DESKTOP_ED25519_KEY_ID` - public identifier written into the manifest.
- `DESKTOP_ED25519_PUBLIC_KEY_B64` - public raw Ed25519 key embedded in stable agents.
- `WINDOWS_CODESIGN_CERT_PFX_B64` - Authenticode certificate bundle.
- `WINDOWS_CODESIGN_CERT_PASSWORD` - certificate import password.
- `WINDOWS_CODESIGN_SUBJECT` - expected public certificate subject for update verification.
- `APPLE_INSTALLER_CERT_P12_B64` - Developer ID Installer certificate bundle.
- `APPLE_INSTALLER_CERT_PASSWORD` - certificate import password.
- `APPLE_APPLICATION_CERT_P12_B64` - Developer ID Application certificate bundle.
- `APPLE_APPLICATION_CERT_PASSWORD` - application certificate import password.
- `APPLE_APPLICATION_SIGNING_IDENTITY` - Developer ID Application identity.
- `APPLE_SIGNING_IDENTITY` - Developer ID Installer identity.
- `APPLE_ID` - notarization account.
- `APPLE_TEAM_ID` - Apple developer team.
- `APPLE_APP_SPECIFIC_PASSWORD` - notarization password.
- `LINUX_PACKAGE_SIGNING_PRIVATE_KEY_B64` - package repository signing key.
- `LINUX_PACKAGE_SIGNING_KEY_ID` - public signing key identifier.

The corresponding Ed25519 public key and platform signer identities are public
release metadata, not secrets. Pin them in the distributed agent before stable
updates are enabled.
