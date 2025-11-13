# XcodeGen Project Management

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project file from a declarative YAML specification.

## Why XcodeGen?

- **Version control friendly**: YAML configuration instead of XML pbxproj
- **No merge conflicts**: Project file is generated, not manually edited
- **Deterministic**: Same configuration always produces same project
- **Maintainable**: Centralized configuration in `project.yml`

## Getting Started

### Installation

XcodeGen is already installed via Homebrew (version 2.44.1).

### Project Structure

The Xcode project is **generated** from the following:

- `ios/project.yml` - Main XcodeGen configuration
- `ios/VoiceCode/Info.plist` - App Info.plist
- `ios/VoiceCode/VoiceCode.entitlements` - App entitlements
- `ios/VoiceCodeShareExtension/Info.plist` - Share extension Info.plist
- `ios/VoiceCodeShareExtension/VoiceCodeShareExtension.entitlements` - Share extension entitlements

The `ios/VoiceCode.xcodeproj` directory is **generated** and should NOT be manually edited.

## Usage

### Automatic Generation

All Makefile targets automatically generate the project before building:

```bash
make build        # Auto-generates project, then builds
make test         # Auto-generates project, then tests
make test-class   # Auto-generates project, then runs specific tests
```

### Manual Generation

To regenerate the project manually:

```bash
make generate-project
```

Or directly:

```bash
cd ios && xcodegen generate
```

## Making Project Changes

### Adding/Removing Files

Files are automatically discovered in the `sources` paths defined in `project.yml`. No need to manually add files to the project.

**Main app source files**: Any `.swift` file in `ios/VoiceCode/` (excluding `.md` files)

**Share extension files**: Any file in `ios/VoiceCodeShareExtension/`

**Test files**: Any file in `ios/VoiceCodeTests/` or `ios/VoiceCodeUITests/`

### Adding Build Settings

Edit `ios/project.yml` and add settings under the appropriate target:

```yaml
targets:
  VoiceCode:
    settings:
      base:
        SWIFT_VERSION: 6.0
      configs:
        Debug:
          SWIFT_OPTIMIZATION_LEVEL: -Onone
        Release:
          SWIFT_OPTIMIZATION_LEVEL: -O
```

### Adding Dependencies

To add target dependencies or frameworks, edit `ios/project.yml`:

```yaml
targets:
  VoiceCode:
    dependencies:
      - target: VoiceCodeShareExtension
        embed: true
```

### Adding Resources

Resources are explicitly listed in `project.yml`:

```yaml
targets:
  VoiceCode:
    resources:
      - VoiceCode/Assets.xcassets
      - VoiceCode/VoiceCode.xcdatamodeld
      - VoiceCode/PrivacyInfo.xcprivacy
```

### Changing Info.plist Properties

You can define Info.plist properties directly in `project.yml`:

```yaml
targets:
  VoiceCode:
    info:
      path: VoiceCode/Info.plist
      properties:
        CFBundleDisplayName: Untethered
        UIBackgroundModes:
          - audio
```

Or edit the physical `ios/VoiceCode/Info.plist` file directly.

### Version and Build Number Management

**IMPORTANT:** Version and build numbers are managed in `ios/project.yml`, NOT in Info.plist files.

To change the version or build number, edit `ios/project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"      # App version (e.g., 1.0, 1.1, 2.0)
    CURRENT_PROJECT_VERSION: "43" # Build number (must increment for each upload)
```

The Info.plist files use build setting variables:
- `CFBundleShortVersionString: $(MARKETING_VERSION)`
- `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`

**Do NOT:**
- Manually edit version numbers in Info.plist files (they will be overridden)
- Use `make bump-build` (agvtool) - it doesn't work with XcodeGen's approach

**To increment build for TestFlight:**
1. Edit `CURRENT_PROJECT_VERSION` in `ios/project.yml`
2. Increment the number (e.g., "43" → "44")
3. Run `make deploy-testflight`

## Git Workflow

The `.xcodeproj` directory is **generated** and **ignored by git**. Only these files are tracked:

- `ios/project.yml` - XcodeGen configuration
- `ios/VoiceCode/Info.plist` - Info.plist files
- `ios/VoiceCode/VoiceCode.entitlements` - Entitlements files
- `ios/VoiceCodeShareExtension/Info.plist`
- `ios/VoiceCodeShareExtension/VoiceCodeShareExtension.entitlements`

When cloning the repository:

1. Clone the repo
2. Run `make generate-project` (or any make target, which auto-generates)
3. The Xcode project is created locally

## Targets

The project has four targets:

1. **VoiceCode** - Main iOS app (iOS 18.5+)
2. **VoiceCodeShareExtension** - Share extension for file uploads
3. **VoiceCodeTests** - Unit tests
4. **VoiceCodeUITests** - UI tests

## Configuration Details

### Main App (VoiceCode)

- Platform: iOS 18.5+
- Bundle ID: `dev.910labs.voice-code`
- Development Team: REDACTED_TEAM_ID
- Signing: Automatic
- Embedded extension: VoiceCodeShareExtension

### Share Extension (VoiceCodeShareExtension)

- Platform: iOS 18.5+
- Bundle ID: `dev.910labs.voice-code.VoiceCodeShareExtension`
- Extension point: `com.apple.share-services`
- Activation: Single file sharing

### Test Targets

Both test targets use auto-generated Info.plist files via `GENERATE_INFOPLIST_FILE = YES`.

## Troubleshooting

### Project file missing

Run `make generate-project` to create it.

### Build settings not applying

1. Edit `ios/project.yml`
2. Run `make generate-project`
3. Rebuild

### New files not showing up

Files are auto-discovered. Just run `make generate-project` to refresh the project.

### Xcode complains about missing project

The `.xcodeproj` is generated. Run `make generate-project` before opening Xcode.

## References

- [XcodeGen Documentation](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- [XcodeGen Examples](https://github.com/yonaskolb/XcodeGen/tree/master/Examples)
