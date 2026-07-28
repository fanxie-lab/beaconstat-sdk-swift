import Foundation
import XCTest
@testable import Beaconstat

/// The SDK ships a `PrivacyInfo.xcprivacy`, and these tests are what keep it
/// true.
///
/// A privacy manifest is the one artefact in the package that nothing else
/// checks: it is not compiled, not linted, and a wrong value produces no
/// symptom until an adopter's App Store submission is flagged or — worse — its
/// nutrition label quietly misdescribes what the SDK does. So the file is
/// pinned from three directions:
///
/// 1. **It is actually bundled.** Declaring a resource in `Package.swift` and
///    landing it at the resource bundle root are different things, and only
///    the second one counts.
/// 2. **Its contents are the audited set**, not whatever the last edit left
///    behind.
/// 3. **The source still matches the audit.** The empty
///    `NSPrivacyAccessedAPITypes` array rests on a claim about the source —
///    that the only required-reason API in the SDK is macOS-gated — and
///    `testTheOnlyRequiredReasonAPIInTheSourceIsMacOSGated` re-derives that
///    claim from the source itself rather than trusting the comment.
final class PrivacyManifestTests: XCTestCase {
    // MARK: - Loading

    /// Read through `Bundle.module` rather than off disk, deliberately: this is
    /// the assertion that the resource declaration in `Package.swift` works.
    /// Reading the source file directly would still pass if the `resources:`
    /// entry were deleted tomorrow.
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not in the resource bundle — check that Package.swift "
            + "still declares `resources: [.copy(\"PrivacyInfo.xcprivacy\")]` on the Beaconstat target")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "the manifest is not a plist dictionary")
    }

    private func collectedTypes() throws -> [[String: Any]] {
        try XCTUnwrap(manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    }

    // MARK: - Bundling

    func testTheManifestIsBundledAtTheResourceBundleRoot() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        // Apple reads the manifest from the bundle ROOT. `.copy` preserves the
        // path it is given, so a `Resources/` subdirectory in Package.swift
        // would put it one level down, where nothing looks.
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       Bundle.module.bundleURL.lastPathComponent,
                       "the manifest must sit at the bundle root, not in a subdirectory")
    }

    func testTheManifestIsAValidPropertyListWithTheFourTopLevelKeys() throws {
        XCTAssertEqual(Set(try manifest().keys),
                       ["NSPrivacyTracking", "NSPrivacyTrackingDomains",
                        "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"])
    }

    // MARK: - Tracking

    /// The single most consequential value in the file. `true` obliges every
    /// adopter to run an App Tracking Transparency prompt, and makes requests
    /// to any listed domain fail without one.
    func testTheSDKDoesNotDeclareTrackingAndListsNoTrackingDomains() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(manifest["NSPrivacyTrackingDomains"] as? [String]), [],
                       "a tracking domain may only be listed when NSPrivacyTracking is true")
    }

    /// The manifest's tracking claim is only as good as the code. ATT tracking
    /// means linking this app's data with other companies' data, or handing it
    /// to a data broker; the SDK cannot do either, because it has no device
    /// identifier that is stable ACROSS apps. Hashing the install id with the
    /// bundle id is what guarantees that, so it is asserted here and not only
    /// in `FingerprintTests`.
    func testTheInstallFingerprintCannotBeJoinedAcrossApps() {
        let installId = "5a2b1c3d-0000-4000-8000-abcdefabcdef"
        let inAppOne = Fingerprint.compute(bundleIdentifier: "com.example.one", installId: installId)
        let inAppTwo = Fingerprint.compute(bundleIdentifier: "com.example.two", installId: installId)
        XCTAssertNotEqual(inAppOne, inAppTwo,
                          "the same install must present a different fingerprint to each app, "
                          + "or NSPrivacyTracking=false is not defensible")
    }

    // MARK: - Collected data types

    func testTheCollectedDataTypesAreExactlyTheAuditedSet() throws {
        let declared = try collectedTypes().compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(Set(declared),
                       ["NSPrivacyCollectedDataTypeDeviceID",          // install fingerprint, session id
                        "NSPrivacyCollectedDataTypeProductInteraction", // events, names, properties
                        "NSPrivacyCollectedDataTypeOtherDiagnosticData", // device/OS/app/SDK/run context
                        "NSPrivacyCollectedDataTypeOtherDataTypes"])    // locale, timezone, preferences
        XCTAssertEqual(declared.count, Set(declared).count, "a data type is declared twice")
    }

    /// Every type is unlinked, untracked, and collected for analytics. There is
    /// no identity in this system to link to: no `identify()` API, no account,
    /// no IDFA, no `identifierForVendor`, and the only stable id is a random
    /// UUID hashed before it leaves the device.
    func testEveryCollectedTypeIsUnlinkedUntrackedAndForAnalytics() throws {
        for entry in try collectedTypes() {
            let name = (entry["NSPrivacyCollectedDataType"] as? String) ?? "<missing>"
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false, "\(name)")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, "\(name)")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAnalytics"], "\(name)")
        }
    }

    /// Timezone is collected; Coarse Location is not declared, and must not be.
    /// Apple scopes that type to Approximate-Location-Services resolution, and
    /// declaring it would put a location pin on every adopter's nutrition label
    /// for data that is not location.
    func testNoLocationTypeIsDeclared() throws {
        let declared = Set(try collectedTypes().compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertFalse(declared.contains("NSPrivacyCollectedDataTypeCoarseLocation"))
        XCTAssertFalse(declared.contains("NSPrivacyCollectedDataTypePreciseLocation"))
    }

    /// The accessibility carve-out, wired to the thing it depends on.
    ///
    /// The manifest omits Sensitive Info because `collectAccessibility`
    /// defaults to `false`, so the shipped configuration collects none of the
    /// seven disability-adjacent settings. Flip that default and this test goes
    /// red — which is the point: the manifest would then be wrong, and the
    /// decision has to be reopened rather than silently invalidated.
    func testSensitiveInfoIsOmittedOnlyBecauseAccessibilityCollectionDefaultsOff() throws {
        XCTAssertFalse(BeaconstatOptions().collectAccessibility,
                       "the manifest omits NSPrivacyCollectedDataTypeSensitiveInfo on the strength of "
                       + "this default; if accessibility collection ships on, the manifest must declare it")
        let declared = Set(try collectedTypes().compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertFalse(declared.contains("NSPrivacyCollectedDataTypeSensitiveInfo"))
    }

    // MARK: - Required reason APIs

    func testNoRequiredReasonAPITypesAreDeclared() throws {
        XCTAssertEqual(try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]]).count, 0,
                       "the audit found no required-reason API compiled for a platform that requires "
                       + "a declaration — see testTheOnlyRequiredReasonAPIInTheSourceIsMacOSGated")
    }

    /// Re-derives the audit from the source, so the empty
    /// `NSPrivacyAccessedAPITypes` array is a finding rather than an assumption.
    ///
    /// Apple scopes required-reason declarations to iOS, iPadOS, tvOS, visionOS
    /// and watchOS; macOS is deliberately absent from that list. The SDK's only
    /// covered API is `UserDefaults.standard` in `EnvironmentCollector`, and it
    /// lives inside `#elseif os(macOS)` — so it is not compiled into any
    /// platform where a declaration would be required.
    ///
    /// That matters more than it looks, because there is no reason code that
    /// would cover it if it *were* compiled in: `AppleInterfaceStyle` is
    /// written by the system and the derived value is sent off device, which
    /// `CA92.1` and `1C8F.1` both exclude, `C56D.1` forbids transmitting, and
    /// `AC6B.1` is for MDM keys. Moving the read out from behind `os(macOS)`
    /// would leave the SDK undeclarable, not merely undeclared — so it fails
    /// here first.
    func testTheOnlyRequiredReasonAPIInTheSourceIsMacOSGated() throws {
        let hits = try RequiredReasonAPIScanner.scanSources()
        let ungated = hits.filter { !$0.isMacOSGated }
        XCTAssertTrue(ungated.isEmpty, """
            Required-reason API reachable on a platform that requires a privacy-manifest \
            declaration. Either gate it behind `#if os(macOS)`, or add the category and an \
            approved reason code to Sources/Beaconstat/PrivacyInfo.xcprivacy:
            \(ungated.map(\.description).joined(separator: "\n"))
            """)
    }

    /// The counterpart: the scanner has to be able to find something, or the
    /// test above passes because the sweep is broken rather than because the
    /// source is clean.
    func testTheScannerStillFindsTheKnownMacOSOnlyUserDefaultsRead() throws {
        let hits = try RequiredReasonAPIScanner.scanSources()
        let userDefaults = hits.filter { $0.token == "UserDefaults" }
        XCTAssertEqual(userDefaults.count, 1, "found: \(hits.map(\.description))")
        let hit = try XCTUnwrap(userDefaults.first)
        XCTAssertEqual(hit.file, "EnvironmentCollector.swift")
        XCTAssertTrue(hit.isMacOSGated)
    }
}
