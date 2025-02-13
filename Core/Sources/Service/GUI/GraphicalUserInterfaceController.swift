import ActiveApplicationMonitor
import AppActivator
import AppKit
import ConversationTab
import ChatTab
import ComposableArchitecture
import Dependencies
import Preferences
import SuggestionBasic
import SuggestionWidget

#if canImport(ChatTabPersistent)
import ChatTabPersistent
#endif

@Reducer
struct GUI {
    @ObservableState
    struct State: Equatable {
        var suggestionWidgetState = WidgetFeature.State()

        var chatHistory: ChatHistory {
            get { suggestionWidgetState.chatPanelState.chatHistory }
            set { suggestionWidgetState.chatPanelState.chatHistory = newValue }
        }

        var promptToCodeGroup: PromptToCodeGroup.State {
            get { suggestionWidgetState.panelState.content.promptToCodeGroup }
            set { suggestionWidgetState.panelState.content.promptToCodeGroup = newValue }
        }
    }

    enum Action {
        case start
        case openChatPanel(forceDetach: Bool)
        case createAndSwitchToChatTabIfNeeded
//        case createAndSwitchToBrowserTabIfNeeded(url: URL)
        case sendCustomCommandToActiveChat(CustomCommand)
        case toggleWidgetsHotkeyPressed

        case suggestionWidget(WidgetFeature.Action)
        case switchWorkspace(path: String, name: String)
        case initWorkspaceChatTabIfNeeded(path: String)

        static func promptToCodeGroup(_ action: PromptToCodeGroup.Action) -> Self {
            .suggestionWidget(.panel(.sharedPanel(.promptToCodeGroup(action))))
        }

        #if canImport(ChatTabPersistent)
        case persistent(ChatTabPersistent.Action)
        #endif
    }

    @Dependency(\.chatTabPool) var chatTabPool
    @Dependency(\.activateThisApp) var activateThisApp

    public enum Debounce: Hashable {
        case updateChatTabOrder
    }

    var body: some ReducerOf<Self> {
        CombineReducers {
            Scope(state: \.suggestionWidgetState, action: \.suggestionWidget) {
                WidgetFeature()
            }

            Scope(
                state: \.chatHistory,
                action: \.suggestionWidget.chatPanel
            ) {
                Reduce { _, action in
                    switch action {
                    case let .createNewTapButtonClicked(kind):
//                        return .run { send in
//                            if let (_, chatTabInfo) = await chatTabPool.createTab(for: kind) {
//                                await send(.createNewTab(chatTabInfo))
//                            }
//                        }
                        return .run { send in
                            if let (_, chatTabInfo) = await chatTabPool.createTab(for: kind) {
                                await send(.appendAndSelectTab(chatTabInfo))
                            }
                        }

//                    case let .closeTabButtonClicked(id):
//                        return .run { _ in
//                            chatTabPool.removeTab(of: id)
//                        }

                    case let .chatTab(_, .openNewTab(builder)):
                        return .run { send in
                            if let (_, chatTabInfo) = await chatTabPool
                                .createTab(from: builder.chatTabBuilder)
                            {
                                await send(.appendAndSelectTab(chatTabInfo))
                            }
                        }

                    default:
                        return .none
                    }
                }
            }

            #if canImport(ChatTabPersistent)
            Scope(state: \.persistentState, action: \.persistent) {
                ChatTabPersistent()
            }
            #endif

            Reduce { state, action in
                switch action {
                case .start:
                    #if canImport(ChatTabPersistent)
                    return .run { send in
                        await send(.persistent(.restoreChatTabs))
                    }
                    #else
                    return .none
                    #endif

                case let .openChatPanel(forceDetach):
                    return .run { send in
                        await send(
                            .suggestionWidget(
                                .chatPanel(.presentChatPanel(forceDetach: forceDetach))
                            )
                        )
                        await send(.suggestionWidget(.updateKeyWindow(.chatPanel)))

                        activateThisApp()
                    }

                case .createAndSwitchToChatTabIfNeeded:
                    
                    if let currentChatWorkspace = state.chatHistory.currentChatWorkspace, let selectedTabInfo = currentChatWorkspace.selectedTabInfo,
                       chatTabPool.getTab(of: selectedTabInfo.id) is ConversationTab
                    {
                        // Already in Chat tab
                        return .none
                    }

                    if let firstChatTabInfo = state.chatHistory.currentChatWorkspace?.tabInfo.first(where: {
                        chatTabPool.getTab(of: $0.id) is ConversationTab
                    }) {
                        return .run { send in
                            await send(.suggestionWidget(.chatPanel(.tabClicked(
                                id: firstChatTabInfo.id
                            ))))
                        }
                    }
                    return .run { send in
                        if let (_, chatTabInfo) = await chatTabPool.createTab(for: nil) {
                            await send(
                                .suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo)))
                            )
                        }
                    }

                case let .switchWorkspace(path, name):
                    return .run { send in
                        await send(
                            .suggestionWidget(.chatPanel(.switchWorkspace(path, name)))
                        )
                        await send(.initWorkspaceChatTabIfNeeded(path: path))
                    }
                case let .initWorkspaceChatTabIfNeeded(path):
                    guard let chatWorkspace = state.chatHistory.workspaces[id: path], chatWorkspace.tabInfo.isEmpty
                            else { return .none }
                    return .run { send in
                        if let (_, chatTabInfo) = await chatTabPool.createTab(for: nil) {
                            await send(
                                .suggestionWidget(.chatPanel(.appendTabToWorkspace(chatTabInfo, chatWorkspace)))
                                )
                        }
                    }
//                case let .createAndSwitchToBrowserTabIfNeeded(url):
//                    #if canImport(BrowserChatTab)
//                    func match(_ tabURL: URL?) -> Bool {
//                        guard let tabURL else { return false }
//                        return tabURL == url
//                            || tabURL.absoluteString.hasPrefix(url.absoluteString)
//                    }
//
//                    if let selectedTabInfo = state.chatTabGroup.selectedTabInfo,
//                       let tab = chatTabPool.getTab(of: selectedTabInfo.id) as? BrowserChatTab,
//                       match(tab.url)
//                    {
//                        // Already in the target Browser tab
//                        return .none
//                    }
//
//                    if let firstChatTabInfo = state.chatTabGroup.tabInfo.first(where: {
//                        guard let tab = chatTabPool.getTab(of: $0.id) as? BrowserChatTab,
//                              match(tab.url)
//                        else { return false }
//                        return true
//                    }) {
//                        return .run { send in
//                            await send(.suggestionWidget(.chatPanel(.tabClicked(
//                                id: firstChatTabInfo.id
//                            ))))
//                        }
//                    }
//
//                    return .run { send in
//                        if let (_, chatTabInfo) = await chatTabPool.createTab(
//                            for: .init(BrowserChatTab.urlChatBuilder(
//                                url: url,
//                                externalDependency: ChatTabFactory
//                                    .externalDependenciesForBrowserChatTab()
//                            ))
//                        ) {
//                            await send(
//                                .suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo)))
//                            )
//                        }
//                    }
//
//                    #else
//                    return .none
//                    #endif

                case let .sendCustomCommandToActiveChat(command):
                    @Sendable func stopAndHandleCommand(_ tab: ConversationTab) async {
                        if tab.service.isReceivingMessage {
                            await tab.service.stopReceivingMessage()
                        }
                        try? await tab.service.handleCustomCommand(command)
                    }

                    if let info = state.chatHistory.currentChatWorkspace?.selectedTabInfo,
                       let activeTab = chatTabPool.getTab(of: info.id) as? ConversationTab
                    {
                        return .run { send in
                            await send(.openChatPanel(forceDetach: false))
                            await stopAndHandleCommand(activeTab)
                        }
                    }

                    if var chatWorkspace = state.chatHistory.currentChatWorkspace, let info = chatWorkspace.tabInfo.first(where: {
                        chatTabPool.getTab(of: $0.id) is ConversationTab
                    }),
                        let chatTab = chatTabPool.getTab(of: info.id) as? ConversationTab
                    {
                        chatWorkspace.selectedTabId = chatTab.id
                        let updatedChatWorkspace = chatWorkspace
                        return .run { send in
                            await send(.suggestionWidget(.chatPanel(.updateChatHistory(updatedChatWorkspace))))
                            await send(.openChatPanel(forceDetach: false))
                            await stopAndHandleCommand(chatTab)
                        }
                    }

                    return .run { send in
                        guard let (chatTab, chatTabInfo) = await chatTabPool.createTab(for: nil)
                        else {
                            return
                        }
                        await send(.suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo))))
                        await send(.openChatPanel(forceDetach: false))
                        if let chatTab = chatTab as? ConversationTab {
                            await stopAndHandleCommand(chatTab)
                        }
                    }

                case .toggleWidgetsHotkeyPressed:
                    return .run { send in
                        await send(.suggestionWidget(.circularWidget(.widgetClicked)))
                    }

                case let .suggestionWidget(.chatPanel(.chatTab(id, .tabContentUpdated))):
                    #if canImport(ChatTabPersistent)
                    // when a tab is updated, persist it.
                    return .run { send in
                        await send(.persistent(.chatTabUpdated(id: id)))
                    }
                    #else
                    return .none
                    #endif

//                case let .suggestionWidget(.chatPanel(.closeTabButtonClicked(id))):
//                    #if canImport(ChatTabPersistent)
//                    // when a tab is closed, remove it from persistence.
//                    return .run { send in
//                        await send(.persistent(.chatTabClosed(id: id)))
//                    }
//                    #else
//                    return .none
//                    #endif

                case .suggestionWidget:
                    return .none

                #if canImport(ChatTabPersistent)
                case .persistent:
                    return .none
                #endif
                }
            }
        }
//        .onChange(of: \.chatCollection.selectedChatGroup?.tabInfo) { old, new in
//            Reduce { _, _ in
//                guard old.map(\.id) != new.map(\.id) else {
//                    return .none
//                }
//                #if canImport(ChatTabPersistent)
//                return .run { send in
//                    await send(.persistent(.chatOrderChanged))
//                }.debounce(id: Debounce.updateChatTabOrder, for: 1, scheduler: DispatchQueue.main)
//                #else
//                return .none
//                #endif
//            }
//        }
    }
}

@MainActor
public final class GraphicalUserInterfaceController {
    let store: StoreOf<GUI>
    let widgetController: SuggestionWidgetController
    let widgetDataSource: WidgetDataSource
    let chatTabPool: ChatTabPool

    class WeakStoreHolder {
        weak var store: StoreOf<GUI>?
    }

    init() {
        let chatTabPool = ChatTabPool()
        let suggestionDependency = SuggestionWidgetControllerDependency()
        let setupDependency: (inout DependencyValues) -> Void = { dependencies in
            dependencies.suggestionWidgetControllerDependency = suggestionDependency
            dependencies.suggestionWidgetUserDefaultsObservers = .init()
            dependencies.chatTabPool = chatTabPool
            dependencies.chatTabBuilderCollection = ChatTabFactory.chatTabBuilderCollection
            dependencies.promptToCodeAcceptHandler = { promptToCode in
                Task {
                    let handler = PseudoCommandHandler()
                    await handler.acceptPromptToCode()
                    if !promptToCode.isContinuous {
                        NSWorkspace.activatePreviousActiveXcode()
                    } else {
                        NSWorkspace.activateThisApp()
                    }
                }
            }
        }
        let store = StoreOf<GUI>(
            initialState: .init(),
            reducer: { GUI() },
            withDependencies: setupDependency
        )
        self.store = store
        self.chatTabPool = chatTabPool
        widgetDataSource = .init()

        widgetController = SuggestionWidgetController(
            store: store.scope(
                state: \.suggestionWidgetState,
                action: \.suggestionWidget
            ),
            chatTabPool: chatTabPool,
            dependency: suggestionDependency
        )

        chatTabPool.createStore = { id in
            store.scope(
                state: { state in
                    state.chatHistory.currentChatWorkspace?.tabInfo[id: id] ?? .init(id: id, title: "")
                },
                action: { childAction in
                    .suggestionWidget(.chatPanel(.chatTab(id: id, action: childAction)))
                }
            )
        }

        suggestionDependency.suggestionWidgetDataSource = widgetDataSource
        suggestionDependency.onOpenChatClicked = { [weak self] in
            Task { [weak self] in
                await self?.store.send(.createAndSwitchToChatTabIfNeeded).finish()
                self?.store.send(.openChatPanel(forceDetach: false))
            }
        }
        suggestionDependency.onCustomCommandClicked = { command in
            Task {
                let commandHandler = PseudoCommandHandler()
                await commandHandler.handleCustomCommand(command)
            }
        }
    }

    func start() {
        store.send(.start)
    }

    public func openGlobalChat() {
        PseudoCommandHandler().openChat(forceDetach: true)
    }
}

extension ChatTabPool {
    @MainActor
    func createTab(
        id: String = UUID().uuidString,
        from builder: ChatTabBuilder
    ) async -> (any ChatTab, ChatTabInfo)? {
        let id = id
        let info = ChatTabInfo(id: id, title: "")
        guard let chatTap = await builder.build(store: createStore(id)) else { return nil }
        setTab(chatTap)
        return (chatTap, info)
    }

    @MainActor
    func createTab(
        for kind: ChatTabKind?
    ) async -> (any ChatTab, ChatTabInfo)? {
        let id = UUID().uuidString
        let info = ChatTabInfo(id: id, title: "")
        guard let builder = kind?.builder else {
            let chatTap = ConversationTab(store: createStore(id))
            setTab(chatTap)
            return (chatTap, info)
        }
        
        guard let chatTap = await builder.build(store: createStore(id)) else { return nil }
        setTab(chatTap)
        return (chatTap, info)
    }
}

