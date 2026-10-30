import Foundation

/// Westie 自己的配置目录：默认 `~/.config/westie`，可用 `WESTIE_CONFIG_HOME` 另指。
/// `settings.json` 存外观、面板布局和会话最近活动时间；`dsh/` 是自带 DSH 内核的数据目录（DSH_HOME）。
/// 以后接入别的 Agent 内核，各自在这里占一个子目录。
enum ConfigHome {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["WESTIE_CONFIG_HOME"] { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/westie")
    }()

    static var dshHome: URL { url.appending(path: "dsh") }
}

/// 一个 JSON 文件当键值表用：启动时读一次进内存，每次写入整份原子落盘。
/// 文件很小，写入只发生在用户操作结束时（改外观、拖完面板、打开会话），不需要合并或防抖。
final class ConfigStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var values: [String: Any]

    init(file: URL) {
        self.file = file
        values = (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// 日常用 `<配置目录>/settings.json`；自动化测试用仓库 temp/ 里单独一份，默认每次启动清空
    /// （`WESTIE_LAYOUT_KEEP` 保留），不动日常使用的外观和布局。
    static let shared: ConfigStore = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WESTIE_AUTOMATION"] != nil else {
            let store = ConfigStore(file: ConfigHome.url.appending(path: "settings.json"))
            store.importLegacyAppearance()
            return store
        }
        let file = environment["WESTIE_PERF_LOG"] != nil
            ? ConfigHome.url.appending(path: "settings.json")
            : KernelConfiguration.repoRoot.appending(path: "temp/automation/settings.json")
        if environment["WESTIE_LAYOUT_KEEP"] == nil { try? FileManager.default.removeItem(at: file) }
        return ConfigStore(file: file)
    }()

    subscript(key: String) -> Any? {
        get { lock.withLock { values[key] } }
        set {
            lock.withLock {
                values[key] = newValue
                write()
            }
        }
    }

    /// 存 Codable 编出来的 JSON：落盘时展开成对象，`settings.json` 保持可读。
    func data(forKey key: String) -> Data? {
        guard let object = self[key], JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    func set(data: Data, forKey key: String) {
        self[key] = try? JSONSerialization.jsonObject(with: data)
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("Westie: 写配置失败 \(file.path): \(error)")
        }
    }

    /// 外观以前存在 UserDefaults：配置文件里还没有时搬一次过来。会话相关的旧记录指向 `~/.dsh` 里的会话，不搬。
    private func importLegacyAppearance() {
        guard self[AppearanceSettings.key] == nil,
              let legacy = UserDefaults.standard.dictionary(forKey: "Westie.appearance.v1"),
              JSONSerialization.isValidJSONObject(legacy)
        else { return }
        self[AppearanceSettings.key] = legacy
    }
}
