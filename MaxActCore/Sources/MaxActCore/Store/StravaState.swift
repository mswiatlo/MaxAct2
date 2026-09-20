import Foundation

/// Where a workout stands with Strava.
///
/// `.queued` and `.uploading` are distinct from `.failed` on purpose: Strava's upload API is
/// asynchronous, so a request that returned 200 has only been *accepted*. Until the upload id has
/// been polled to completion the outcome is genuinely unknown, and reporting that as success is
/// how duplicate uploads happen.
public enum StravaState: Sendable, Hashable {
    case notUploaded
    /// Selected for upload but not yet sent.
    case queued
    /// Accepted by Strava; `stravaUploadID` is being polled.
    case uploading
    case uploaded
    /// Strava recognised it as a duplicate of an activity already present. Not an error — it means
    /// the desired end state already holds.
    case duplicate
    case failed(reason: String)

    /// Stable string for persistence and for `#Predicate` filtering, which cannot see through an
    /// enum with associated values.
    public var storageKey: String {
        switch self {
        case .notUploaded: "notUploaded"
        case .queued: "queued"
        case .uploading: "uploading"
        case .uploaded: "uploaded"
        case .duplicate: "duplicate"
        case .failed: "failed"
        }
    }

    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    public init(storageKey: String, failureReason: String?) {
        switch storageKey {
        case "queued": self = .queued
        case "uploading": self = .uploading
        case "uploaded": self = .uploaded
        case "duplicate": self = .duplicate
        case "failed": self = .failed(reason: failureReason ?? "unknown error")
        default: self = .notUploaded
        }
    }

    /// True once the workout is on Strava by any route, so the UI and batch actions can skip it.
    public var isOnStrava: Bool {
        switch self {
        case .uploaded, .duplicate: true
        case .notUploaded, .queued, .uploading, .failed: false
        }
    }

    /// Symbol *and* text everywhere — Strava state must never be conveyed by colour alone.
    public var symbolName: String {
        switch self {
        case .notUploaded: "circle.dashed"
        case .queued: "clock"
        case .uploading: "arrow.up.circle"
        case .uploaded: "checkmark.circle.fill"
        case .duplicate: "equal.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    public var label: String {
        switch self {
        case .notUploaded: "Not uploaded"
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded to Strava"
        case .duplicate: "Already on Strava"
        case .failed(let reason): "Upload failed: \(reason)"
        }
    }
}

extension ActivityKind {
    /// Stable key for persistence and predicate filtering. Round-trips `.other` so an unrecognised
    /// activity name survives a save/load cycle rather than collapsing.
    public var storageKey: String {
        switch self {
        case .running: "running"
        case .walking: "walking"
        case .hiking: "hiking"
        case .cycling: "cycling"
        case .indoorCycling: "indoorCycling"
        case .swimming: "swimming"
        case .rowing: "rowing"
        case .elliptical: "elliptical"
        case .strengthTraining: "strengthTraining"
        case .functionalTraining: "functionalTraining"
        case .yoga: "yoga"
        case .other(let name): "other:\(name)"
        }
    }

    public init(storageKey: String) {
        if storageKey.hasPrefix("other:") {
            self = .other(String(storageKey.dropFirst("other:".count)))
            return
        }
        switch storageKey {
        case "running": self = .running
        case "walking": self = .walking
        case "hiking": self = .hiking
        case "cycling": self = .cycling
        case "indoorCycling": self = .indoorCycling
        case "swimming": self = .swimming
        case "rowing": self = .rowing
        case "elliptical": self = .elliptical
        case "strengthTraining": self = .strengthTraining
        case "functionalTraining": self = .functionalTraining
        case "yoga": self = .yoga
        default: self = .other(storageKey)
        }
    }
}
