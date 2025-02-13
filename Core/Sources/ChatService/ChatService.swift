import ChatAPIService
import Combine
import Foundation
import GitHubCopilotService
import Preferences
import ConversationServiceProvider
import BuiltinExtension
import JSONRPC
import Status

public protocol ChatServiceType {
    var memory: ContextAwareAutoManagedChatMemory { get set }
    func send(_ id: String, content: String, skillSet: [ConversationSkill], references: [FileReference]) async throws
    func stopReceivingMessage() async
    func upvote(_ id: String, _ rating: ConversationRating) async
    func downvote(_ id: String, _ rating: ConversationRating) async
    func copyCode(_ id: String) async
}

public final class ChatService: ChatServiceType, ObservableObject {
    
    public var memory: ContextAwareAutoManagedChatMemory
    @Published public internal(set) var chatHistory: [ChatMessage] = []
    @Published public internal(set) var isReceivingMessage = false
    public var chatTemplates: [ChatTemplate]? = nil
    public static var shared: ChatService = ChatService.service()

    private let conversationProvider: ConversationServiceProvider?
    private let conversationProgressHandler: ConversationProgressHandler
    private let conversationContextHandler: ConversationContextHandler = ConversationContextHandlerImpl.shared
    private var cancellables = Set<AnyCancellable>()
    private var activeRequestId: String?
    private var conversationId: String?
    private var skillSet: [ConversationSkill] = []
    init(provider: any ConversationServiceProvider,
         memory: ContextAwareAutoManagedChatMemory = ContextAwareAutoManagedChatMemory(),
         conversationProgressHandler: ConversationProgressHandler = ConversationProgressHandlerImpl.shared) {
        self.memory = memory
        self.conversationProvider = provider
        self.conversationProgressHandler = conversationProgressHandler
        memory.chatService = self
        
        subscribeToNotifications()
        subscribeToConversationContextRequest()
    }
    
    private func subscribeToNotifications() {
        memory.observeHistoryChange { [weak self] in
            Task { [weak self] in
                guard let memory = self?.memory else { return }
                self?.chatHistory = await memory.history
            }
        }
        
        conversationProgressHandler.onBegin.sink { [weak self] (token, progress) in
            self?.handleProgressBegin(token: token, progress: progress)
        }.store(in: &cancellables)
        
        conversationProgressHandler.onProgress.sink { [weak self] (token, progress) in
            self?.handleProgressReport(token: token, progress: progress)
        }.store(in: &cancellables)
        
        conversationProgressHandler.onEnd.sink { [weak self] (token, progress) in
            self?.handleProgressEnd(token: token, progress: progress)
        }.store(in: &cancellables)
    }
    
    private func subscribeToConversationContextRequest() {
        self.conversationContextHandler.onConversationContext.sink(receiveValue: { [weak self] (request, completion) in
            guard let skills = self?.skillSet, !skills.isEmpty, request.params!.conversationId == self?.conversationId else { return }
            skills.forEach { skill in
                if (skill.applies(params: request.params!)) {
                    skill.resolveSkill(request: request, completion: completion)
                }
            }
        }).store(in: &cancellables)
    }
    public static func service() -> ChatService {
        let provider = BuiltinExtensionConversationServiceProvider(
            extension: GitHubCopilotExtension.self
        )
        return ChatService(provider: provider)
    }
    
    public func send(_ id: String, content: String, skillSet: Array<ConversationSkill>, references: Array<FileReference>) async throws {
        guard activeRequestId == nil else { return }
        let workDoneToken = UUID().uuidString
        activeRequestId = workDoneToken
        
        await memory.appendMessage(ChatMessage(id: id, role: .user, content: content, references: []))
        let skillCapabilities: [String] = [ CurrentEditorSkill.ID, ProblemsInActiveDocumentSkill.ID ]
        let supportedSkills: [String] = skillSet.map { $0.id }
        let ignoredSkills: [String] = skillCapabilities.filter {
            !supportedSkills.contains($0)
        }
        let request = ConversationRequest(workDoneToken: workDoneToken,
                                          content: content,
                                          workspaceFolder: "",
                                          skills: skillCapabilities,
                                          ignoredSkills: ignoredSkills,
                                          references: references)
        self.skillSet = skillSet
        try await send(request)
    }

    public func sendAndWait(_ id: String, content: String) async throws -> String {
        try await send(id, content: content, skillSet: [], references: [])
        if let reply = await memory.history.last(where: { $0.role == .assistant })?.content {
            return reply
        }
        return ""
    }

    public func stopReceivingMessage() async {
        if let activeRequestId = activeRequestId {
            do {
                try await conversationProvider?.stopReceivingMessage(activeRequestId)
            } catch {
                print("Failed to cancel ongoing request with WDT: \(activeRequestId)")
            }
        }
        resetOngoingRequest()
    }

    public func clearHistory() async {
        await memory.clearHistory()
        if let activeRequestId = activeRequestId {
            do {
                try await conversationProvider?.stopReceivingMessage(activeRequestId)
            } catch {
                print("Failed to cancel ongoing request with WDT: \(activeRequestId)")
            }
        }
        resetOngoingRequest()
    }

    public func deleteMessage(id: String) async {
        await memory.removeMessage(id)
    }

    public func resendMessage(id: String) async throws {
        if let message = (await memory.history).first(where: { $0.id == id })
        {
            do {
                try await send(id, content: message.content, skillSet: [], references: [])
            } catch {
                print("Failed to resend message")
            }
        }
    }

    public func setMessageAsExtraPrompt(id: String) async {
        if let message = (await memory.history).first(where: { $0.id == id })
        {
            await mutateHistory { history in
                history.append(.init(
                    role: .assistant,
                    content: message.content
                ))
            }
        }
    }

    public func mutateHistory(_ mutator: @escaping (inout [ChatMessage]) -> Void) async {
        await memory.mutateHistory(mutator)
    }

    public func handleCustomCommand(_ command: CustomCommand) async throws {
        struct CustomCommandInfo {
            var specifiedSystemPrompt: String?
            var extraSystemPrompt: String?
            var sendingMessageImmediately: String?
            var name: String?
        }

        let info: CustomCommandInfo? = {
            switch command.feature {
            case let .chatWithSelection(extraSystemPrompt, prompt, useExtraSystemPrompt):
                let updatePrompt = useExtraSystemPrompt ?? true
                return .init(
                    extraSystemPrompt: updatePrompt ? extraSystemPrompt : nil,
                    sendingMessageImmediately: prompt,
                    name: command.name
                )
            case let .customChat(systemPrompt, prompt):
                return .init(
                    specifiedSystemPrompt: systemPrompt,
                    extraSystemPrompt: "",
                    sendingMessageImmediately: prompt,
                    name: command.name
                )
            case .promptToCode: return nil
            case .singleRoundDialog: return nil
            }
        }()

        guard let info else { return }

        let templateProcessor = CustomCommandTemplateProcessor()

        if info.specifiedSystemPrompt != nil || info.extraSystemPrompt != nil {
            await mutateHistory { history in
                history.append(.init(
                    role: .assistant,
                    content: ""
                ))
            }
        }

        if let sendingMessageImmediately = info.sendingMessageImmediately,
           !sendingMessageImmediately.isEmpty
        {
            try await send(UUID().uuidString, content: templateProcessor.process(sendingMessageImmediately), skillSet: [], references: [])
        }
    }
    
    public func upvote(_ id: String, _ rating: ConversationRating) async {
        try? await conversationProvider?.rateConversation(turnId: id, rating: rating)
    }
    
    public func downvote(_ id: String, _ rating: ConversationRating) async {
        try? await conversationProvider?.rateConversation(turnId: id, rating: rating)
    }
    
    public func copyCode(_ id: String) async {
        // TODO: pass copy code info to Copilot server
    }

    public func loadChatTemplates() async -> [ChatTemplate]? {
        guard self.chatTemplates == nil else { return self.chatTemplates }

        do {
            if let templates = (try await conversationProvider?.templates()) {
                self.chatTemplates = templates
                return templates
            }
        } catch {
            // handle error if desired
        }

        return nil
    }

    public func handleSingleRoundDialogCommand(
        systemPrompt: String?,
        overwriteSystemPrompt: Bool,
        prompt: String
    ) async throws -> String {
        let templateProcessor = CustomCommandTemplateProcessor()
        return try await sendAndWait(UUID().uuidString, content: templateProcessor.process(prompt))
    }
    
    private func handleProgressBegin(token: String, progress: ConversationProgressBegin) {
        guard let workDoneToken = activeRequestId, workDoneToken == token else { return }
        conversationId = progress.conversationId
        
        Task {
            if var lastUserMessage = await memory.history.last(where: { $0.role == .user }) {
                lastUserMessage.turnId = progress.turnId
            }
        }
    }

    private func handleProgressReport(token: String, progress: ConversationProgressReport) {
        guard let workDownToken = activeRequestId, workDownToken == token else {
            return
        }
        
        let id = progress.turnId
        var content = ""
        var references: [ConversationReference] = []

        if let reply = progress.reply {
            content = reply
        }
        
        if let progressReferences = progress.references, !progressReferences.isEmpty {
            progressReferences.forEach { item in
                let reference = ConversationReference(
                    uri: item.uri,
                    status: .included,
                    kind: .other
                )
                references.append(reference)
            }
        }
        
        if content.isEmpty && references.isEmpty {
            return
        }
        
        // create immutable copies
        let messageContent = content
        let messageReferences = references

        Task {
            let message = ChatMessage(id: id, role: .assistant, content: messageContent, references: messageReferences)
            await memory.appendMessage(message)
        }
    }

    private func handleProgressEnd(token: String, progress: ConversationProgressEnd) {
        guard let workDoneToken = activeRequestId, workDoneToken == token else { return }
        let followUp = progress.followUp
        
        if let CLSError = progress.error {
            // CLS Error Code 402: reached monthly chat messages limit
            if CLSError.code == 402 {
                Task {
                    await Status.shared
                        .updateCLSStatus(.error, message: CLSError.message)
                    let errorMessage = ChatMessage(
                        id: progress.turnId,
                        role: .system,
                        content: CLSError.message
                    )
                    await memory.removeMessage(progress.turnId)
                    await memory.appendMessage(errorMessage)
                }
            } else {
                Task {
                    let errorMessage = ChatMessage(
                        id: progress.turnId,
                        role: .assistant,
                        content: "",
                        errorMessage: CLSError.message
                    )
                    await memory.appendMessage(errorMessage)
                }
            }
            resetOngoingRequest()
            return
        }
        
        Task {
            let message = ChatMessage(id: progress.turnId, role: .assistant, content: "", followUp: followUp, suggestedTitle: progress.suggestedTitle)
            await memory.appendMessage(message)
        }
        
        resetOngoingRequest()
    }
    
    private func resetOngoingRequest() {
        activeRequestId = nil
        isReceivingMessage = false
    }
    
    private func send(_ request: ConversationRequest) async throws {
        guard !isReceivingMessage else { throw CancellationError() }
        isReceivingMessage = true
        
        do {
            if let conversationId = conversationId {
                try await conversationProvider?.createTurn(with: conversationId, request: request)
            } else {
                try await conversationProvider?.createConversation(request)
            }
        } catch {
            resetOngoingRequest()
            throw error
        }
    }
}

