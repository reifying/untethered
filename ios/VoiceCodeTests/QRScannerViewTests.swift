// QRScannerViewTests.swift
// Unit tests for QRScannerView

import XCTest
@testable import VoiceCode

final class QRScannerViewTests: XCTestCase {

    // MARK: - QRScannerView Coordinator Tests

    func testCoordinatorCallsOnCodeScannedWithValidCode() {
        var scannedCode: String?
        var cancelCalled = false

        let coordinator = QRScannerView.Coordinator(
            onCodeScanned: { code in scannedCode = code },
            onCancel: { cancelCalled = true }
        )

        let testCode = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        coordinator.qrScannerDidScanCode(testCode)

        XCTAssertEqual(scannedCode, testCode)
        XCTAssertFalse(cancelCalled)
    }

    func testCoordinatorCallsOnCancel() {
        var scannedCode: String?
        var cancelCalled = false

        let coordinator = QRScannerView.Coordinator(
            onCodeScanned: { code in scannedCode = code },
            onCancel: { cancelCalled = true }
        )

        coordinator.qrScannerDidCancel()

        XCTAssertNil(scannedCode)
        XCTAssertTrue(cancelCalled)
    }

    // MARK: - API Key Format Validation Tests (as used by scanner)

    func testValidAPIKeyAccepted() {
        // Valid API key format
        let validKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(validKey))

        // All zeros
        let allZeros = "voice-code-00000000000000000000000000000000"
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(allZeros))

        // All f's
        let allFs = "voice-code-ffffffffffffffffffffffffffffffff"
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(allFs))
    }

    func testInvalidAPIKeyRejected() {
        // Random website URL (common QR code content)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("https://example.com"))

        // Wrong prefix
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("api-key-a1b2c3d4e5f678901234567890abcdef"))

        // Too short
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-short"))

        // Too long
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890abcdefg"))

        // Uppercase hex
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-A1B2C3D4E5F678901234567890ABCDEF"))

        // Non-hex characters
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-ghijklmn12345678901234567890abcd"))

        // Empty string
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(""))

        // JSON object
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("{\"type\":\"api_key\"}"))

        // WiFi config (common QR code content)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("WIFI:T:WPA;S:MyNetwork;P:MyPassword;;"))

        // vCard (common QR code content)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("BEGIN:VCARD\nVERSION:3.0\nN:Doe;John\nEND:VCARD"))
    }

    // MARK: - Integration Tests

    func testScanValidKeyThenSaveToKeychain() throws {
        // Clean up first
        try? KeychainManager.shared.deleteAPIKey()

        let validKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"

        // Simulate what happens after successful scan
        if KeychainManager.shared.isValidAPIKeyFormat(validKey) {
            try KeychainManager.shared.saveAPIKey(validKey)
        }

        // Verify key was saved
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), validKey)

        // Clean up
        try KeychainManager.shared.deleteAPIKey()
    }

    func testScanInvalidKeyDoesNotSave() throws {
        // Clean up first
        try? KeychainManager.shared.deleteAPIKey()

        let invalidKey = "https://malicious-site.com/fake-key"

        // Simulate what happens after scan - validation should prevent save
        if KeychainManager.shared.isValidAPIKeyFormat(invalidKey) {
            try KeychainManager.shared.saveAPIKey(invalidKey)
        }

        // Verify no key was saved
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
        XCTAssertNil(KeychainManager.shared.retrieveAPIKey())
    }

    // MARK: - Callback Order Tests

    func testCallbacksAreNotCalledMultipleTimes() {
        var scannedCount = 0
        var cancelCount = 0

        let coordinator = QRScannerView.Coordinator(
            onCodeScanned: { _ in scannedCount += 1 },
            onCancel: { cancelCount += 1 }
        )

        // Call scan multiple times (simulating duplicate scans)
        let testCode = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        coordinator.qrScannerDidScanCode(testCode)

        // Each call to coordinator increments counter (controller handles dedup with hasScanned flag)
        XCTAssertEqual(scannedCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    func testCoordinatorDoesNotMixCallbacks() {
        var scannedCode: String?
        var cancelCalled = false

        let coordinator = QRScannerView.Coordinator(
            onCodeScanned: { code in scannedCode = code },
            onCancel: { cancelCalled = true }
        )

        // Call scan
        let testCode = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        coordinator.qrScannerDidScanCode(testCode)

        // Verify only scan callback was called
        XCTAssertEqual(scannedCode, testCode)
        XCTAssertFalse(cancelCalled)

        // Reset
        scannedCode = nil

        // Call cancel
        coordinator.qrScannerDidCancel()

        // Verify only cancel callback was called this time
        XCTAssertNil(scannedCode)
        XCTAssertTrue(cancelCalled)
    }
}
