import Foundation

/// The public collection entry points: `track()` and the Apple entry-point
/// family.
///
/// Split out of `BeaconstatCore.swift` because that file had reached
/// SwiftLint's `file_length` ceiling — the orchestrator had already grown two
/// same-file extensions (session lifecycle, delivery) and a third would not
/// have helped, since `file_length` counts the file, not the type.
///
/// The cost of living in another file is that the members used here are
/// `internal` rather than `private`: `onQueueIfCollecting`, `enqueue`,
/// `startSessionIfNeeded`, `logger` and `clock`. Everything else about the
/// core's state stays private. The one queue/consent guard is deliberately
/// *not* repeated per entry point — it was copied eight times, which is exactly
/// how a `track()` that forgets to check `isOptedOut` gets written.
extension BeaconstatCore {
    // MARK: - Custom events

    func track(_ name: String, properties: [String: String]) {
        onQueueIfCollecting {
            guard EventValidation.isValidUserEventName(name) else {
                self.logger.debug("dropping invalid event name: \(name)"); return
            }
            var clean: [String: String] = [:]
            // Sorted, not raw dictionary order: which 49 of an over-cap property
            // set survive used to depend on Swift's per-instance hash seed, so
            // two identical `track()` calls in the same process could keep
            // different columns (L7).
            for (k, v) in properties.sorted(by: { $0.key < $1.key }) {
                guard EventValidation.isValidUserKey(k) else {
                    self.logger.debug("dropping invalid property key: \(k)"); continue
                }
                guard v.count <= 1024 else {
                    self.logger.debug("dropping oversized property value for key: \(k)"); continue
                }
                guard clean.count < 49 else { // leave room for _bcs.session.id (server caps 50 keys/event)
                    self.logger.debug("property count limit reached — dropping key: \(k)"); continue
                }
                clean[k] = v
            }
            let sid = self.startSessionIfNeeded()
            if let sid { clean["_bcs.session.id"] = sid }
            self.enqueue(Event(name: name, time: self.clock.nowISO8601(),
                               properties: clean.isEmpty ? nil : clean))
        }
    }

    // MARK: - Apple entry-point events

    func trackOpenURL(_ url: URL) {
        onQueueIfCollecting {
            let scheme = url.scheme?.lowercased()
            let entryType = (scheme == "http" || scheme == "https") ? "universal_link" : "url_scheme"
            var props: [String: String] = ["_bcs.apple.entry_type": entryType]
            if let scheme { props["_bcs.apple.url_scheme"] = scheme }
            if let host = url.host?.lowercased() { props["_bcs.apple.url_host"] = host }
            // NEVER include path / query / fragment.
            self.emitAppleEntry(name: "_bcs.apple.opened_from_url", props: props)
        }
    }

    func trackOpenActivity(_ webpageURL: URL?) {
        onQueueIfCollecting {
            var props: [String: String] = ["_bcs.apple.entry_type": "activity"]
            if let scheme = webpageURL?.scheme?.lowercased() { props["_bcs.apple.url_scheme"] = scheme }
            if let host = webpageURL?.host?.lowercased() { props["_bcs.apple.url_host"] = host }
            self.emitAppleEntry(name: "_bcs.apple.opened_from_url", props: props)
        }
    }

    func trackShortcut(_ type: String) {
        onQueueIfCollecting {
            self.emitAppleEntry(name: "_bcs.apple.opened_from_shortcut",
                                props: self.reserved(["_bcs.apple.shortcut_type": type]))
        }
    }

    func trackWidget(kind: String?, family: String?) {
        onQueueIfCollecting {
            self.emitAppleEntry(name: "_bcs.apple.opened_from_widget",
                                props: self.reserved(["_bcs.apple.widget_kind": kind,
                                                      "_bcs.apple.widget_family": family]))
        }
    }

    func trackPushReceived(category: String?, wasSilent: Bool) {
        onQueueIfCollecting {
            // Only category + was_silent — NEVER the notification body/title/userInfo.
            var props = self.reserved(["_bcs.apple.push_category": category])
            props["_bcs.apple.push_was_silent"] = wasSilent ? "true" : "false"
            self.emitAppleEntry(name: "_bcs.apple.push_received", props: props)
        }
    }

    func trackPushOpened(category: String?, actionId: String?) {
        onQueueIfCollecting {
            // Only category + action id — NEVER the notification body/title/userInfo.
            self.emitAppleEntry(name: "_bcs.apple.push_opened",
                                props: self.reserved(["_bcs.apple.push_category": category,
                                                      "_bcs.apple.push_action_id": actionId]))
        }
    }

    // MARK: - Shared

    /// Shared tail for Apple entry-point events: ensure a session, tag it, enqueue.
    private func emitAppleEntry(name: String, props: [String: String]) {
        var props = props
        if let sid = startSessionIfNeeded() { props["_bcs.session.id"] = sid }
        enqueue(Event(name: name, time: clock.nowISO8601(), properties: props))
    }

    /// Host-supplied scalars bound for reserved `_bcs.apple.*` dimensions.
    ///
    /// These used to go onto the wire verbatim while `track()` enforced a key
    /// regex, a value cap and a key cap — so a dynamic quick action encoding a
    /// target (`"openChat:user@example.com"`) leaked PII onto a reserved
    /// dimension and blew up its cardinality (M2). `nil` values are omitted, as
    /// before; unsalvageable ones are dropped and logged **by key only**.
    private func reserved(_ pairs: [String: String?]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in pairs.sorted(by: { $0.key < $1.key }) {
            guard let value else { continue }
            guard let label = ReservedValue.sanitize(value) else {
                logger.debug("dropping unsafe value for reserved key: \(key)")
                continue
            }
            out[key] = label
        }
        return out
    }
}
