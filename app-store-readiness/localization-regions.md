# Localization & Regional Readiness Review

**App**: Untethered (Voice-Code)
**Review Date**: November 8, 2025
**Reviewer**: Analysis of iOS codebase and backend

## Executive Summary

The voice-code app has **MINIMAL** internationalization support currently. It is primarily designed for English-speaking markets with limited infrastructure for localization. Several areas need significant work before international deployment.

**Current State**: US/English-only
**Localization Readiness**: 25%
**Recommended Action**: Implement localization infrastructure before international release

---

## 1. Localization Infrastructure

### Current Status: ❌ NOT IMPLEMENTED

**Findings**:

- **No .xcstrings catalog**: The project has no String Catalog files for localization
- **No .lproj directories**: No language-specific resource bundles found
- **No Localizable.strings**: No traditional localization files present
- **Hardcoded strings throughout**: All UI strings are hardcoded in Swift views

**Evidence**:
```swift
// ConversationView.swift - All hardcoded strings
Text("Loading conversation...")
Text("No messages yet")
Text("Start a conversation to see messages here.")
Text("Voice Mode")
Text("Text Mode")
Text("Connected")
Text("Disconnected")
Text("Session locked - tap to unlock")
Text("Type your message...")

// SettingsView.swift - Hardcoded UI
Text("Server Configuration")
Text("Voice Selection")
Text("Audio Playback")
Text("Connection Test")
Text("Help")
Text("Tailscale Setup")
```

**Info.plist Analysis**:
- No `CFBundleDevelopmentRegion` specified (defaults to en-US)
- No `CFBundleLocalizations` array defined
- Privacy descriptions only in English:
  - `NSMicrophoneUsageDescription`: "Untethered needs microphone access for voice input to control Claude."
  - `NSSpeechRecognitionUsageDescription`: "Untethered needs speech recognition to transcribe your voice commands."

**Recommendations**:

1. **Create String Catalog** (`.xcstrings`)
   - Migrate all hardcoded strings to `NSLocalizedString()` or `String(localized:)`
   - Use Xcode's String Catalog for managing translations
   - Extract ~200+ user-facing strings from Views

2. **Add base localization keys**:
   ```swift
   Text("conversation.loading") // Instead of "Loading conversation..."
   Text("conversation.empty") // Instead of "No messages yet"
   ```

3. **Define supported localizations** in Info.plist:
   ```xml
   <key>CFBundleDevelopmentRegion</key>
   <string>en</string>
   <key>CFBundleLocalizations</key>
   <array>
       <string>en</string>
   </array>
   ```

4. **Effort estimate**: 2-3 weeks for full localization infrastructure

---

## 2. Voice & Speech Recognition

### Current Status: ⚠️ ENGLISH-ONLY

**Speech Recognition**:
```swift
// VoiceInputManager.swift:22
speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
```

**Hardcoded to US English**. No language selection or detection.

**Text-to-Speech (Voice Output)**:
```swift
// AppSettings.swift:66-70
.filter {
    let lang = $0.language.lowercased()
    return lang.hasPrefix("en-") || lang == "en"
}
```

**Only English voices are exposed** (en-US, en-GB, en-AU filtered), but multiple English dialects supported:
- US English
- British English
- Australian English
- Other `en-*` variants

**Voice Quality Tiers Available**:
- Premium voices (highest quality)
- Enhanced voices (good quality)
- Default voices (excluded from UI)

**Recommendations**:

1. **Add language preference setting**:
   ```swift
   @Published var selectedLanguage: String = "en-US"
   // Support: en-US, en-GB, es-ES, fr-FR, de-DE, ja-JP, zh-CN, etc.
   ```

2. **Dynamic speech recognizer initialization**:
   ```swift
   speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage))
   ```

3. **Expand voice filter** to selected language:
   ```swift
   .filter { $0.language.hasPrefix(selectedLanguagePrefix) }
   ```

4. **Regional dialect support**:
   - Spanish: es-ES (Spain), es-MX (Mexico), es-AR (Argentina)
   - Portuguese: pt-PT (Portugal), pt-BR (Brazil)
   - Chinese: zh-CN (Simplified), zh-TW (Traditional)

5. **Fallback handling** for unsupported languages

**Constraints**:
- SFSpeechRecognizer language availability varies by device region
- Premium voices may require download (noted in Settings UI)
- Speech recognition requires on-device language packs

---

## 3. Date, Time & Number Formatting

### Current Status: ⚠️ PARTIALLY LOCALE-AWARE

**Date Formatting**:
```swift
// ConversationView.swift:515-518
let dateFormatter = DateFormatter()
dateFormatter.dateStyle = .medium
dateFormatter.timeStyle = .short
exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
```

**Uses system locale** for date/time formatting (✅ Good)

```swift
// ConversationView.swift:735
Text(message.timestamp, style: .time)
```

**SwiftUI's automatic formatting** respects locale (✅ Good)

**Relative Time (Custom Implementation)**:
```swift
// ConversationView.swift:650-666
func relativeTimeString() -> String {
    let interval = now.timeIntervalSince(self)
    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    }
    // ...
}
```

**Hardcoded English strings** ("just now", "minutes ago", "hours ago") - ❌ Not localized

**ISO8601 for API/Backend**:
```swift
// Models/Command.swift:139
let formatter = ISO8601DateFormatter()
```

**Proper use** of ISO8601 for machine-readable timestamps (✅ Good)

**Recommendations**:

1. **Use RelativeDateTimeFormatter** for relative times:
   ```swift
   let formatter = RelativeDateTimeFormatter()
   formatter.unitsStyle = .full
   return formatter.localizedString(for: self, relativeTo: Date())
   ```

2. **Continue using DateFormatter** with locale awareness
3. **Avoid hardcoded pluralization** (English "minute" vs "minutes")
   - Use `.stringsdict` for plural rules in other languages
   - French: "il y a 1 minute" vs "il y a 2 minutes"
   - Russian has 3 plural forms
   - Arabic has 6 plural forms

**Number Formatting**:
No currency formatting detected (app doesn't handle pricing in UI currently).

Token counts use simple integer formatting:
```swift
// ConversationView.swift:615-620
private func formatTokenCount(_ count: Int) -> String {
    if count >= 1000 {
        let k = Double(count) / 1000.0
        return String(format: "%.1fK", k)
    }
    return "\(count)"
}
```

Works for all locales, but could use `NumberFormatter` for consistency.

---

## 4. Right-to-Left (RTL) Language Support

### Current Status: ❌ NOT TESTED

**Findings**:
- No RTL language testing detected (Arabic, Hebrew, Persian, Urdu)
- SwiftUI **automatically** mirrors layouts for RTL locales (✅ Built-in)
- Custom layouts may need RTL testing

**Potential RTL Issues**:

1. **HStack ordering** (SwiftUI auto-mirrors, should work)
2. **Icon meanings** may be culture-dependent
3. **Text alignment** in custom views
4. **ScrollView behavior** (SwiftUI handles)

**Recommendations**:

1. **Test with RTL preview**:
   ```swift
   #Preview {
       ConversationView(...)
           .environment(\.layoutDirection, .rightToLeft)
   }
   ```

2. **Verify specific components**:
   - Message bubbles (user vs assistant positioning)
   - Navigation flows
   - Button layouts in toolbars

3. **Icon audit**:
   - Directional icons (arrows) may need mirroring
   - Check `systemName` icons with `.leading`/`.trailing` traits

4. **Text input fields**:
   - Verify natural RTL text flow in TextField
   - Test mixed LTR/RTL content (URLs, code in Arabic text)

**SwiftUI RTL Support**: Generally excellent, but needs testing

---

## 5. Target Markets & Regions

### Current Status: 📍 US-FOCUSED

**Apparent Target Market**:
- **Primary**: United States (developer market)
- **Secondary**: English-speaking developers globally (UK, Canada, Australia)
- **Tailscale dependency** suggests technical users with VPN access

**Regional Considerations**:

**Network Requirements**:
- App requires **Tailscale VPN** or local network for backend connection
- Tailscale availability: Global, but...
  - May have restrictions in China (VPN regulations)
  - Corporate firewall issues in some regions

**Developer Tool Market**:
- AI coding assistants (Claude Code) strongest in:
  - North America (US, Canada)
  - Western Europe (UK, Germany, France)
  - Asia-Pacific (Japan, South Korea, Singapore, Australia)
  - India (growing developer market)

**Speech Recognition Availability**:
- `SFSpeechRecognizer` availability varies by region
- Not all languages available in all regions
- Requires checking `isAvailable` per locale

**Recommendations**:

1. **Phase 1 Markets** (English):
   - US, UK, Canada, Australia, Ireland, New Zealand

2. **Phase 2 Markets** (Major languages):
   - Spanish: Spain, Mexico, Latin America
   - French: France, Canada (Quebec)
   - German: Germany, Austria, Switzerland
   - Japanese: Japan
   - Portuguese: Brazil, Portugal

3. **Phase 3 Markets** (Emerging):
   - Chinese: China (with VPN considerations), Taiwan, Hong Kong
   - Korean: South Korea
   - Russian: Russia, Eastern Europe
   - Hindi: India

4. **Regional feature matrix** documentation needed

---

## 6. Currency & Pricing

### Current Status: ✅ NO CURRENCY HANDLING

**Findings**:
- App does **not display pricing** to end users
- Claude API costs tracked internally but not shown as currency:

```swift
// Message.swift:20
var cost: Double?  // Stored but not displayed in UI

// Usage tracking only:
struct Usage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
}
```

**Backend sends cost data** (`input_cost`, `output_cost`, `total_cost` in WebSocket protocol), but **iOS doesn't display it**.

**Recommendations**:

1. **If adding cost display later**:
   - Use `NumberFormatter` with `.currencyStyle`
   - Detect user region with `Locale.current.currencyCode`
   - USD for US, EUR for Europe, etc.

2. **Current state**: No localization needed (no pricing UI)

3. **API pricing is USD-based** (Anthropic), so conversion would be needed for local currency display

---

## 7. Region-Specific Features & Restrictions

### Current Status: ⚠️ CONSIDER RESTRICTIONS

**Export Compliance**:

```xml
<!-- Info.plist -->
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

**Declared no encryption** beyond standard HTTPS/TLS. This is **correct** for App Store export compliance (no custom cryptography).

**Potential Regional Restrictions**:

1. **AI/LLM Services**:
   - Claude API availability varies by region
   - Some countries restrict AI services
   - China: May require special approvals for AI apps
   - EU: GDPR compliance for data processing (covered in privacy review)

2. **Speech Recognition**:
   - On-device speech recognition may be restricted in some regions
   - Cloud speech services have different availability

3. **VPN/Network Tools**:
   - App requires VPN (Tailscale) or direct network access
   - VPN usage restricted in: China, Russia, UAE, etc.
   - Consider alternative connection methods for restricted regions

4. **Developer Tools**:
   - Generally unrestricted globally
   - No content restrictions for coding tools

**Recommendations**:

1. **Document region support matrix**:
   ```
   Region          | Speech | Claude API | Tailscale | Status
   ---------------|--------|------------|-----------|--------
   USA            | ✅     | ✅         | ✅        | Full
   EU             | ✅     | ✅         | ✅        | Full
   China          | ⚠️     | ❌         | ⚠️        | Limited
   Russia         | ⚠️     | ⚠️         | ⚠️        | Limited
   Middle East    | ✅     | ✅         | ⚠️        | Partial
   ```

2. **Add region detection** for feature gating:
   ```swift
   if Locale.current.regionCode == "CN" {
       // Show alternative connection instructions
   }
   ```

3. **Alternative backends** for restricted regions:
   - Direct IP connection (non-VPN)
   - Different AI providers where Claude unavailable

4. **Comply with local laws**:
   - Data residency requirements (EU, China)
   - AI service registration (China)
   - Encryption declarations (already handled)

---

## 8. Language-Specific Content Issues

### Current Status: ⚠️ ENGLISH ASSUMPTIONS

**Content Issues Identified**:

1. **Technical terminology** may not translate well:
   - "Session" - varies across languages
   - "Working Directory" - file system concepts
   - "Prompt" - specific AI terminology
   - "Compact" (session compression) - technical term

2. **Voice command vocabulary**:
   - Currently English-only prompts
   - Future: Need language-specific command vocabularies

3. **Error messages** from backend:
   ```swift
   // VoiceCodeClient.swift
   if let error = client.currentError {
       Text(error)  // Backend errors in English
   }
   ```
   Backend (Clojure) returns English error messages

4. **Code/technical content**:
   - Code snippets are language-neutral (good)
   - File paths are UNIX-style (universal)
   - Git commands/output always English

5. **String length variations**:
   - German typically 30% longer than English
   - Chinese/Japanese much shorter
   - UI layouts may need adjustments

**Recommendations**:

1. **Glossary for translators**:
   - Define technical terms (Session, Directory, Claude, etc.)
   - Decide: Translate or keep English technical terms?
   - Example: "Working Directory" might stay English in many locales

2. **Backend localization**:
   - Consider returning error codes + localized strings
   - Or localize errors in iOS client based on codes

3. **UI layout testing**:
   - Test all views with **longest expected text** (German)
   - Verify text truncation handling
   - Use `lineLimit()` and `.minimumScaleFactor()` where needed

4. **Context for translators**:
   - Add comments to localization keys explaining usage
   - Provide screenshots of UI elements

5. **Preserve technical accuracy**:
   - Some terms better left in English for developer audience
   - File paths, git commands, Claude API terms

---

## 9. Localization Priority Matrix

| Component | Priority | Effort | Impact | Status |
|-----------|----------|--------|--------|--------|
| UI Strings | HIGH | Medium | High | ❌ Not started |
| Error Messages | HIGH | Low | Medium | ❌ Not started |
| Voice Languages | MEDIUM | High | Medium | ⚠️ English-only |
| Date/Time Format | LOW | Low | Low | ✅ System locale |
| RTL Support | LOW | Medium | Low | 🔍 Needs testing |
| Privacy Descriptions | HIGH | Low | High | ❌ English-only |
| Regional Features | MEDIUM | High | Medium | 📋 Planning |
| Help/Documentation | MEDIUM | Medium | Medium | ❌ Not started |

---

## 10. Recommendations Summary

### Critical (Before International Release)

1. **Implement String Catalog**:
   - Extract all hardcoded strings
   - Use `NSLocalizedString()` throughout
   - Target: 100% UI string coverage

2. **Localize Privacy Strings**:
   - Microphone usage description
   - Speech recognition description
   - Required for non-English App Store markets

3. **Add Language Selection**:
   - User preference for speech recognition language
   - Sync with voice output language
   - Default to system locale

### Important (Phase 2)

4. **Replace Hardcoded Relative Time**:
   - Use `RelativeDateTimeFormatter`
   - Proper plural handling via `.stringsdict`

5. **Test RTL Layouts**:
   - Preview all views with RTL locale
   - Fix any layout issues

6. **Backend Error Localization**:
   - Error codes or message keys
   - Client-side localization

### Nice to Have (Phase 3)

7. **Regional Feature Documentation**:
   - Supported countries matrix
   - Service availability by region

8. **Alternative Connection Methods**:
   - For regions with VPN restrictions

9. **Multi-language Voice Commands**:
   - Language-specific prompt vocabularies

---

## 11. Current International Support Score

**Overall Readiness**: 25% 🟡

| Category | Score | Notes |
|----------|-------|-------|
| Localization Infrastructure | 0% ❌ | No string catalogs |
| Language Support | 20% 🟡 | English-only, but multi-dialect |
| Date/Time Formatting | 60% 🟢 | Mostly locale-aware |
| Currency Formatting | N/A ⚪ | No currency display |
| RTL Support | 40% 🟡 | SwiftUI auto-support, untested |
| Regional Features | 30% 🟡 | US-focused, needs matrix |
| Export Compliance | 100% 🟢 | Properly declared |
| Content Localization | 0% ❌ | All English |

---

## 12. Recommended Launch Strategy

### Option A: English-Only Launch
**Timeline**: Immediate
**Markets**: US, UK, Canada, Australia, Ireland, New Zealand
**Effort**: Minimal (current state)
**Risk**: Limits market size

### Option B: Basic Localization
**Timeline**: 4-6 weeks
**Markets**: + Spain, France, Germany, Japan
**Effort**: Medium
- String catalog implementation
- Privacy string translations
- Basic language support for speech
**Risk**: Translation quality without native speakers

### Option C: Full Internationalization
**Timeline**: 3-4 months
**Markets**: Global (25+ countries)
**Effort**: High
- Complete localization infrastructure
- Professional translations
- Regional testing
- RTL verification
- Regional feature gating
**Risk**: Higher complexity, longer time to market

**Recommendation**: **Option A** for MVP, plan **Option B** for Q1 2026, **Option C** for market expansion.

---

## 13. Action Items

### Immediate (Pre-Launch)
- [ ] Add `CFBundleDevelopmentRegion` to Info.plist (en)
- [ ] Document app as English-only in App Store metadata
- [ ] Test date formatting in non-US English locale
- [ ] Verify export compliance declaration accuracy

### Short-Term (Next Release)
- [ ] Create String Catalog (.xcstrings)
- [ ] Migrate all UI strings to localized strings
- [ ] Add language preference setting
- [ ] Implement multi-language speech recognition
- [ ] Replace custom relative time with RelativeDateTimeFormatter
- [ ] Get professional translations for privacy descriptions (required for non-English stores)

### Medium-Term (6 months)
- [ ] Professional translation service integration
- [ ] RTL layout testing and fixes
- [ ] Regional support matrix documentation
- [ ] Backend error code system for localization
- [ ] Multi-language voice command support
- [ ] Regional feature gating implementation

### Long-Term (1 year)
- [ ] Expand to 10+ languages
- [ ] Regional backend deployment options
- [ ] Alternative connection methods for restricted regions
- [ ] Localized help/documentation
- [ ] Community translation program

---

## Conclusion

The voice-code app is currently **English-only** with minimal international readiness. While the underlying iOS frameworks provide good foundation (date formatting, SwiftUI RTL support), significant work is needed for true internationalization:

**Strengths**:
- Proper use of DateFormatter with locale awareness
- Export compliance properly declared
- SwiftUI's automatic RTL support
- No currency handling (avoids complexity)

**Weaknesses**:
- No localization infrastructure (String Catalog)
- Hardcoded English strings throughout UI
- English-only speech recognition
- English-only privacy descriptions
- Untested RTL layouts
- No regional feature planning

**Recommended Path**: Launch as English-only initially, then invest in proper localization infrastructure for international expansion. The app's target audience (developers) has high English proficiency, making this viable for MVP.

**Estimated Effort for Basic Internationalization**: 4-6 weeks of development work plus translation costs.
