import Foundation
import TelemetryServiceProvider

public class GitHubPanicErrorReporter {
    private static let panicEndpoint = URL(string: "https://copilot-telemetry.githubusercontent.com/telemetry")!
    private static let sessionId = UUID().uuidString
    private static let standardChannelKey = Bundle.main
        .object(forInfoDictionaryKey: "STANDARD_TELEMETRY_CHANNEL_KEY") as! String
    
    // Helper: Format current time in ISO8601 style
    private static func currentTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSX"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
    
    // Helper: Create failbot payload JSON string and update properties
    private static func createFailbotPayload(
        for request: TelemetryExceptionRequest,
        properties: inout [String: Any]
    ) -> String? {
        let payload: [String: Any] = [
            "context": [:],
            "app": "copilot-xcode",
            "catalog_service": "CopilotXcode",
            "release": "copilot-xcode@\(properties["common_extversion"] ?? "0.0.0")",
            "rollup_id": "auto",
            "platform": "macOS",
            "exception_detail": request.exceptionDetail?.toDictionary() ?? []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    // Helper: Create payload with a channel input, but always using standard telemetry key.
    private static func createPayload(
        for request: TelemetryExceptionRequest,
        properties: inout [String: Any]
    ) -> [String: Any] {
        // Build and add failbot payload to properties
        if let payloadString = createFailbotPayload(for: request, properties: &properties) {
            properties["failbot_payload"] = payloadString
        }
        properties["common_vscodesessionid"] = sessionId
        properties["client_sessionid"] = sessionId
        
        let baseData: [String: Any] = [
            "ver": 2,
            "severityLevel": "Error",
            "name": "agent/error.exception",
            "properties": properties,
            "exceptions": [],
            "measurements": [:]
        ]
        
        return [
            "ver": 1,
            "time": currentTime(),
            "severityLevel": "Error",
            "name": "Microsoft.ApplicationInsights.standard.Event",
            "iKey": standardChannelKey,
            "data": [
                "baseData": baseData,
                "baseType": "ExceptionData"
            ]
        ]
    }
    
    public static func report(_ request: TelemetryExceptionRequest) async {
        do {
            var properties: [String : Any] = request.properties ?? [:]
            let payload = createPayload(
                for: request,
                properties: &properties
            )

            let jsonData = try JSONSerialization.data(withJSONObject: [payload], options: [])
            var httpRequest = URLRequest(url: panicEndpoint)
            httpRequest.httpMethod = "POST"
            httpRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            httpRequest.httpBody = jsonData

            let (_, response) = try await URLSession.shared.data(for: httpRequest)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
        } catch {
            print("Fails to send to Panic Endpoint: \(error)")
        }
    }
}
