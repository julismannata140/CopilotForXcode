import Foundation

public protocol ChatMemory {
    /// The message history.
    var history: [ChatMessage] { get async }
    /// Update the message history.
    func mutateHistory(_ update: (inout [ChatMessage]) -> Void) async
}

public extension ChatMemory {
    /// Append a message to the history.
    func appendMessage(_ message: ChatMessage) async {
        await mutateHistory { history in
            if let index = history.firstIndex(where: { $0.id == message.id }) {
                history[index].content = history[index].content + message.content
                history[index].references.append(contentsOf: message.references)
                history[index].followUp = message.followUp
                history[index].suggestedTitle = message.suggestedTitle
                if let errorMessage = message.errorMessage {
                    history[index].errorMessage = (history[index].errorMessage ?? "") + errorMessage
                }
            } else {
                history.append(message)
            }
        }
    }

    /// Remove a message from the history.
    func removeMessage(_ id: String) async {
        await mutateHistory {
            $0.removeAll { $0.id == id }
        }
    }

    /// Clear the history.
    func clearHistory() async {
        await mutateHistory { $0.removeAll() }
    }
}
