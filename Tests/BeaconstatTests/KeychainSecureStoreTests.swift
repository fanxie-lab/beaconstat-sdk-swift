import Foundation
import XCTest
@testable import Beaconstat

/// Records every `SecItem*` call and returns scripted statuses, so the
/// delete-then-add logic, the access group (M12) and the write-failure path
/// (H5) are exercised in-process. The real Keychain is unavailable in an
/// unsigned SwiftPM test bundle, which is why this code had zero coverage.
private final class SecItemRecorder {
    var copyMatchingStatus: OSStatus = errSecItemNotFound
    var copyMatchingData: Data?
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    var copyMatchingQueries: [[String: Any]] = []
    var addAttributes: [[String: Any]] = []
    var deleteQueries: [[String: Any]] = []

    var api: KeychainSecureStore.SecItemAPI {
        KeychainSecureStore.SecItemAPI(
            copyMatching: { [unowned self] query, result in
                self.copyMatchingQueries.append(query as! [String: Any]) // swiftlint:disable:this force_cast
                if let data = self.copyMatchingData, self.copyMatchingStatus == errSecSuccess {
                    result?.pointee = data as CFTypeRef
                }
                return self.copyMatchingStatus
            },
            add: { [unowned self] attributes, _ in
                self.addAttributes.append(attributes as! [String: Any]) // swiftlint:disable:this force_cast
                return self.addStatus
            },
            delete: { [unowned self] query in
                self.deleteQueries.append(query as! [String: Any]) // swiftlint:disable:this force_cast
                return self.deleteStatus
            })
    }
}

final class KeychainSecureStoreTests: XCTestCase {
    private func store(_ recorder: SecItemRecorder,
                       accessGroup: String? = nil) -> KeychainSecureStore {
        let s = KeychainSecureStore(service: "com.example.test", secItem: recorder.api)
        s.setKeychainAccessGroup(accessGroup)
        return s
    }

    // MARK: - read

    func testReadReturnsTheStoredUTF8Value() {
        let rec = SecItemRecorder()
        rec.copyMatchingStatus = errSecSuccess
        rec.copyMatchingData = Data("bcs_tok_x".utf8)
        XCTAssertEqual(store(rec).string(forKey: .siteToken), "bcs_tok_x")
        XCTAssertEqual(rec.copyMatchingQueries.count, 1)
        XCTAssertEqual(rec.copyMatchingQueries[0][kSecAttrAccount as String] as? String, "site_token")
        XCTAssertEqual(rec.copyMatchingQueries[0][kSecAttrService as String] as? String, "com.example.test")
    }

    func testReadReturnsNilOnNonSuccessStatus() {
        let rec = SecItemRecorder()
        rec.copyMatchingStatus = errSecInteractionNotAllowed // locked device, pre-first-unlock
        rec.copyMatchingData = Data("bcs_tok_x".utf8)
        XCTAssertNil(store(rec).string(forKey: .siteToken))
    }

    // MARK: - write: the Bool must not be discarded (H5)

    func testWriteDeletesThenAddsAndReportsSuccess() {
        let rec = SecItemRecorder()
        XCTAssertTrue(store(rec).set("install-abc", forKey: .installId))
        XCTAssertEqual(rec.deleteQueries.count, 1)
        XCTAssertEqual(rec.addAttributes.count, 1)
        XCTAssertEqual(rec.addAttributes[0][kSecAttrAccount as String] as? String, "install_id")
        XCTAssertEqual(rec.addAttributes[0][kSecValueData as String] as? Data, Data("install-abc".utf8))
    }

    func testWriteReportsFailureWhenAddIsRejected() {
        let rec = SecItemRecorder()
        rec.addStatus = errSecMissingEntitlement // unsandboxed macOS
        XCTAssertFalse(store(rec).set("install-abc", forKey: .installId))
    }

    func testWriteReportsFailureWhenDeleteFailsUnexpectedly() {
        let rec = SecItemRecorder()
        rec.deleteStatus = errSecInteractionNotAllowed // pre-first-unlock background launch
        XCTAssertFalse(store(rec).set("install-abc", forKey: .installId))
        XCTAssertTrue(rec.addAttributes.isEmpty, "must not add after an unexplained delete failure")
    }

    func testItemNotFoundOnDeleteIsNotAFailure() {
        let rec = SecItemRecorder()
        rec.deleteStatus = errSecItemNotFound
        XCTAssertTrue(store(rec).set("install-abc", forKey: .installId))
    }

    func testNilValueDeletesWithoutAdding() {
        let rec = SecItemRecorder()
        XCTAssertTrue(store(rec).set(nil, forKey: .installId))
        XCTAssertEqual(rec.deleteQueries.count, 1)
        XCTAssertTrue(rec.addAttributes.isEmpty)
    }

    func testItemsAreScopedToThisDeviceAfterFirstUnlock() {
        let rec = SecItemRecorder()
        store(rec).set("install-abc", forKey: .installId)
        XCTAssertEqual(rec.addAttributes[0][kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    // MARK: - M12: Keychain access group

    func testAccessGroupIsAppliedToAdds() {
        let rec = SecItemRecorder()
        store(rec, accessGroup: "ABCDE12345.com.example.shared").set("install-abc", forKey: .installId)
        XCTAssertEqual(rec.addAttributes[0][kSecAttrAccessGroup as String] as? String,
                       "ABCDE12345.com.example.shared")
    }

    /// Reads and deletes deliberately omit the group so they span *every*
    /// accessible group. That is what migrates an app that already has an
    /// `install_id` in its private group when it later adopts a shared group —
    /// otherwise adopting the option would mint a brand-new install.
    func testReadsAndDeletesOmitTheAccessGroupSoTheySpanEveryGroup() {
        let rec = SecItemRecorder()
        let s = store(rec, accessGroup: "ABCDE12345.com.example.shared")
        _ = s.string(forKey: .installId)
        s.set("install-abc", forKey: .installId)
        XCTAssertNil(rec.copyMatchingQueries[0][kSecAttrAccessGroup as String])
        XCTAssertNil(rec.deleteQueries[0][kSecAttrAccessGroup as String])
    }

    func testNoAccessGroupAttributeWhenNoneIsConfigured() {
        let rec = SecItemRecorder()
        store(rec, accessGroup: nil).set("install-abc", forKey: .installId)
        XCTAssertNil(rec.addAttributes[0][kSecAttrAccessGroup as String])
    }

    func testAccessGroupIsForwardedThroughTheLayeredStore() {
        let rec = SecItemRecorder()
        let keychain = KeychainSecureStore(service: "com.example.test", secItem: rec.api)
        let layered = LayeredSecureStore(primary: keychain, mirror: nil)
        layered.setKeychainAccessGroup("ABCDE12345.com.example.shared")
        layered.set("install-abc", forKey: .installId)
        XCTAssertEqual(rec.addAttributes[0][kSecAttrAccessGroup as String] as? String,
                       "ABCDE12345.com.example.shared")
    }
}
