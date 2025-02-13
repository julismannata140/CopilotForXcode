import ConversationServiceProvider
import XcodeInspector
import Foundation
import Logger

public let supportedFileExtensions: Set<String> = ["swift", "m", "mm", "h", "cpp", "c", "js", "py", "rb", "java", "applescript", "scpt", "plist", "entitlements"]
private let skipPatterns: [String] = [
    ".git",
    ".svn",
    ".hg",
    "CVS",
    ".DS_Store",
    "Thumbs.db",
    "node_modules",
    "bower_components"
]

public struct ContextUtils {
    static func matchesPatterns(_ url: URL, patterns: [String]) -> Bool {
        let fileName = url.lastPathComponent
        for pattern in patterns {
            if fnmatch(pattern, fileName, 0) == 0 {
                return true
            }
        }
        return false
    }

    public static func getFilesInActiveWorkspace() -> [FileReference] {
        guard let workspaceURL = XcodeInspector.shared.realtimeActiveWorkspaceURL,
              let projectURL = XcodeInspector.shared.realtimeActiveProjectURL else {
            return []
        }

        do {
            let fileManager = FileManager.default
            let enumerator = fileManager.enumerator(
                at: projectURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var files: [FileReference] = []
            while let fileURL = enumerator?.nextObject() as? URL {
                // Skip items matching the specified pattern
                if matchesPatterns(fileURL, patterns: skipPatterns) {
                    enumerator?.skipDescendants()
                    continue
                }

                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                // Handle directories if needed
                if resourceValues.isDirectory == true {
                    continue
                }

                guard resourceValues.isRegularFile == true else { continue }
                if supportedFileExtensions.contains(fileURL.pathExtension.lowercased()) == false {
                    continue
                }

                let relativePath = fileURL.path.replacingOccurrences(of: projectURL.path, with: "")
                let fileName = fileURL.lastPathComponent

                let file = FileReference(url: fileURL,
                                           relativePath: relativePath,
                                           fileName: fileName)
                files.append(file)
            }

            return files
        } catch {
            Logger.client.error("Failed to get files in workspace: \(error)")
            return []
        }
    }
}
