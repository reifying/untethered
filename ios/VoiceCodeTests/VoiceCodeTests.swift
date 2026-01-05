//
//  VoiceCodeTests.swift
//  VoiceCodeTests
//
//  Created by Travis Brown on 10/14/25.
//

import Testing
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

struct VoiceCodeTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}
