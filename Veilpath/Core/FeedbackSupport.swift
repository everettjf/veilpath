import Foundation
import UIKit

struct ScreenshotFeedbackContext: Identifiable {
    let id = UUID()
    let screenshotURL: URL
    let previewImage: UIImage
    let screenDescription: String
}

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

    @MainActor
    static func captureCurrentWindow() throws -> (url: URL, image: UIImage) {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let window = windowScenes.lazy
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? windowScenes.lazy.flatMap(\.windows).first(where: { !$0.isHidden }) else {
            throw CaptureError.windowUnavailable
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { throw CaptureError.encodingFailed }
        let url = try ExportCache.stage(data, named: "Veilpath Screenshot \(UUID().uuidString).png")
        return (url, image)
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

    private enum CaptureError: LocalizedError {
        case windowUnavailable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .windowUnavailable: String(localized: "The current screen could not be captured.")
            case .encodingFailed: String(localized: "The screenshot could not be prepared for sharing.")
            }
        }
    }
}
