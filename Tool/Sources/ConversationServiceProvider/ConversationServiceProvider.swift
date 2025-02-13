import CopilotForXcodeKit
import Foundation
import CodableWrappers

public protocol ConversationServiceType {
    func createConversation(_ request: ConversationRequest, workspace: WorkspaceInfo) async throws
    func createTurn(with conversationId: String, request: ConversationRequest, workspace: WorkspaceInfo) async throws
    func cancelProgress(_ workDoneToken: String, workspace: WorkspaceInfo) async throws
    func rateConversation(turnId: String, rating: ConversationRating, workspace: WorkspaceInfo) async throws
    func copyCode(request: CopyCodeRequest, workspace: WorkspaceInfo) async throws
    func templates(workspace: WorkspaceInfo) async throws -> [ChatTemplate]?
}

public protocol ConversationServiceProvider {
    func createConversation(_ request: ConversationRequest) async throws
    func createTurn(with conversationId: String, request: ConversationRequest) async throws
    func stopReceivingMessage(_ workDoneToken: String) async throws
    func rateConversation(turnId: String, rating: ConversationRating) async throws
    func copyCode(_ request: CopyCodeRequest) async throws
    func templates() async throws -> [ChatTemplate]?
}

public struct FileReference: Hashable {
    public let url: URL
    public let relativePath: String?
    public let fileName: String?
    public var isCurrentEditor: Bool = false

    public init(url: URL, relativePath: String?, fileName: String?, isCurrentEditor: Bool = false) {
        self.url = url
        self.relativePath = relativePath
        self.fileName = fileName
        self.isCurrentEditor = isCurrentEditor
    }
    
    public init(url: URL, isCurrentEditor: Bool = false) {
        self.url = url
        self.relativePath = nil
        self.fileName = nil
        self.isCurrentEditor = isCurrentEditor
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(isCurrentEditor)
    }

    public static func == (lhs: FileReference, rhs: FileReference) -> Bool {
        return lhs.url == rhs.url && lhs.isCurrentEditor == rhs.isCurrentEditor
    }
}

extension FileReference {
    public func getPathRelativeToHome() -> String {
        let filePath = url.path
        guard !filePath.isEmpty else { return "" }
        
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        if !homeDirectory.isEmpty {
            return filePath.replacingOccurrences(of: homeDirectory, with: "~")
        }
        
        return filePath
    }
}

public struct ConversationRequest {
    public var workDoneToken: String
    public var content: String
    public var workspaceFolder: String
    public var skills: [String]
    public var ignoredSkills: [String]?
    public var references: [FileReference]?

    public init(
        workDoneToken: String,
        content: String,
        workspaceFolder: String,
        skills: [String],
        ignoredSkills: [String]? = nil,
        references: [FileReference]? = nil
    ) {
        self.workDoneToken = workDoneToken
        self.content = content
        self.workspaceFolder = workspaceFolder
        self.skills = skills
        self.ignoredSkills = ignoredSkills
        self.references = references
    }
}

public struct CopyCodeRequest {
    public var turnId: String
    public var codeBlockIndex: Int
    public var copyType: CopyKind
    public var copiedCharacters: Int
    public var totalCharacters: Int
    public var copiedText: String
    
    init(turnId: String, codeBlockIndex: Int, copyType: CopyKind, copiedCharacters: Int, totalCharacters: Int, copiedText: String) {
        self.turnId = turnId
        self.codeBlockIndex = codeBlockIndex
        self.copyType = copyType
        self.copiedCharacters = copiedCharacters
        self.totalCharacters = totalCharacters
        self.copiedText = copiedText
    }
}

public enum ConversationRating: Int, Codable {
    case unrated = 0
    case helpful = 1
    case unhelpful = -1
}

public enum CopyKind: Int, Codable {
    case keyboard = 1
    case toolbar = 2
}

public struct ConversationReference: Codable, Equatable {
    public enum Kind: String, Codable {
        case `class`
        case `struct`
        case `enum`
        case `actor`
        case `protocol`
        case `extension`
        case `case`
        case property
        case `typealias`
        case function
        case method
        case text
        case webpage
        case other
    }
    
    public enum Status: String, Codable {
        case included, blocked, notfound, empty
    }

    public var uri: String
    public var status: Status?
    @FallbackDecoding<ReferenceKindFallback>
    public var kind: Kind
    
    public var ext: String {
        return url?.pathExtension ?? ""
    }
    
    public var fileName: String {
        return url?.lastPathComponent ?? ""
    }
    
    public var filePath: String {
        return url?.path ?? ""
    }
    
    public var url: URL? {
        return URL(string: uri)
    }

    public init(
        uri: String,
        status: Status?,
        kind: Kind
    ) {
        self.uri = uri
        self.status = status
        self.kind = kind
        
    }
}

extension ConversationReference {
    public func getPathRelativeToHome() -> String {
        guard !filePath.isEmpty else { return filePath}
        
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        if !homeDirectory.isEmpty{
            return filePath.replacingOccurrences(of: homeDirectory, with: "~")
        }
        
        return filePath
    }
}

public struct ReferenceKindFallback: FallbackValueProvider {
    public static var defaultValue: ConversationReference.Kind { .other }
}

public struct ConversationFollowUp: Codable, Equatable {
    public var message: String
    public var id: String
    public var type: String
    
    public init(message: String, id: String, type: String) {
        self.message = message
        self.id = id
        self.type = type
    }
}

public struct ChatTemplate: Codable, Equatable {
    public var id: String
    public var description: String
    public var shortDescription: String
    public var scopes: [ChatPromptTemplateScope]
    
    public init(id: String, description: String, shortDescription: String, scopes: [ChatPromptTemplateScope]=[]) {
        self.id = id
        self.description = description
        self.shortDescription = shortDescription
        self.scopes = scopes
    }
}

public enum ChatPromptTemplateScope: String, Codable, Equatable {
    case chatPanel = "chat-panel"
    case editor = "editor"
    case inline = "inline"
}

public struct CopilotLanguageServerError: Codable {
    public var code: Int?
    public var message: String
    public var responseIsIncomplete: Bool?
    public var responseIsFiltered: Bool?
}
