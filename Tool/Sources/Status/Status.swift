import AppKit
import Foundation

public enum ExtensionPermissionStatus {
    case unknown
    case succeeded
    case failed
}

@objc public enum ObservedAXStatus: Int {
    case unknown = -1
    case granted = 1
    case notGranted = 0
}

public struct CLSStatus: Equatable {
    public enum Status {
            case unknown, normal, inProgress, error, warning, inactive
        }

    public let status: Status
    public let message: String

    public var isInactiveStatus: Bool {
        status == .inactive && !message.isEmpty
    }

    public var isErrorStatus: Bool {
        (status == .warning || status == .error) && !message.isEmpty
    }
}

public struct AuthStatus: Equatable {
    public enum Status {
            case unknown, loggedIn, notLoggedIn, notAuthorized
        }

    public let status: Status
    public let username: String?
    public let message: String?
}

private struct AuthStatusInfo {
    let authIcon: StatusResponse.Icon?
    let authStatus: AuthStatus.Status
    let userName: String?
}

private struct CLSStatusInfo {
    let icon: StatusResponse.Icon?
    let message: String
}

private struct ExtensionStatusInfo {
    let icon: StatusResponse.Icon?
    let message: String?
    let url: String?
}

public extension Notification.Name {
    static let authStatusDidChange = Notification.Name("com.github.CopilotForXcode.authStatusDidChange")
    static let serviceStatusDidChange = Notification.Name("com.github.CopilotForXcode.serviceStatusDidChange")
}

public struct StatusResponse {
    public struct Icon {
        public let name: String
        // isTemplate = true, monochrome icon; isTemplate = false, colored icon
        public let isTemplate: Bool

        public init(name: String, isTemplate: Bool = true) {
            self.name = name
            self.isTemplate = isTemplate
        }

        public var nsImage: NSImage? {
            let image = NSImage(named: name)
            image?.isTemplate = isTemplate
            return image
        }
    }

    public let icon: Icon
    public let inProgress: Bool
    public let clsMessage: String
    public let message: String?
    public let url: String?
    public let authStatus: AuthStatus.Status
    public let userName: String?
}

public final actor Status {
    public static let shared = Status()

    private var extensionStatus: ExtensionPermissionStatus = .unknown
    private var axStatus: ObservedAXStatus = .unknown
    private var clsStatus = CLSStatus(status: .unknown, message: "")
    private var authStatus = AuthStatus(status: .unknown, username: nil, message: nil)

    private let okIcon = StatusResponse.Icon(name: "MenuBarIcon", isTemplate: false)
    private let errorIcon = StatusResponse.Icon(name: "MenuBarWarningIcon")
    private let inactiveIcon = StatusResponse.Icon(name: "MenuBarInactiveIcon")

    private init() {}

    public func updateExtensionStatus(_ status: ExtensionPermissionStatus) {
        guard status != extensionStatus else { return }
        extensionStatus = status
        broadcast()
    }

    public func updateAXStatus(_ status: ObservedAXStatus) {
        guard status != axStatus else { return }
        axStatus = status
        broadcast()
    }

    public func updateCLSStatus(_ status: CLSStatus.Status, message: String) {
        let newStatus = CLSStatus(status: status, message: message)
        guard newStatus != clsStatus else { return }
        clsStatus = newStatus
        broadcast()
    }

    public func updateAuthStatus(_ status: AuthStatus.Status, username: String? = nil, message: String? = nil) {
        let newStatus = AuthStatus(status: status, username: username, message: message)
        guard newStatus != authStatus else { return }
        authStatus = newStatus
        broadcast()
    }

    public func getAXStatus() -> ObservedAXStatus {
        if isXcodeRunning() {
            return axStatus
        } else if AXIsProcessTrusted() {
            return .granted
        } else {
            return axStatus
        }
    }

    private func isXcodeRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dt.Xcode"
        ).isEmpty
    }

    public func getAuthStatus() -> AuthStatus.Status {
        authStatus.status
    }

    public func getCLSStatus() -> CLSStatus {
        clsStatus
    }

    public func getStatus() -> StatusResponse {
        let authStatusInfo: AuthStatusInfo = getAuthStatusInfo()
        let clsStatusInfo: CLSStatusInfo = getCLSStatusInfo()
        let extensionStatusInfo: ExtensionStatusInfo = getExtensionStatusInfo()
        return .init(
            icon: authStatusInfo.authIcon ?? clsStatusInfo.icon ?? extensionStatusInfo.icon ?? okIcon,
            inProgress: clsStatus.status == .inProgress,
            clsMessage: clsStatus.message,
            message: extensionStatusInfo.message,
            url: extensionStatusInfo.url,
            authStatus: authStatusInfo.authStatus,
            userName: authStatusInfo.userName
        )
    }

    private func getAuthStatusInfo() -> AuthStatusInfo {
        switch authStatus.status {
        case .unknown, .loggedIn:
            return AuthStatusInfo(
                authIcon: nil,
                authStatus: authStatus.status,
                userName: authStatus.username
            )
        case .notLoggedIn:
            return AuthStatusInfo(
                authIcon: errorIcon,
                authStatus: authStatus.status,
                userName: nil
            )
        case .notAuthorized:
            return AuthStatusInfo(
                authIcon: inactiveIcon,
                authStatus: authStatus.status,
                userName: authStatus.username
            )
        }
    }
    
    private func getCLSStatusInfo() -> CLSStatusInfo {
        if clsStatus.isInactiveStatus {
            return CLSStatusInfo(icon: inactiveIcon, message: clsStatus.message)
        }
        if clsStatus.isErrorStatus {
            return CLSStatusInfo(icon: errorIcon, message: clsStatus.message)
        }
        return CLSStatusInfo(icon: nil, message: "")
    }

    private func getExtensionStatusInfo() -> ExtensionStatusInfo {
        if extensionStatus == .failed {
            return ExtensionStatusInfo(
                icon: errorIcon,
                message: """
                Enable Copilot in Xcode & restart
                """,
                url: "x-apple.systempreferences:com.apple.ExtensionsPreferences"
            )
        }

        switch getAXStatus() {
        case .granted:
            return ExtensionStatusInfo(icon: nil, message: nil, url: nil)
        case .notGranted:
            return ExtensionStatusInfo(
                icon: errorIcon,
                message: """
                Enable accessibility in system preferences
                """,
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        case .unknown:
            return ExtensionStatusInfo(
                icon: errorIcon,
                message: """
                Enable accessibility or restart Copilot
                """,
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .serviceStatusDidChange, object: nil)
        // Can remove DistributedNotificationCenter if the settings UI moves in-process
        DistributedNotificationCenter.default().post(name: .serviceStatusDidChange, object: nil)
    }
}
