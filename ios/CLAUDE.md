# iOS Development Notes

## Xcodegen

We use [xcodegen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project file from `project.yml`.

**Never edit `VoiceCode.xcodeproj/project.pbxproj` manually** - changes will be overwritten.

To regenerate the project after adding/removing files:

```bash
cd ios
xcodegen generate
```

The project file is gitignored since it's generated from `project.yml`.
