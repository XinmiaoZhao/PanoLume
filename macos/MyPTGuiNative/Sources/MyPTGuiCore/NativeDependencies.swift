import Foundation

public enum NativeDependencyKind: String, Codable, CaseIterable, Sendable {
    case opencv
    case libraw
    case ceres
    case eigen
    case libtiff
    case metal
}

public struct NativeDependencyStatus: Codable, Equatable, Sendable {
    public var kind: NativeDependencyKind
    public var displayName: String
    public var headerAvailable: Bool
    public var runtimeAvailable: Bool
    public var runtimeRequired: Bool
    public var available: Bool
    public var requiredForParity: Bool
    public var headerCandidates: [String]
    public var runtimeCandidates: [String]
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case kind
        case displayName = "display_name"
        case headerAvailable = "header_available"
        case runtimeAvailable = "runtime_available"
        case runtimeRequired = "runtime_required"
        case available
        case requiredForParity = "required_for_parity"
        case headerCandidates = "header_candidates"
        case runtimeCandidates = "runtime_candidates"
        case notes
    }
}

public struct NativeDependencyReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var status: String
    public var allRequiredAvailable: Bool
    public var requiredForParity: [NativeDependencyKind]
    public var dependencies: [NativeDependencyStatus]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case allRequiredAvailable = "all_required_available"
        case requiredForParity = "required_for_parity"
        case dependencies
    }

    public func status(for kind: NativeDependencyKind) -> NativeDependencyStatus? {
        dependencies.first { $0.kind == kind }
    }
}
