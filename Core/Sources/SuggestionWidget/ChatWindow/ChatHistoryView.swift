import ActiveApplicationMonitor
import ConversationTab
import AppKit
import ComposableArchitecture
import SwiftUI
import ChatTab
import SharedUIComponents


struct ChatHistoryView: View {
    let store: StoreOf<ChatPanelFeature>
    @Environment(\.chatTabPool) var chatTabPool
    @Binding var isChatHistoryVisible: Bool
    @State private var searchText = ""
    
    var body: some View {
        WithPerceptionTracking {
            let _ = store.currentChatWorkspace?.tabInfo

            VStack(alignment: .center, spacing: 0) {
                Header(isChatHistoryVisible: $isChatHistoryVisible)
                    .frame(height: 32)
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                
                Divider()
                
                ChatHistorySearchBarView(searchText: $searchText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                
                ItemView(store: store, searchText: $searchText, isChatHistoryVisible: $isChatHistoryVisible)
                    .padding(.horizontal, 16)
            }
        }
    }
    
    struct Header: View {
        @Binding var isChatHistoryVisible: Bool
        @AppStorage(\.chatFontSize) var chatFontSize
        
        var body: some View {
            HStack {
                Text("Chat History")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(nil)
                
                Spacer()
                
                Button(action: {
                    isChatHistoryVisible = false
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(HoverButtonStyle())
                .help("Close")
            }
        }
    }
    
    struct ItemView: View {
        let store: StoreOf<ChatPanelFeature>
        @Binding var searchText: String
        @Binding var isChatHistoryVisible: Bool
        
        @Environment(\.chatTabPool) var chatTabPool
        
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredTabInfo, id: \.id) { info in
                        if let tab = chatTabPool.getTab(of: info.id){
                            ChatHistoryItemView(
                                store: store,
                                info: info,
                                content: { tab.chatConversationItem },
                                isChatHistoryVisible: $isChatHistoryVisible
                            )
                            .id(info.id)
                            .frame(height: 49)
                        }
                        else {
                            EmptyView()
                        }
                    }
                }
            }
        }
        
        var filteredTabInfo: IdentifiedArray<String, ChatTabInfo> {
            guard let tabInfo = store.currentChatWorkspace?.tabInfo else {
                return []
            }

            guard !searchText.isEmpty else { return tabInfo }
            let result = tabInfo.filter { info in
                if let tab = chatTabPool.getTab(of: info.id),
                   let conversationTab = tab as? ConversationTab {
                    return conversationTab.getChatTabTitle().localizedCaseInsensitiveContains(searchText)
                }
                
                return false
            }
            return result
        }
    }
}


struct ChatHistorySearchBarView: View {
    @Binding var searchText: String
    @FocusState private var isSearchBarFocused: Bool
    
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .focused($isSearchBarFocused)
                .foregroundColor(searchText.isEmpty ? Color(nsColor: .placeholderTextColor) : Color(nsColor: .textColor))
        }
        .cornerRadius(10)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
        )
        .onAppear {
            isSearchBarFocused = true
        }
    }
}

struct ChatHistoryItemView<Content: View>: View {
    let store: StoreOf<ChatPanelFeature>
    let info: ChatTabInfo
    let content: () -> Content
    @Binding var isChatHistoryVisible: Bool
    @State private var isHovered = false
    
    func isTabSelected() -> Bool {
        return store.state.currentChatWorkspace?.selectedTabId == info.id
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 8) {
                    content()
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(1)
                        .hoverPrimaryForeground(isHovered: isHovered)
                    
                    if isTabSelected() {
                        Text("Current")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if !isTabSelected() {
                    if isHovered {
                        Button(action: {
                            store.send(.chatHisotryDeleteButtonClicked(id: info.id))
                        }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(HoverButtonStyle())
                        .help("Delete")
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)
        .onHover(perform: {
            isHovered = $0
        })
        .hoverRadiusBackground(isHovered: isHovered, cornerRadius: 4)
        .onTapGesture {
            store.send(.chatHistoryItemClicked(id: info.id))
            isChatHistoryVisible = false
        }
    }
}

struct ChatHistoryView_Previews: PreviewProvider {
    static let pool = ChatTabPool([
        "2": EmptyChatTab(id: "2"),
        "3": EmptyChatTab(id: "3"),
        "4": EmptyChatTab(id: "4"),
        "5": EmptyChatTab(id: "5"),
        "6": EmptyChatTab(id: "6")
    ])

    static func createStore() -> StoreOf<ChatPanelFeature> {
        StoreOf<ChatPanelFeature>(
            initialState: .init(
                chatHistory: .init(
                    workspaces: [.init(
                        id: "activeWorkspacePath",
                        tabInfo: [
                            .init(id: "2", title: "Empty-2"),
                            .init(id: "3", title: "Empty-3"),
                            .init(id: "4", title: "Empty-4"),
                            .init(id: "5", title: "Empty-5"),
                            .init(id: "6", title: "Empty-6")
                        ] as IdentifiedArray<String, ChatTabInfo>,
                        selectedTabId: "2"
                    )] as IdentifiedArray<String, ChatWorkspace>,
                    selectedWorkspacePath: "activeWorkspacePath",
                    selectedWorkspaceName: "activeWorkspacePath"
                ),
                isPanelDisplayed: true
            ),
            reducer: { ChatPanelFeature() }
        )
    }

    static var previews: some View {
        ChatHistoryView(
            store: createStore(),
            isChatHistoryVisible: .constant(true)
            )
            .xcodeStyleFrame()
            .padding()
            .environment(\.chatTabPool, pool)
    }
}
