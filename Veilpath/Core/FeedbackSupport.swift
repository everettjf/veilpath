import Foundation
import UIKit

enum FeedbackSupport {
    static func issueURL(screenDescription: String? = nil) -> URL {
        var components = URLComponents(string: "https://github.com/everettjf/veilpath/issues/new")!
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let device = UIDevice.current
        let contextLine = screenDescription.map { "- Screen: \($0)\n" } ?? ""
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Feedback] "),
            URLQueryItem(
                name: "body",
                value: """


                ## Description


                ## Environment
                \(contextLine)- Device: \(device.model) (\(hardwareIdentifier))
                - Operating System: \(device.systemName) \(device.systemVersion)
                - System Build: \(ProcessInfo.processInfo.operatingSystemVersionString)
                - Veilpath: \(appVersion) (\(appBuild))

                If this report is related to a screenshot, please attach it here after reviewing it for sensitive information.
                """
            )
        ]
        return components.url ?? URL(string: "https://github.com/everettjf/veilpath/issues/new")!
    }

    private static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

}
