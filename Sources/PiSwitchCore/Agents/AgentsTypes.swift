import Foundation
import CryptoKit

public struct AgentsError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AgentsCollection: String, Codable, CaseIterable, Sendable {
    case global, templates
}

public struct AgentEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct AgentOrigin: Codable, Equatable, Sendable {
    public let templateId: UUID
    public let templateName: String
    public let createdFromHash: String
}

public struct AgentProject: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public var origin: AgentOrigin?
    public init(id: UUID = UUID(), path: String) { self.id = id; self.path = path }
}

public struct AgentApplication: Codable, Equatable, Sendable {
    public let versionId: UUID
    public let appliedHash: String
}

public enum AgentTarget: Hashable, Sendable {
    case entry(AgentsCollection, UUID)
    case global
    case project(UUID)

    public var key: String {
        switch self {
        case .entry(_, let id): return id.uuidString
        case .global: return "global"
        case .project(let id): return id.uuidString
        }
    }
}

public struct AgentBackup: Codable, Equatable, Sendable {
    public let key: String
    public let hash: String
    public let permissions: Int
}

public struct AgentsState: Codable, Equatable, Sendable {
    public var version = 1
    public var globals: [AgentEntry] = []
    public var templates: [AgentEntry] = []
    public var projects: [AgentProject] = []
    public var activeGlobal: AgentApplication?
    public var backups: [AgentBackup] = []
    public init() {}

    public func entries(_ collection: AgentsCollection) -> [AgentEntry] {
        collection == .global ? globals : templates
    }
}

public struct AgentFileSnapshot: Equatable, Sendable {
    public let data: Data?
    public let permissions: Int?
    public let inode: UInt64?
    public let device: UInt64?
    public let modificationTime: Int?
    public let modificationNanoseconds: Int?
    public let changeTime: Int?
    public let changeNanoseconds: Int?
    public var text: String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public var hash: String? { data.map(Self.digest) }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AgentsInspection: Sendable {
    public let state: AgentsState
    public let revision: AgentFileSnapshot
    public let warnings: [String]
}

public struct AgentContext: Identifiable, Equatable, Sendable {
    public var id: String { directory }
    public let directory: String
    public let selectedPath: String?
    public let otherPaths: [String]
    public let problem: String?
}

public enum AgentsStoreStep: Sendable {
    case backup, replace, writeState, cleanup
}
