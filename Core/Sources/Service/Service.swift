import BuiltinExtension
import Combine
import Dependencies
import Foundation
import GitHubCopilotService
import KeyBindingManager
import Logger
import SuggestionService
import Toast
import Workspace
import WorkspaceSuggestionService
import XcodeInspector
import XcodeThemeController
import XPCShared
import SuggestionWidget

@globalActor public enum ServiceActor {
    public actor TheActor {}
    public static let shared = TheActor()
}

/// The running extension service.
public final class Service {
    public static let shared = Service()

    @WorkspaceActor
    let workspacePool: WorkspacePool
    @MainActor
    public let guiController = GraphicalUserInterfaceController()
    public let realtimeSuggestionController = RealtimeSuggestionController()
    public let scheduledCleaner: ScheduledCleaner
    let globalShortcutManager: GlobalShortcutManager
    let keyBindingManager: KeyBindingManager
    let xcodeThemeController: XcodeThemeController = .init()

    @Dependency(\.toast) var toast
    var cancellable = Set<AnyCancellable>()

    private init() {
        @Dependency(\.workspacePool) var workspacePool

        BuiltinExtensionManager.shared.setupExtensions([
            GitHubCopilotExtension(workspacePool: workspacePool)
        ])
        scheduledCleaner = .init()
        workspacePool.registerPlugin {
            SuggestionServiceWorkspacePlugin(workspace: $0) { SuggestionService.service() }
        }
        workspacePool.registerPlugin {
            GitHubCopilotWorkspacePlugin(workspace: $0)
        }
        workspacePool.registerPlugin {
            BuiltinExtensionWorkspacePlugin(workspace: $0)
        }
        self.workspacePool = workspacePool

        globalShortcutManager = .init(guiController: guiController)
        keyBindingManager = .init(
            workspacePool: workspacePool,
            acceptSuggestion: {
                Task { await PseudoCommandHandler().acceptSuggestion() }
            },
            expandSuggestion: {
                if !ExpandableSuggestionService.shared.isSuggestionExpanded {
                    ExpandableSuggestionService.shared.isSuggestionExpanded = true
                }
            },
            collapseSuggestion: {
                if ExpandableSuggestionService.shared.isSuggestionExpanded {
                    ExpandableSuggestionService.shared.isSuggestionExpanded = false
                }
            },
            dismissSuggestion: {
                Task { await PseudoCommandHandler().dismissSuggestion() }
            }
        )
        let scheduledCleaner = ScheduledCleaner()

        scheduledCleaner.service = self
        Logger.telemetryLogger = TelemetryLogger()
    }

    @MainActor
    public func start() {
        scheduledCleaner.start()
        realtimeSuggestionController.start()
        guiController.start()
        xcodeThemeController.start()
        globalShortcutManager.start()
        keyBindingManager.start()

        Task {
            await XcodeInspector.shared.safe.$activeDocumentURL
                .removeDuplicates()
                .filter { $0 != .init(fileURLWithPath: "/") }
                .compactMap { $0 }
                .sink { [weak self] fileURL in
                    Task {
                        do {
                            try await self?.workspacePool
                                .fetchOrCreateWorkspaceAndFilespace(fileURL: fileURL)
                        } catch {
                            Logger.workspacePool.error(error)
                        }
                    }
                }.store(in: &cancellable)
            
            await XcodeInspector.shared.safe.$activeWorkspaceURL.receive(on: DispatchQueue.main)
                .sink { newURL in
                    if let path = newURL?.path, self.guiController.store.chatHistory.selectedWorkspacePath != path {
                        let name = self.getDisplayNameOfXcodeWorkspace(url: newURL!)
                        self.guiController.store.send(.switchWorkspace(path: path, name: name))
                    }
                    
                }.store(in: &cancellable)
        }
    }

    @MainActor
    public func prepareForExit() async {
        Logger.service.info("Prepare for exit.")
        keyBindingManager.stopForExit()
        await scheduledCleaner.closeAllChildProcesses()
    }

    private func getDisplayNameOfXcodeWorkspace(url: URL) -> String {
        var name = url.lastPathComponent
        let suffixes = [".xcworkspace", ".xcodeproj"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }
}

public extension Service {
    func handleXPCServiceRequests(
        endpoint: String,
        requestBody: Data,
        reply: @escaping (Data?, Error?) -> Void
    ) {
        reply(nil, XPCRequestNotHandledError())
    }
}

