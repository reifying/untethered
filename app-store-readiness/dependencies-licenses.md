# Dependencies and License Compliance Assessment

**Generated**: 2025-11-08
**Project**: voice-code (Untethered)
**Version**: 1.0 (Build 18)

## Executive Summary

**Overall Status**: COMPLIANT

The voice-code project demonstrates excellent App Store compliance with minimal third-party dependencies and exclusive use of permissive open-source licenses. The app relies primarily on Apple's native frameworks with a lightweight Clojure backend using well-established, permissive libraries.

**Key Findings**:
- No proprietary third-party SDKs or frameworks
- All dependencies use App Store-compatible licenses (Apache 2.0, MIT, EPL 1.0)
- No binary frameworks or problematic dependencies
- iOS deployment target (18.5) is aggressive but valid
- Native Apple frameworks require no attribution

## iOS Application Dependencies

### 1. Apple Native Frameworks (First-Party)

All iOS dependencies are Apple's native frameworks, which require no license attribution and are fully App Store compliant.

| Framework | Purpose | License | Attribution Required |
|-----------|---------|---------|---------------------|
| SwiftUI | UI framework | Apple EULA | No |
| Speech | Voice recognition (SFSpeechRecognizer) | Apple EULA | No |
| AVFoundation | Audio recording/playback | Apple EULA | No |
| CoreData | Local persistence | Apple EULA | No |
| Combine | Reactive programming | Apple EULA | No |
| Foundation | Core utilities | Apple EULA | No |
| UIKit | iOS UI components | Apple EULA | No |
| UserNotifications | Push notifications | Apple EULA | No |
| OSLog | System logging | Apple EULA | No |
| Intents | App extensions/Siri | Apple EULA | No |

**Compliance Notes**:
- All Apple frameworks are covered under the Apple SDK License Agreement
- No attribution or license notices required in app
- Privacy disclosures required in Info.plist (already implemented):
  - `NSMicrophoneUsageDescription`: "Untethered needs microphone access for voice input to control Claude."
  - `NSSpeechRecognitionUsageDescription`: "Untethered needs speech recognition to transcribe your voice commands."
- Background audio mode enabled for voice features

### 2. Third-Party iOS Dependencies

**Status**: NONE

The iOS app uses no third-party dependencies. No CocoaPods, Swift Package Manager, or Carthage dependencies detected.

## Backend (Clojure) Dependencies

### Core Dependencies

| Dependency | Version | License | App Store Compatible | Attribution Required |
|------------|---------|---------|---------------------|---------------------|
| org.clojure/clojure | 1.12.3 | EPL 1.0 | Yes | Yes |
| org.clojure/core.async | 1.7.701 | EPL 1.0 | Yes | Yes |
| org.clojure/tools.logging | 1.3.0 | EPL 1.0 | Yes | Yes |
| http-kit/http-kit | 2.8.1 | Apache 2.0 | Yes | Yes |
| cheshire/cheshire | 6.1.0 | MIT | Yes | Yes |
| com.taoensso/timbre | 6.6.1 | EPL 1.0 | Yes | Yes |

### Transitive Dependencies (Notable)

| Dependency | License | Notes |
|------------|---------|-------|
| com.fasterxml.jackson.core/jackson-core | Apache 2.0 | Industry-standard JSON processor |
| com.fasterxml.jackson.dataformat/jackson-dataformat-smile | Apache 2.0 | Binary JSON format |
| com.fasterxml.jackson.dataformat/jackson-dataformat-cbor | Apache 2.0 | Compact binary format |
| org.ow2.asm/asm | BSD-3-Clause | Bytecode manipulation (via tools.analyzer) |
| org.clojure/tools.analyzer.jvm | EPL 1.0 | Static code analysis |
| org.clojure/tools.reader | EPL 1.0 | EDN/Clojure parser |

## License Compatibility Analysis

### Eclipse Public License (EPL) 1.0
- **Used by**: Clojure, core.async, tools.logging, timbre, and most Clojure ecosystem libraries
- **Type**: Weak copyleft (file-level, not project-level)
- **App Store Compatible**: YES
- **Commercial Use**: Permitted
- **Attribution**: Required (copyright notice and license text)
- **Source Disclosure**: Only for EPL-licensed files if modified
- **Notes**: EPL is explicitly compatible with commercial distribution. Does not require releasing your entire codebase.

### Apache License 2.0
- **Used by**: http-kit, Jackson libraries
- **Type**: Permissive
- **App Store Compatible**: YES
- **Commercial Use**: Permitted
- **Attribution**: Required (NOTICE file if present, license text)
- **Patent Grant**: Yes (explicit patent protection)
- **Notes**: One of the most business-friendly open-source licenses

### MIT License
- **Used by**: Cheshire
- **Type**: Permissive
- **App Store Compatible**: YES
- **Commercial Use**: Permitted
- **Attribution**: Required (copyright notice)
- **Notes**: Minimal restrictions, maximum flexibility

### BSD-3-Clause
- **Used by**: ASM (transitive via tools.analyzer)
- **Type**: Permissive
- **App Store Compatible**: YES
- **Commercial Use**: Permitted
- **Attribution**: Required (copyright notice)

## SDK and API Version Compliance

### iOS Platform
- **Xcode Version**: 16.4
- **Swift Version**: 5.0
- **iOS Deployment Target**: 18.5
- **SDK**: iOS 18.5

**Analysis**:
- **CAUTION**: iOS 18.5 deployment target is very aggressive
  - iOS 18 was released September 2024
  - iOS 18.5 would be a point release (likely 2025)
  - This severely limits potential user base to newest devices only
- **Recommendation**: Consider lowering to iOS 17.0 or 16.0 for broader compatibility
  - Current implementation uses no iOS 18-specific APIs
  - SwiftUI, Speech, and AVFoundation APIs used are available on iOS 15+
- **App Store Requirement**: As of April 2025, apps must be built with iOS 18 SDK
  - Project complies (using Xcode 16.4)
  - Deployment target can be lower (e.g., iOS 16) while building with iOS 18 SDK

### Deprecated API Usage
- **Status**: NONE DETECTED
- No uses of `@available`, `@API_DEPRECATED`, or `#available` checks found
- All Apple framework APIs used are current and supported

## Privacy and Data Collection

### Speech Framework (SFSpeechRecognizer)
- **Data Processing**: Voice data sent to Apple servers OR processed on-device (iOS 13+)
- **User Notification**: System automatically shows Apple's privacy notice on first use
- **Info.plist Disclosure**: Implemented correctly
- **Attribution**: Not required (covered under Apple SDK license)

### Background Audio Mode
- **Declared**: Yes (`UIBackgroundModes: audio`)
- **Purpose**: Voice input/output while app is backgrounded
- **Compliance**: Requires actual audio functionality (implemented via voice features)

## Binary Frameworks and Supply Chain Security

### Status: CLEAN

- **No binary frameworks** (.framework files) detected
- **No pre-compiled dependencies** (all source-based)
- **All dependencies from trusted sources**:
  - Apple frameworks: Official Apple SDK
  - Clojure libraries: Maven Central (org.clojure namespace)
  - Third-party Clojure: Reputable maintainers (http-kit, cheshire, timbre)

### Supply Chain Verification
- **Backend dependencies**: Managed via `deps.edn` (Clojure CLI tools)
- **Dependency resolution**: Maven Central (signed artifacts)
- **iOS dependencies**: None (all Apple-provided)
- **Version pinning**: All versions explicitly specified (good practice)

## Required Attributions and Credits

### Open Source Acknowledgments File

Create an "Open Source Licenses" or "Acknowledgments" section in your app's Settings or About screen with the following content:

```
=== Open Source Software ===

This software uses the following open source components:

--- Clojure ---
Copyright (c) Rich Hickey. All rights reserved.
The use and distribution terms for this software are covered by the
Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)

--- http-kit ---
Copyright © 2012-2024 http-kit
Licensed under the Apache License 2.0
http://www.apache.org/licenses/LICENSE-2.0

--- Cheshire ---
Copyright (c) 2012-2024 Lee Hinman
Licensed under the MIT License
https://opensource.org/licenses/MIT

--- Timbre ---
Copyright © 2014-2025 Peter Taoussanis
Licensed under the Eclipse Public License 1.0
http://opensource.org/licenses/eclipse-1.0.php

--- Jackson JSON Processor ---
Copyright (c) 2007- Tatu Saloranta and other contributors
Licensed under the Apache License 2.0
http://www.apache.org/licenses/LICENSE-2.0
```

### License Text Files

Store complete license texts in your repository:
- `/app-store-readiness/licenses/EPL-1.0.txt`
- `/app-store-readiness/licenses/APACHE-2.0.txt`
- `/app-store-readiness/licenses/MIT.txt`
- `/app-store-readiness/licenses/BSD-3-Clause.txt`

## Recommendations

### Critical
1. **Review iOS Deployment Target**: Consider lowering from 18.5 to 16.0 or 17.0
   - Current implementation has no iOS 18-specific dependencies
   - Would dramatically increase addressable market
   - Can still build with iOS 18 SDK (required as of April 2025)

### High Priority
2. **Add Open Source Credits Screen**: Implement in-app acknowledgments section
   - Required by EPL, Apache 2.0, MIT, and BSD licenses
   - Demonstrates good open-source citizenship
   - Can be in Settings > About > Open Source Licenses

3. **Create LICENSE.txt**: Add to app bundle and repository
   - Include all required license texts
   - Simplifies compliance verification

### Medium Priority
4. **Document Backend Dependencies**: For transparency and maintenance
   - Consider adding `clojure -X:deps tree` output to docs
   - Helps with security audits and updates

5. **Encryption Export Compliance**: Already declared correctly
   - `ITSAppUsesNonExemptEncryption: false` in Info.plist
   - WebSocket connection uses standard HTTPS (no custom crypto)
   - Correct for App Store submission

### Low Priority
6. **Dependency Update Policy**: Establish regular update schedule
   - Check for security updates monthly
   - Review breaking changes before updating
   - Pin versions in production (already doing this)

## App Store Review Checklist

- [x] All dependencies use App Store-compatible licenses
- [x] No GPL or AGPL dependencies (copyleft licenses)
- [x] Privacy disclosures in Info.plist complete
- [x] No binary frameworks from untrusted sources
- [x] Encryption export compliance declared
- [x] Background modes justified by functionality
- [ ] Open source acknowledgments screen implemented
- [ ] License texts included in app bundle
- [ ] Consider broader iOS version support (18.5 → 16.0+)

## Security Considerations

### Known Vulnerabilities
- **Status**: No known vulnerabilities in listed dependencies
- **Last Checked**: 2025-11-08
- **Recommendation**: Run periodic security scans via GitHub Dependabot or similar

### WebSocket Security
- **Implementation**: Native URLSessionWebSocketTask (Apple provided)
- **Transport**: WSS (WebSocket Secure) over TLS
- **Authentication**: Custom session-based (backend controlled)
- **Data Validation**: JSON parsing via Cheshire (well-tested, mature library)

### Voice Data Privacy
- **Speech Recognition**: User must grant permission explicitly
- **Data Transmission**: Voice data may be sent to Apple (disclosed to user)
- **Local Processing**: Available on iOS 13+ (automatic when possible)
- **Retention**: No voice data stored by app (transcription only)

## Conclusion

The voice-code project demonstrates excellent dependency hygiene and App Store compliance:

**Strengths**:
- Minimal third-party dependencies (backend only)
- All permissive, commercially-friendly licenses
- No binary frameworks or proprietary SDKs
- Native Apple framework usage (optimal for performance and security)
- Proper privacy disclosures

**Action Items**:
1. Review and potentially lower iOS deployment target (18.5 → 16.0+)
2. Implement in-app open source acknowledgments screen
3. Include license text files in app bundle
4. Consider adding quarterly dependency update review to maintenance schedule

**Overall Assessment**: The project is well-positioned for App Store submission with minimal compliance risk. The primary concern is the aggressive iOS 18.5 deployment target, which should be reconsidered for market reach.

---

**Document Maintained By**: Development Team
**Next Review Date**: 2025-12-08 (quarterly)
**Contact**: dev@910labs.dev
