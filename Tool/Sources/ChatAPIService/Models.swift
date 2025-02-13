import CodableWrappers
import Foundation
import ConversationServiceProvider
import GitHubCopilotService

public struct ChatMessage: Equatable, Codable {
    public typealias ID = String

    public enum Role: String, Codable, Equatable {
        case system
        case user
        case assistant
    }
    
    /// The role of a message.
    @FallbackDecoding<ChatMessageRoleFallback>
    public var role: Role

    /// The content of the message, either the chat message, or a result of a function call.
    public var content: String

    /// The id of the message.
    public var id: ID
    
    /// The turn id of the message.
    public var turnId: ID?
    
    /// Rate assistant message
    public var rating: ConversationRating = .unrated

    /// The references of this message.
    @FallbackDecoding<EmptyArray<ConversationReference>>
    public var references: [ConversationReference]
    
    /// The followUp question of this message
    public var followUp: ConversationFollowUp?
    
    public var suggestedTitle: String?

    /// The error occurred during responding chat in server
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        role: Role,
        turnId: String? = nil,
        content: String,
        references: [ConversationReference] = [],
        followUp: ConversationFollowUp? = nil,
        suggestedTitle: String? = nil,
        errorMessage: String? = nil
    ) {
        self.role = role
        self.content = content
        self.id = id
        self.turnId = turnId
        self.references = references
        self.followUp = followUp
        self.suggestedTitle = suggestedTitle
        self.errorMessage = errorMessage
    }
}

public struct ChatMessageRoleFallback: FallbackValueProvider {
    public static var defaultValue: ChatMessage.Role { .user }
}

