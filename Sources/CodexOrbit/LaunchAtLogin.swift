import AppKit
import ServiceManagement
import Combine

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }
    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }
    var statusCode: String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
    var description: String {
        if let errorMessage { return errorMessage }
        switch status {
        case .enabled: return "已开启：登录 Mac 后自动启动，保持在菜单栏运行。"
        case .requiresApproval: return "需要在系统设置的登录项中允许 Codex Orbit。"
        case .notRegistered: return "关闭时仅在手动打开应用后运行。"
        case .notFound: return "请确认应用位于「应用程序」目录后重试。"
        @unknown default: return "请在系统设置中检查登录项。"
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        do {
            if enabled {
                let path = Bundle.main.bundleURL.path
                let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
                guard path.hasPrefix("/Applications/") || path.hasPrefix(homeApplications) else {
                    errorMessage = "请先将应用安装到「应用程序」目录，再开启自启动。"
                    return
                }
                if status == .notRegistered || status == .notFound { try SMAppService.mainApp.register() }
            } else if status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let error = error as NSError
            errorMessage = "无法修改登录项（\(error.domain) \(error.code)），请在系统设置中检查。"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
