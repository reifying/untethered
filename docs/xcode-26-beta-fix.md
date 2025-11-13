# Fixing Xcode 26.x Beta Archive Issues

## Problem

When running `make deploy-testflight` or `make archive`, you encounter this error:

```
xcodebuild: error: Found no destinations for the scheme 'VoiceCode' and action archive.

Ineligible destinations for the "VoiceCode" scheme:
    { platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder,
      name:Any iOS Device, error:iOS 26.1 is not installed. Please download and
      install the platform from Xcode > Settings > Components. }
```

## Root Cause

Xcode 26.x is a beta/pre-release version with a platform validation bug. Even though:
- The iOS SDK is installed (verified with `xcodebuild -showsdks` showing iOS 26.1)
- The platform exists at `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/`
- Normal builds and tests work fine

...Xcode incorrectly reports the iOS platform as "not installed" when archiving.

## Solution

**Option 1: Install iOS Platform via Xcode GUI (Recommended)**

1. Open Xcode.app
2. Go to **Settings** > **Platforms** (or **Components** in some versions)
3. Look for **iOS** in the list
4. Click **Download** or **Install** next to iOS 26.1
5. Wait for installation to complete
6. Try `make archive` again

**Option 2: Downgrade to Stable Xcode (If Possible)**

If you have Xcode 15.x or 16.x available:

```bash
sudo xcode-select --switch /Applications/Xcode-15.4.app/Contents/Developer
make archive
```

**Option 3: Use Physical Device Workaround**

If you have an iPhone or iPad connected via USB:

1. Connect device and unlock it
2. Trust computer if prompted
3. Modify `scripts/publish-testflight.sh` to use device destination:
   ```bash
   DEVICE_ID=$(xcrun xct race list devices | grep "iPhone" | grep "connected" | ...)
   xcodebuild archive ... -destination "id=$DEVICE_ID"
   ```

This typically works because device destinations don't trigger the same validation bug.

## Workarounds Attempted (Didn't Work)

- ✗ Using `-sdk iphoneos` without `-destination`
- ✗ Using `-destination 'generic/platform=iOS'`
- ✗ Setting `DVTDisableValidateGenericDeviceDestinations=1`
- ✗ Setting `IDESkipGenericPlatformDestinationVerification=1`
- ✗ Using `-UseModernBuildSystem=NO`
- ✗ Using `-skipPackagePluginValidation` and `-skipMacroValidation`
- ✗ Building with `-target` instead of `-scheme`
- ✗ Running `xcodebuild -runFirstLaunch`
- ✗ Updating scheme `LastUpgradeVersion`

All fail with the same "Found no destinations" error.

## Verification

After fixing, verify the platform is recognized:

```bash
make show-destinations
```

Should show available destinations without errors.

## Related Commands

```bash
# Check Xcode version
xcodebuild -version

# List installed SDKs
xcodebuild -showsdks

# Check SDK info
make check-sdk

# Show available destinations
make show-destinations
```
