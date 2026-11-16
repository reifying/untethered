// TestingEnvironmentTests.swift
// Knowing, at launch, that this process is a test run. The Mac tests run inside
// the app and its sandbox, so this is what keeps a test run away from the real
// app's settings, log and message store.

import XCTest
import CoreData
@testable import VoiceCode

final class TestingEnvironmentTests: XCTestCase {

    func testAnyTestRunnerVariableMeansHostingUnitTests() {
        XCTAssertFalse(TestingEnvironment.isHostingUnitTests(environment: [:]))
        XCTAssertFalse(TestingEnvironment.isHostingUnitTests(environment: ["HOME": "/Users/me", "PATH": "/usr/bin"]))
        for key in TestingEnvironment.testRunnerEnvironmentKeys {
            XCTAssertTrue(TestingEnvironment.isHostingUnitTests(environment: [key: ""]), "\(key), even when empty")
        }
    }

    /// The point of the environment check: it is true from the first instruction,
    /// which the XCTest class lookup is not. This asserts Xcode still sets at least
    /// one of the variables; if a future Xcode stops, this fails rather than the
    /// tests quietly going back to writing on the real app's data.
    func testThisProcessIsRecognisedAsATestRun() {
        XCTAssertTrue(TestingEnvironment.isHostingUnitTests,
                      "none of \(TestingEnvironment.testRunnerEnvironmentKeys) is set in the test host")
        XCTAssertTrue(TestingEnvironment.isUnitTesting)
        XCTAssertTrue(TestingEnvironment.isTestRun)
    }

    func testTheSharedStoreIsInMemoryInATestRun() {
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertFalse(stores.isEmpty)
        for store in stores {
            XCTAssertTrue(store.type == NSInMemoryStoreType || store.url?.path == "/dev/null",
                          "a test run must not open the real message store (found \(store.type) at \(store.url?.path ?? "nil"))")
        }
    }
}
