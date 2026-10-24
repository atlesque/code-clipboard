// Code Clipboard: menu bar app that subscribes to an ntfy topic and copies
// each new message to the clipboard (e.g. login codes forwarded from email).

import AppKit
import Security
import ServiceManagement
import UserNotifications

// Set at build time from NTFY_TOPIC_URL (see build.sh); can be changed in the menu.
let defaultTopicURL = (Bundle.main.object(forInfoDictionaryKey: "NtfyTopicURL") as? String) ?? ""
let keychainService = Bundle.main.bundleIdentifier ?? "code-clipboard"

func topicURL() -> String {
    UserDefaults.standard.string(forKey: "topicURL") ?? defaultTopicURL
}
// Messages older than this (e.g. replayed after sleep) are not copied.
let maxMessageAge: TimeInterval = 10 * 60

// MARK: - Keychain

enum Keychain {
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // A token dropped in ~/Library/Application Support/Code Clipboard/token
    // (e.g. by install.sh) is moved into the Keychain and the file deleted.
    static func importTokenFile() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Code Clipboard/token")
        guard let token = try? String(contentsOf: url, encoding: .utf8) else { return }
        write("token", token.trimmingCharacters(in: .whitespacesAndNewlines))
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - ntfy subscriber

final class Subscriber: NSObject, URLSessionDataDelegate {
    var onMessage: ((_ id: String, _ text: String, _ time: Date) -> Void)?
    var onState: ((_ state: String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var lastId: String?
    private var retryDelay: TimeInterval = 1
    private var retryTimer: Timer?
    private var watchdog: Timer?
    private var lastActivity = Date()
    private(set) var running = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90 // ntfy sends keepalives every ~45 s
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func start() {
        running = true
        connect()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.running, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastActivity) > 120 { self.reconnect(now: true) }
        }
    }

    func stop() {
        running = false
        retryTimer?.invalidate()
        watchdog?.invalidate()
        task?.cancel()
        task = nil
        onState?("Paused")
    }

    func reconnect(now: Bool = false) {
        task?.cancel()
        task = nil
        if now { retryDelay = 1 }
        scheduleRetry()
    }

    private func connect() {
        retryTimer?.invalidate()
        guard running else { return }
        let topic = topicURL()
        guard !topic.isEmpty else { onState?("No topic URL set"); return }
        guard var comps = URLComponents(string: topic.trimmingCharacters(in: .init(charactersIn: "/")) + "/json") else {
            onState?("Invalid topic URL"); return
        }
        // After a drop, ask for everything since the last seen message.
        if let lastId { comps.queryItems = [URLQueryItem(name: "since", value: lastId)] }
        var req = URLRequest(url: comps.url!)
        if let token = Keychain.read("token") {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        buffer.removeAll()
        lastActivity = Date()
        onState?("Connecting…")
        task = session.dataTask(with: req)
        task?.resume()
    }

    private func scheduleRetry() {
        guard running else { return }
        retryTimer?.invalidate()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            retryDelay = 1
            onState?("Connected")
            completionHandler(.allow)
        } else {
            onState?(status == 401 || status == 403 ? "Not authorised (check token)" : "HTTP \(status)")
            if status == 401 || status == 403 { retryDelay = max(retryDelay, 30) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask == task else { return }
        lastActivity = Date()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: Data(line))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == self.task else { return }
        self.task = nil
        if running {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                onState?("Disconnected – retrying")
            }
            scheduleRetry()
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["event"] as? String == "message",
              let id = obj["id"] as? String else { return }
        lastId = id
        let time = Date(timeIntervalSince1970: (obj["time"] as? Double) ?? Date().timeIntervalSince1970)
        let text = (obj["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onMessage?(id, text, time)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let subscriber = Subscriber()
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "No code yet", action: #selector(copyLast), keyEquivalent: "c")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let notifyItem = NSMenuItem(title: "Show Notification", action: #selector(toggleNotify), keyEquivalent: "")
    private var lastText: String?
    private var seen = [String]()

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["notify": true])
        Keychain.importTokenFile()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("doc.on.clipboard")

        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        lastItem.isEnabled = false
        menu.addItem(lastItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Set Topic URL…", action: #selector(setTopic), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Access Token…", action: #selector(setToken), keyEquivalent: ""))
        menu.addItem(notifyItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Code Clipboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
        refreshToggles()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        subscriber.onState = { [weak self] state in
            self?.stateItem.title = state
            self?.setIcon(state == "Connected" ? "doc.on.clipboard" : "exclamationmark.arrow.triangle.2.circlepath")
        }
        subscriber.onMessage = { [weak self] id, text, time in self?.received(id: id, text: text, time: time) }

        // Reconnect straight away after sleep or a network change.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.subscriber.reconnect(now: true) }

        // First launch: register as a login item so it starts on boot.
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginConfigured")
            refreshToggles()
        }

        subscriber.start()
        if topicURL().isEmpty { DispatchQueue.main.async { self.setTopic() } }
    }

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Code Clipboard")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func received(id: String, text: String, time: Date) {
        guard !seen.contains(id) else { return }
        seen.append(id)
        if seen.count > 50 { seen.removeFirst() }
        guard Date().timeIntervalSince(time) < maxMessageAge else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastText = text
        let df = DateFormatter()
        df.timeStyle = .short
        lastItem.title = "Copy again: \(text.prefix(40))  (\(df.string(from: time)))"
        lastItem.isEnabled = true

        // Flash the icon so it's obvious something was copied.
        setIcon("checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.setIcon("doc.on.clipboard")
        }

        if UserDefaults.standard.bool(forKey: "notify") {
            let content = UNMutableNotificationContent()
            content.title = "Code copied"
            content.body = text
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner])
    }

    private func refreshToggles() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        notifyItem.state = UserDefaults.standard.bool(forKey: "notify") ? .on : .off
        pauseItem.title = subscriber.running || stateItem.title == "Starting…" ? "Pause" : "Resume"
    }

    @objc private func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func togglePause() {
        if subscriber.running { subscriber.stop() } else { subscriber.start() }
        pauseItem.title = subscriber.running ? "Pause" : "Resume"
    }

    @objc private func reconnect() { if subscriber.running { subscriber.reconnect(now: true) } }

    @objc private func toggleNotify() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "notify"), forKey: "notify")
        refreshToggles()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshToggles()
    }

    @objc private func setTopic() {
        if let value = prompt("ntfy topic URL, e.g. https://ntfy.example.com/my-codes", topicURL(), secure: false) {
            UserDefaults.standard.set(value.isEmpty ? nil : value, forKey: "topicURL")
            reconnect()
        }
    }

    @objc private func setToken() {
        if let value = prompt("ntfy access token (tk_…). Leave empty to remove.", "", secure: true) {
            Keychain.write("token", value.trimmingCharacters(in: .whitespacesAndNewlines))
            reconnect()
        }
    }

    private func prompt(_ message: String, _ value: String, secure: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Code Clipboard"
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
