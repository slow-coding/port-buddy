//  Interface strings. Chinese when the system language is Chinese, English
//  otherwise; the list is short enough that a table would be more machinery
//  than the problem deserves.

import Foundation

enum L10n {
    /// Which language this process runs in. The bundle declares en and zh-Hans
    /// in CFBundleLocalizations, so macOS resolves the system language (and a
    /// per-app override in System Settings) down to one of them before we ever
    /// ask.
    static let language: String = {
        if let preferred = Bundle.main.preferredLocalizations.first {
            return preferred
        }
        return Locale.preferredLanguages.first ?? "en"
    }()

    private static let isChinese = language.hasPrefix("zh")

    static func t(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

    static var filterAll: String { t("All", "全部") }
    static var filterTip: String { t("Show one project or app", "只看某一个工程 / 应用") }

    static func filterByNameTip(_ name: String) -> String {
        t("Show only “\(name)” · click again to clear", "只看「\(name)」· 再点一下取消")
    }
    static var empty: String { t("Nothing of yours is listening", "你自己的进程没有在监听") }
    static var refreshTip: String { t("Refresh", "刷新") }
    static var terminate: String { t("Terminate", "终止") }
    static var terminateConfirm: String { t("Confirm", "确认") }
    static var killAll: String { t("Terminate all", "全部终止") }
    static var killAllConfirm: String { t("Confirm", "确认") }
    static var quit: String { t("Quit \(AppInfo.displayName)", "退出 \(AppInfo.displayName)") }

    static var settingsTitle: String { t("Settings", "设置") }
    static var settingsTip: String { t("Settings", "设置") }
    static var hotKeyLabel: String { t("Hot key that opens the panel", "打开面板的快捷键") }
    static var hotKeyHint: String {
        t("Click the field, then press the keys. Delete clears it.",
          "点一下输入框再按组合键；Delete 清除。")
    }
    static var noHotKey: String { t("Not set", "未设置") }
    static var recordingHotKey: String { t("Press keys…", "按下组合键…") }
    static var clearHotKey: String { t("Clear", "清除") }
    static var hotKeySaved: String { t("Saved", "已保存") }
    static var hotKeyConflict: String { t("That combination is taken by another app", "这个组合键已被别的应用占用") }
    static var hotKeyFailed: String { t("Could not register that combination", "注册这个组合键失败") }
    static var appearanceLabel: String { t("Appearance", "外观") }
    static var appearanceSystem: String { t("System", "跟随系统") }
    static var appearanceLight: String { t("Light", "浅色") }
    static var appearanceDark: String { t("Dark", "深色") }
    static var launchAtLogin: String { t("Launch at login", "开机自动启动") }
    static var launchAtLoginFailed: String {
        t("Only works when the app runs from /Applications",
          "只有在 /Applications 里运行才能改这项")
    }
    static var done: String { t("Done", "完成") }

    static var terminateTip: String { t("Click twice · hold ⌥ to force", "点两次生效 · 按住 ⌥ 强制") }
    static var terminateAllTip: String {
        t("Click twice · SIGTERM to every process listed",
          "点两次生效 · 给列表里的进程发 SIGTERM")
    }

    static func copyTip(_ port: Int) -> String {
        t("Copy http://localhost:\(port)", "复制 http://localhost:\(port)")
    }

    static func statusTip(mine: Int) -> String {
        isChinese ? "\(mine) 个自己的服务在监听"
                  : (mine == 1 ? "1 of your services is listening" : "\(mine) of your services are listening")
    }

    /// Compact, language-neutral: 45s / 12m / 2h14m / 3d4h.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        }
        return "\(hours / 24)d\(hours % 24)h"
    }

    static func rowTip(_ entry: PortEntry) -> String {
        var lines = [entry.displayName]
        lines.append(entry.argv.isEmpty ? entry.command : entry.argv)
        lines.append("pid \(entry.pid) · :\(entry.port) · \(entry.hostSummary)")
        if let started = entry.startedAt, let uptime = entry.uptime {
            let stamp = DateFormatter.localizedString(from: started, dateStyle: .short, timeStyle: .medium)
            let elapsed = L10n.uptime(uptime)
            lines.append(t("up \(elapsed) since \(stamp)", "已运行 \(elapsed)（\(stamp) 启动）"))
        }
        if !entry.cwd.isEmpty { lines.append(entry.cwd) }
        if !entry.path.isEmpty, entry.path != entry.argv { lines.append(entry.path) }
        return lines.joined(separator: "\n")
    }
}
