import Combine
import FileChangeChecker
import GitHubCopilotService
import LaunchAgentManager
import Logger
import Preferences
import Service
import ServiceManagement
import Status
import SwiftUI
import UpdateChecker
import UserDefaultsObserver
import UserNotifications
import XcodeInspector
import XPCShared
import GitHubCopilotViewModel
import StatusBarItemView

let bundleIdentifierBase = Bundle.main
    .object(forInfoDictionaryKey: "BUNDLE_IDENTIFIER_BASE") as! String
let serviceIdentifier = bundleIdentifierBase + ".ExtensionService"

class ExtensionUpdateCheckerDelegate: UpdateCheckerDelegate {
    func prepareForRelaunch(finish: @escaping () -> Void) {
        Task {
            await Service.shared.prepareForExit()
            finish()
        }
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let service = Service.shared
    var statusBarItem: NSStatusItem!
    var extensionStatusItem: NSMenuItem!
    var accountItem: NSMenuItem!
    var authStatusItem: NSMenuItem!
    var upSellItem: NSMenuItem!
    var toggleCompletions: NSMenuItem!
    var toggleIgnoreLanguage: NSMenuItem!
    var openChat: NSMenuItem!
    var signOutItem: NSMenuItem!
    var xpcController: XPCController?
    let updateChecker =
        UpdateChecker(
            hostBundle: Bundle(url: locateHostBundleURL(url: Bundle.main.bundleURL)),
            checkerDelegate: ExtensionUpdateCheckerDelegate()
        )
    var xpcExtensionService: XPCExtensionService?
    private var cancellables = Set<AnyCancellable>()
    private var progressView: NSProgressIndicator?

    func applicationDidFinishLaunching(_: Notification) {
        if ProcessInfo.processInfo.environment["IS_UNIT_TEST"] == "YES" { return }
        _ = XcodeInspector.shared
        service.start()
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true,
        ] as CFDictionary)
        setupQuitOnUpdate()
        setupQuitOnUserTerminated()
        xpcController = .init()
        Logger.service.info("XPC Service started.")
        NSApp.setActivationPolicy(.accessory)
        buildStatusBarMenu()
        watchServiceStatus()
        watchAXStatus()
        watchAuthStatus()
        setInitialStatusBarStatus()
        UserDefaults.shared.set(false, for: \.clsWarningDismissedUntilRelaunch)
    }

    @objc func quit() {
        Task { @MainActor in
            await service.prepareForExit()
            await xpcController?.quit()
            NSApp.terminate(self)
        }
    }

    @objc func openCopilotForXcode() {
        let task = Process()
        let appPath = locateHostBundleURL(url: Bundle.main.bundleURL)
        task.launchPath = "/usr/bin/open"
        task.arguments = [appPath.absoluteString]
        task.launch()
        task.waitUntilExit()
    }
    
    @objc func signIntoGitHub() {
        Task { @MainActor in
            let viewModel = GitHubCopilotViewModel.shared
            // Don't trigger the shared viewModel's alert
            do {
                guard let signInResponse = try await viewModel.preSignIn() else {
                    return
                }

                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = signInResponse.userCode
                alert.informativeText = """
                Please enter the above code in the GitHub website to authorize your \
                GitHub account with Copilot for Xcode.
                \(signInResponse.verificationURL.absoluteString)
                """
                alert.addButton(withTitle: "Copy Code and Open")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    viewModel.signInResponse = signInResponse
                    viewModel.copyAndOpen()
                }
            } catch {
                Logger.service.error("GitHub copilot view model Sign in fails: \(error)")
            }
        }
    }
    
    @objc func signOutGitHub() {
        Task { @MainActor in
            let viewModel = GitHubCopilotViewModel.shared
            viewModel.signOut()
        }
    }

    @objc func openGlobalChat() {
        Task { @MainActor in
            let serviceGUI = Service.shared.guiController
            serviceGUI.openGlobalChat()
        }
    }

    func setupQuitOnUpdate() {
        Task {
            guard let url = Bundle.main.executableURL else { return }
            let checker = await FileChangeChecker(fileURL: url)

            // If Xcode or Copilot for Xcode is made active, check if the executable of this program
            // is changed. If changed, quit this program.

            let sequence = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didActivateApplicationNotification)
            for await notification in sequence {
                try Task.checkCancellation()
                guard let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.isUserOfService
                else { continue }
                guard await checker.checkIfChanged() else {
                    Logger.service.info("Extension Service is not updated, no need to quit.")
                    continue
                }
                Logger.service.info("Extension Service will quit.")
                #if DEBUG
                #else
                quit()
                #endif
            }
        }
    }

    func setupQuitOnUserTerminated() {
        Task {
            // Whenever Xcode or the host application quits, check if any of the two is running.
            // If none, quit the XPC service.

            let sequence = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didTerminateApplicationNotification)
            for await notification in sequence {
                try Task.checkCancellation()
                guard UserDefaults.shared.value(for: \.quitXPCServiceOnXcodeAndAppQuit)
                else { continue }
                guard let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.isUserOfService
                else { continue }
                if NSWorkspace.shared.runningApplications.contains(where: \.isUserOfService) {
                    continue
                }
                quit()
            }
        }
    }

    func requestAccessoryAPIPermission() {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true,
        ] as NSDictionary)
    }

    @objc func checkForUpdate() {
        guard let updateChecker = updateChecker else {
            Logger.service.error("Unable to check for updates: updateChecker is nil.")
            return
        }
        updateChecker.checkForUpdates()
    }

    func getXPCExtensionService() -> XPCExtensionService {
        if let service = xpcExtensionService { return service }
        let service = XPCExtensionService(logger: .service)
        xpcExtensionService = service
        return service
    }

    func watchServiceStatus() {
        let notifications = NotificationCenter.default.notifications(named: .serviceStatusDidChange)
        Task { [weak self] in
            for await _ in notifications {
                guard let self else { return }
                self.updateStatusBarItem()
            }
        }
    }

    func watchAXStatus() {
        let osNotifications = DistributedNotificationCenter.default().notifications(named: NSNotification.Name("com.apple.accessibility.api"))
        Task { [weak self] in
            for await _ in osNotifications {
                guard let self else { return }
                self.updateStatusBarItem()
            }
        }
    }

    func watchAuthStatus() {
        let notifications = DistributedNotificationCenter.default().notifications(named: .authStatusDidChange)
        Task { [weak self] in
            for await _ in notifications {
                guard let self else { return }
                await self.forceAuthStatusCheck()
            }
        }
    }

    func setInitialStatusBarStatus() {
        Task {
            let authStatus = await Status.shared.getAuthStatus()
            if authStatus == .unknown {
                // temporarily kick off a language server instance to prime the initial auth status
                await forceAuthStatusCheck()
            }
            updateStatusBarItem()
        }
    }

    func forceAuthStatusCheck() async {
        do {
            let service = try GitHubCopilotService()
            _ = try await service.checkStatus()
            try await service.shutdown()
            try await service.exit()
        } catch {
            Logger.service.error("Failed to read auth status: \(error)")
        }
    }
    
    private func configureNotLoggedIn() {
        self.accountItem.view = AccountItemView(
            target: self,
            action: #selector(signIntoGitHub)
        )
        self.authStatusItem.isHidden = true
        self.upSellItem.isHidden = true
        self.toggleCompletions.isHidden = true
        self.toggleIgnoreLanguage.isHidden = true
        self.openChat.isHidden = true
        self.signOutItem.isHidden = true
    }

    private func configureLoggedIn(status: StatusResponse) {
        self.accountItem.view = AccountItemView(
            target: self,
            action: nil,
            userName: status.userName ?? ""
        )
        if !status.clsMessage.isEmpty {
            self.authStatusItem.isHidden = false
            let CLSMessageSummary = getCLSMessageSummary(status.clsMessage)
            self.authStatusItem.title = CLSMessageSummary.summary
            
            let submenu = NSMenu()
            let attributedCLSErrorItem = NSMenuItem()
            attributedCLSErrorItem.view = ErrorMessageView(
                errorMessage: CLSMessageSummary.detail
            )
            submenu.addItem(attributedCLSErrorItem)
            submenu.addItem(.separator())
            submenu.addItem(
                NSMenuItem(
                    title: "View Details on GitHub",
                    action: #selector(openGitHubDetailsLink),
                    keyEquivalent: ""
                )
            )
            
            self.authStatusItem.submenu = submenu
            self.authStatusItem.isEnabled = true
            
            self.upSellItem.title = "Upgrade Now"
            self.upSellItem.isHidden = false
            self.upSellItem.isEnabled = true
        } else {
            self.authStatusItem.isHidden = true
            self.upSellItem.isHidden = true
        }
        self.toggleCompletions.isHidden = false
        self.toggleIgnoreLanguage.isHidden = false
        self.openChat.isHidden = false
        self.signOutItem.isHidden = false
    }

    private func configureNotAuthorized(status: StatusResponse) {
        self.accountItem.view = AccountItemView(
            target: self,
            action: nil,
            userName: status.userName ?? ""
        )
        self.authStatusItem.isHidden = false
        self.authStatusItem.title = "No Subscription"
        
        let submenu = NSMenu()
        let attributedNotAuthorizedItem = NSMenuItem()
        attributedNotAuthorizedItem.view = ErrorMessageView(
            errorMessage: "GitHub Copilot features are disabled. Check your subscription to enable them."
        )
        attributedNotAuthorizedItem.isEnabled = true
        submenu.addItem(attributedNotAuthorizedItem)
        
        self.authStatusItem.submenu = submenu
        self.authStatusItem.isEnabled = true
        
        self.upSellItem.title = "Check Subscription Plans"
        self.upSellItem.isHidden = false
        self.upSellItem.isEnabled = true
        self.toggleCompletions.isHidden = true
        self.toggleIgnoreLanguage.isHidden = true
        self.openChat.isHidden = true
        self.signOutItem.isHidden = false
    }

    private func configureUnknown() {
        self.accountItem.view = AccountItemView(
            target: self,
            action: nil,
            userName: "Unknown User"
        )
        self.authStatusItem.isHidden = true
        self.upSellItem.isHidden = true
        self.toggleCompletions.isHidden = false
        self.toggleIgnoreLanguage.isHidden = false
        self.openChat.isHidden = false
        self.signOutItem.isHidden = false
    }

    func updateStatusBarItem() {
        Task { @MainActor in
            let status = await Status.shared.getStatus()
            self.statusBarItem.button?.image = status.icon.nsImage
            switch status.authStatus {
            case .notLoggedIn: configureNotLoggedIn()
            case .loggedIn: configureLoggedIn(status: status)
            case .notAuthorized: configureNotAuthorized(status: status)
            case .unknown: configureUnknown()
            }
            if let message = status.message {
                self.extensionStatusItem.title = message
                self.extensionStatusItem.isHidden = false
                self.extensionStatusItem.isEnabled = status.url != nil
            } else {
                self.extensionStatusItem.isHidden = true
            }
            self.markAsProcessing(status.inProgress)
        }
    }

    func markAsProcessing(_ isProcessing: Bool) {
        if !isProcessing {
            // No longer in progress
            progressView?.removeFromSuperview()
            progressView = nil
            return
        }
        if progressView != nil {
            // Already in progress
            return
        }
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.sizeToFit()
        progress.frame = statusBarItem.button?.bounds ?? .zero
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        statusBarItem.button?.addSubview(progress)
        statusBarItem.button?.image = nil
        progressView = progress
    }
    
    @objc func openGitHubDetailsLink() {
        Task {
            if let url = URL(string: "https://github.com/copilot") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension NSRunningApplication {
    var isUserOfService: Bool {
        [
            "com.apple.dt.Xcode",
            bundleIdentifierBase,
        ].contains(bundleIdentifier)
    }
}

func locateHostBundleURL(url: URL) -> URL {
    var nextURL = url
    while nextURL.path != "/" {
        nextURL = nextURL.deletingLastPathComponent()
        if nextURL.lastPathComponent.hasSuffix(".app") {
            return nextURL
        }
    }
    let devAppURL = url
        .deletingLastPathComponent()
        .appendingPathComponent("GitHub Copilot for Xcode Dev.app")
    return devAppURL
}

struct CLSMessage {
    let summary: String
    let detail: String
}

func extractDateFromCLSMessage(_ message: String) -> String? {
    let pattern = #"until (\d{1,2}/\d{1,2}/\d{4}, \d{1,2}:\d{2}:\d{2} [AP]M)"#
    if let range = message.range(of: pattern, options: .regularExpression) {
        return String(message[range].dropFirst(6))
    }
    return nil
}

func getCLSMessageSummary(_ message: String) -> CLSMessage {
    let summary: String
    if message.contains("You've reached your monthly chat messages limit") {
        summary = "Monthly Chat Limit Reached"
    } else if message.contains("You've reached your monthly code completion limit") {
        summary = "Monthly Completion Limit Reached"
    } else {
        summary = "CLS Error"
    }
    
    let detail: String
    if let date = extractDateFromCLSMessage(message) {
        detail = "Visit GitHub to check your usage and upgrade to Copilot Pro or wait until \(date) for your limit to reset."
    } else {
        detail = message
    }
    
    return CLSMessage(summary: summary, detail: detail)
}
