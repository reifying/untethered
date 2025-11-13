# TestFlight Deployment - VoiceCode

**Status**: ✅ Setup complete (2025-11-01)

**Latest build**: Version 0.1.0, Build 2
**Latest delivery UUID**: 27799f62-b78b-4626-b01c-add2e733b1bc

---

## Quick Reference

### Deploy to TestFlight (Recommended - Single Command)

**IMPORTANT**: This project uses XcodeGen. Version/build numbers are managed in `ios/project.yml`, not via `agvtool`.

```bash
# 1. Edit ios/project.yml - Increment CURRENT_PROJECT_VERSION (e.g., "43" → "44")
# 2. Deploy:
make deploy-testflight    # ⭐ Archive + Export + Upload (~2 min)
```

### Alternative: Step-by-Step

```bash
# 1. Edit ios/project.yml - Increment CURRENT_PROJECT_VERSION
# 2. Run:
make publish-testflight   # Archive + Export + Upload
```

### Advanced: Granular Control

```bash
# 1. Edit ios/project.yml - Increment CURRENT_PROJECT_VERSION
# 2. Run individual steps:
make archive              # 1. Create archive
make export-ipa           # 2. Export IPA from archive
make upload-testflight    # 3. Upload to TestFlight
```

---

## Configuration Details

### Team & Account

- **Team**: 910 Labs, LLC
- **Team ID**: REDACTED_TEAM_ID
- **Apple ID**: REDACTED_EMAIL
- **Bundle ID**: dev.910labs.voice-code
- **App Store Connect ID**: 6754674317

### Code Signing

- **Certificate**: Apple Distribution: 910 Labs, LLC (REDACTED_TEAM_ID)
  - Already installed in Keychain
  - Location: `~/.apple-certificates/distribution_910labs.*`

- **Provisioning Profile**: VoiceCode App Store
  - UUID: `REDACTED_PROVISIONING_UUID`
  - Type: App Store
  - Location: `~/Library/MobileDevice/Provisioning Profiles/REDACTED_PROVISIONING_UUID.mobileprovision`

### App Store Connect API

- **Key ID**: REDACTED_ASC_KEY_ID
- **Issuer ID**: REDACTED_ASC_ISSUER_ID
- **Role**: App Manager
- **Key file**: `~/.appstoreconnect/private_keys/AuthKey_REDACTED_ASC_KEY_ID.p8`

Environment variables are configured in `.envrc`:
```bash
export ASC_KEY_ID=REDACTED_ASC_KEY_ID
export ASC_ISSUER_ID=REDACTED_ASC_ISSUER_ID
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
```

---

## Version Management

### Current Version
- **Marketing Version**: 0.1.0 (Beta)
- **Build Number**: 1 (auto-incremented)

### Incrementing Versions

**With XcodeGen**, edit `ios/project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"      # App version (0.1.0, 1.0.0, etc.)
    CURRENT_PROJECT_VERSION: "44" # Build number (increment for each upload)
```

```bash
# Check what will be deployed
grep -A1 "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" ios/project.yml
```

### Version Strategy

- **Beta**: 0.x.y (e.g., 0.1.0, 0.2.0)
- **Production**: 1.x.y+ (e.g., 1.0.0, 1.1.0)
- **Build Number**: Auto-incremented for each TestFlight upload

---

## App Store Connect Workflow

### After Upload

1. **Wait for processing** (5-15 minutes)
   - Visit: https://appstoreconnect.apple.com/apps/6754674317/testflight
   - Build status: Processing → Missing Compliance → Ready to Submit

2. **Answer Export Compliance**
   - "Uses encryption?" → **Yes** (HTTPS)
   - "Algorithm type?" → **None of the above**
   - Reasoning: App uses iOS built-in encryption only

3. **Add to Internal Testing**
   - Create group: "Internal Testers"
   - Add testers by email
   - Assign build to group
   - Testers receive email invite

### First Time Setup Checklist

For new team members or new machines:

- [ ] Verify Distribution certificate installed: `security find-identity -v -p codesigning | grep Distribution`
- [ ] Verify provisioning profile exists: `ls ~/Library/MobileDevice/Provisioning\ Profiles/REDACTED_PROVISIONING_UUID.mobileprovision`
- [ ] Verify API key exists: `ls ~/.appstoreconnect/private_keys/AuthKey_REDACTED_ASC_KEY_ID.p8`
- [ ] Verify direnv working: `cd project && echo $ASC_KEY_ID` (should show key ID)
- [ ] Test archive: `make archive`
- [ ] Test export: `make export-ipa`

---

## Troubleshooting

### "No signing certificate found"

```bash
# Check certificate installation
security find-identity -v -p codesigning | grep -i distribution
# Should show: "Apple Distribution: 910 Labs, LLC (REDACTED_TEAM_ID)"
```

**Fix**: Certificate already exists for 910 Labs, reuse from hunt910 setup or contact team admin.

### "No provisioning profile found"

```bash
# Verify profile exists
ls -l ~/Library/MobileDevice/Provisioning\ Profiles/REDACTED_PROVISIONING_UUID.mobileprovision
```

**Fix**: Re-download from https://developer.apple.com/account/resources/profiles/list

### "API keys not configured"

```bash
# Check environment variables
echo "ASC_KEY_ID: ${ASC_KEY_ID}"
echo "ASC_ISSUER_ID: ${ASC_ISSUER_ID}"
echo "Key exists: $([ -f "$ASC_KEY_PATH" ] && echo yes || echo no)"
```

**Fix**:
- Ensure direnv is installed and allowed: `direnv allow .`
- Verify `.envrc` exists in project root
- Check API key file exists: `ls ~/.appstoreconnect/private_keys/AuthKey_REDACTED_ASC_KEY_ID.p8`

### "Build number already used"

```bash
# 1. Edit ios/project.yml and increment CURRENT_PROJECT_VERSION
# 2. Then retry upload
make upload-testflight
```

### Upload hangs or times out

**Fix**: Large uploads require stable connection. If it fails:
1. Retry: `make upload-testflight`
2. Or use Apple Transporter app:
   - Download: https://apps.apple.com/app/transporter/id1450874784
   - Open app, sign in
   - Drag `build/ipa/VoiceCode.ipa` to upload

---

## File Locations

| Item | Path |
|------|------|
| Archive | `build/archives/VoiceCode.xcarchive` |
| IPA | `build/ipa/VoiceCode.ipa` |
| Export Options | `build/ExportOptions.plist` (auto-generated) |
| Publish Script | `scripts/publish-testflight.sh` |
| Environment Config | `.envrc` |
| Info.plist | `ios/VoiceCode/Info.plist` |
| App Icons | `ios/VoiceCode/Assets.xcassets/AppIcon.appiconset/` |

---

## Build History

| Version | Build | Date | Notes | Delivery UUID |
|---------|-------|------|-------|---------------|
| 0.1.0 | 2 | 2025-11-01 | Updated app icon (wings variant) - First deploy-testflight test | 27799f62-b78b-4626-b01c-add2e733b1bc |
| 0.1.0 | 1 | 2025-11-01 | First TestFlight build - Automated deployment setup complete | f2e68c3d-c2d3-4b1c-b727-1c3886ba3538 |

---

## Reference: Setup Process (Completed)

**This section is for historical reference only. The setup is complete.**

### What Was Done (2025-11-01)

1. **Code Signing**
   - Reused existing Distribution certificate from hunt910 (same team)
   - Created new provisioning profile for `dev.910labs.voice-code`
   - Profile UUID: `REDACTED_PROVISIONING_UUID`

2. **API Authentication**
   - Reused existing App Store Connect API key (same team)
   - Configured `.envrc` with credentials
   - Key ID: `REDACTED_ASC_KEY_ID`

3. **App Icons**
   - Generated all required sizes from source image
   - Added to Assets.xcassets/AppIcon.appiconset
   - Added `CFBundleIconName` to Info.plist

4. **Bundle Identifier**
   - Updated from `NineTenLabs.VoiceCode` to `dev.910labs.voice-code`
   - Matches App Store Connect configuration

5. **Automation Scripts**
   - Created `scripts/publish-testflight.sh`
   - Added Makefile targets: archive, export-ipa, upload-testflight, publish-testflight, deploy-testflight
   - Configured environment variable sourcing in Makefile
   - **2025-11-13**: Migrated to XcodeGen - version/build managed in `ios/project.yml`

6. **First Build**
   - Version 0.1.0, Build 1
   - Successfully uploaded to TestFlight
   - Delivery UUID: f2e68c3d-c2d3-4b1c-b727-1c3886ba3538

---

## Additional Resources

- **App Store Connect**: https://appstoreconnect.apple.com
- **TestFlight**: https://appstoreconnect.apple.com/apps/6754674317/testflight
- **Developer Portal**: https://developer.apple.com/account
- **Transporter App**: https://apps.apple.com/app/transporter/id1450874784
- **Reference Setup** (hunt910): `../hunt910/specs/300-implementation/301-ios/301-003-deployment.md`
