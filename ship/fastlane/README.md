# ship/fastlane — the Mac-less release path

`.github/workflows/release-ios.yml` runs these lanes on a GitHub `macos-latest` runner. There is no
Mac in this project and none is needed: the runner creates the signing certificate and the App Store
provisioning profile from an App Store Connect API key, archives `ship/ios`, exports the IPA,
uploads it, and pushes metadata and both screenshot sets.

| lane | what it does |
|---|---|
| `create_app` | creates the App Store Connect app record (idempotent) |
| `signing` | `cert` + `sigh` on the runner; writes `ship/build/signing.env` |
| `build` | pins manual signing, sets the build number, `gym` → `ship/build/ScrollAnytime.ipa` |
| `upload` | binary only |
| `metadata` | listing text + both screenshot sets |
| `submit` | submits to App Review — held behind a workflow input |

Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (base64 of the `.p8`). App Manager role.

`ship/mac-run.sh` still works on a real Mac and is now optional.
