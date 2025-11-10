# Share Extension Setup Instructions

This document describes how to manually add the Share Extension target to the Xcode project.

## Prerequisites

All source files have been created in `ios/VoiceCodeShareExtension/`:
- `ShareViewController.swift` - Main extension logic
- `Info.plist` - Extension configuration
- `VoiceCodeShareExtension.entitlements` - App Group entitlements
- `Base.lproj/MainInterface.storyboard` - UI storyboard

The main app's entitlements have been updated with App Group capability.

## Steps to Add Share Extension Target

### 1. Open Xcode Project
```bash
cd ios
open VoiceCode.xcodeproj
```

### 2. Add New Target

1. In Xcode, select the VoiceCode project in the navigator
2. Click the **+** button at the bottom of the targets list
3. Select **iOS** → **Share Extension**
4. Click **Next**

### 3. Configure Target Settings

**Product Name:** `VoiceCodeShareExtension`
**Team:** Select your development team
**Organization Identifier:** `com.travisbrown`
**Bundle Identifier:** `com.travisbrown.VoiceCode.VoiceCodeShareExtension`
**Language:** Swift

Click **Finish**. When prompted about activating the scheme, click **Activate**.

### 4. Replace Default Files

Xcode creates default files. Replace them with our prepared files:

1. **Delete** the auto-generated files:
   - `ShareViewController.swift` (in target folder)
   - `Info.plist` (in target folder)
   - `MainInterface.storyboard` (in target folder)

2. **Add** our prepared files to the target:
   - Select the `VoiceCodeShareExtension` group in navigator
   - Right-click → **Add Files to "VoiceCode"...**
   - Navigate to `ios/VoiceCodeShareExtension/`
   - Select all files (ShareViewController.swift, Info.plist, Base.lproj folder, VoiceCodeShareExtension.entitlements)
   - **Important:** Check "Copy items if needed" is UNCHECKED (files are already in correct location)
   - Under "Add to targets", check **VoiceCodeShareExtension** ONLY
   - Click **Add**

### 5. Configure Target Settings

Select the **VoiceCodeShareExtension** target and configure:

#### General Tab
- **Deployment Info**
  - iOS Deployment Target: Match main app (iOS 17.0 or later)
- **Frameworks and Libraries**
  - Should be empty (extension is self-contained)

#### Signing & Capabilities Tab
1. Select your development team
2. The App Groups capability should already be present (from entitlements file)
   - If not present, click **+ Capability** → **App Groups**
   - Add: `group.com.travisbrown.untethered`

#### Build Settings Tab
- Search for "Bundle Identifier"
  - Should be: `com.travisbrown.VoiceCode.VoiceCodeShareExtension`
- Search for "Code Signing Entitlements"
  - Set to: `VoiceCodeShareExtension/VoiceCodeShareExtension.entitlements`

### 6. Configure Main App Target

Select the **VoiceCode** target:

#### Signing & Capabilities Tab
- The App Groups capability should already be present (already updated in entitlements)
- Verify it includes: `group.com.travisbrown.untethered`

### 7. Build and Test

1. Select the **VoiceCodeShareExtension** scheme
2. Build (⌘B) to verify no compilation errors
3. Select the **VoiceCode** scheme
4. Build (⌘B) to verify main app includes extension

### 8. Test Share Extension

1. Run the main VoiceCode app on a device or simulator (⌘R)
2. Open Safari or Files app
3. Select a file and tap the Share button
4. Look for "Untethered" in the share sheet
5. Tap it - the extension should save the file to App Group storage
6. You should see "Saving file..." with a spinner

## Verification Checklist

- [ ] VoiceCodeShareExtension target builds without errors
- [ ] VoiceCode app builds and includes extension
- [ ] Share sheet shows "Untethered" option when sharing files
- [ ] Extension saves files to App Group container
- [ ] No runtime crashes when using extension

## Troubleshooting

### Extension doesn't appear in share sheet
- Verify App Groups capability is enabled for BOTH targets
- Verify both targets use the same App Group identifier: `group.com.travisbrown.untethered`
- Clean build folder (Shift+⌘K) and rebuild
- Restart device/simulator

### Build errors about missing files
- Verify all files are added to VoiceCodeShareExtension target membership
- Check file paths in Build Phases → Compile Sources

### Runtime crashes
- Check that Info.plist is correctly configured
- Verify NSExtensionMainStoryboard points to "MainInterface"
- Check Console app for detailed error messages

## Next Steps

Once the Share Extension target is successfully added and tested:
1. Proceed to resources-3029: Implement ResourcesManager for processing pending uploads
2. The main app will need to check the App Group container and upload files to backend
