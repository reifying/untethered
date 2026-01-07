# XcodeGen Project Management

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from a YAML specification. The `.xcodeproj` is generated and not checked into version control.

## Setup

```bash
# Install XcodeGen
brew install xcodegen

# Generate the project
cd ios && xcodegen generate
```

## Why XcodeGen?

- **No merge conflicts** — YAML config instead of XML pbxproj
- **Deterministic** — Same config always produces same project
- **Simple diffs** — Easy to review project changes in PRs

## Usage

### Generate Project

```bash
# From ios/ directory
xcodegen generate

# Or from project root via Makefile
make generate-project
```

All Makefile build targets auto-generate the project before building.

### Project Structure

Files tracked in git:
- `project.yml` — XcodeGen configuration
- `VoiceCode/Info.plist` — App Info.plist
- `VoiceCode/VoiceCode.entitlements` — App entitlements

Generated (gitignored):
- `VoiceCode.xcodeproj/`

### Adding Files

Source files are auto-discovered from paths in `project.yml`. Just add files to the appropriate directory and regenerate:

```bash
xcodegen generate
```

### Version Numbers

Version and build numbers are in `project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
```

Do not edit version numbers in Info.plist files directly.

## Targets

| Target | Platform | Description |
|--------|----------|-------------|
| VoiceCode | iOS 18.5+ | Main app |
| VoiceCodeMac | macOS 15.0+ | macOS app |
| VoiceCodeShareExtension | iOS 18.5+ | Share extension |
| VoiceCodeTests | iOS | Unit tests |
| VoiceCodeUITests | iOS | UI tests |
| VoiceCodeMacTests | macOS | macOS tests |

## Troubleshooting

**Project file missing:** Run `xcodegen generate`

**New files not appearing:** Run `xcodegen generate` to refresh

**Build settings not applying:** Edit `project.yml`, then regenerate

## References

- [XcodeGen Documentation](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
