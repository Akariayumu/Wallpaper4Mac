//go:build darwin
// +build darwin

// 菜单栏控制程序。打包进 Wallpaper4Mac.app，和 wallpaper-cli（Go 主程序）放在同一个 Contents/MacOS 下。
// 编译：scripts/build-app.sh
import SwiftUI
import AppKit

// 和 bridge.m 里的通知名保持一致
private let kStateNotification = Notification.Name("com.xstation.wallpaper4mac.state")
private let kQueryNotification = Notification.Name("com.xstation.wallpaper4mac.query")
private let kManualPauseNotification = Notification.Name("com.xstation.wallpaper4mac.setManualPause")
private let kPIDFile = "/tmp/desktop-wallpaper.pid"
private let kLoginAgentLabel = "com.xstation.wallpaper4mac"
private let kLegacyAgentLabel = "com.user.onlywallpaper"

struct ContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 状态显示
            HStack(spacing: 10) {
                Image(systemName: viewModel.symbolName)
                    .font(.title)
                    .foregroundColor(viewModel.symbolColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.statusTitle).font(.headline)
                    if !viewModel.statusDetail.isEmpty {
                        Text(viewModel.statusDetail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            // 选择视频
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(viewModel.videoName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择视频…", action: viewModel.selectVideo)
                }
                if viewModel.videoMissing {
                    Text("视频文件不存在，请重新选择")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            // 启动/停止、暂停/继续
            HStack(spacing: 10) {
                if viewModel.isRunning {
                    Button(action: viewModel.toggleManualPause) {
                        Label(viewModel.isManuallyPaused ? "继续" : "暂停",
                              systemImage: viewModel.isManuallyPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: viewModel.stop) {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: viewModel.start) {
                        Label("启动", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.videoPath.isEmpty || viewModel.videoMissing || viewModel.isBusy)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("低功耗预设", isOn: $viewModel.lowPowerMode)
                    .onChange(of: viewModel.lowPowerMode) { _, newValue in
                        viewModel.setLowPowerMode(newValue)
                    }
                Text(viewModel.lowPowerMode ? "无操作 90 秒后暂停" : "无操作 5 分钟后暂停")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // 开机自启
            VStack(alignment: .leading, spacing: 4) {
                Toggle("登录时自动播放", isOn: $viewModel.autostart)
                    .onChange(of: viewModel.autostart) { _, newValue in
                        viewModel.setAutostart(newValue)
                    }
                Text("登录后打开本程序并播放上面的视频")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("关屏、用电池、全屏或其他应用在前台 5 秒会自动暂停")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .help("只退出菜单栏程序，壁纸继续播放")
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear(perform: viewModel.refresh)
    }
}

@main
struct WallpaperApp: App {
    @StateObject private var viewModel = WallpaperViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class WallpaperViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var isManuallyPaused = false
    @Published var pauseReasons = ""
    @Published var isBusy = false
    @Published var videoPath: String
    @Published var autostart: Bool
    @Published var lowPowerMode: Bool

    private let defaults = UserDefaults.standard
    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?

    private var cliPath: String { Bundle.main.bundlePath + "/Contents/MacOS/wallpaper-cli" }
    private var loginAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(kLoginAgentLabel).plist")
    }

    init() {
        videoPath = UserDefaults.standard.string(forKey: "videoPath") ?? ""
        lowPowerMode = UserDefaults.standard.object(forKey: "lowPowerMode") as? Bool ?? true
        autostart = false
        autostart = FileManager.default.fileExists(atPath: loginAgentURL.path)

        observer = DistributedNotificationCenter.default().addObserver(
            forName: kStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.applyState(note.userInfo)
        }
        // 只看 PID 是否存活，不启动子进程；用于发现壁纸进程被外部停掉
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshRunning()
        }
        pollTimer?.tolerance = 5

        refresh()
        if CommandLine.arguments.contains("--autoplay") {
            // 登录时由 LaunchAgent 带 --autoplay 启动；稍等桌面就绪再播放
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.refreshRunning()
                if !self.isRunning && !self.videoPath.isEmpty && !self.videoMissing { self.start() }
            }
        }
    }

    // MARK: 显示

    var videoName: String {
        videoPath.isEmpty ? "未选择视频" : (videoPath as NSString).lastPathComponent
    }
    var videoMissing: Bool {
        !videoPath.isEmpty && !FileManager.default.fileExists(atPath: videoPath)
    }
    var statusTitle: String {
        if isBusy { return "处理中…" }
        if !isRunning { return "未运行" }
        return isPaused ? "已暂停" : "播放中"
    }
    var statusDetail: String {
        isRunning && isPaused ? pauseReasons : ""
    }
    var symbolName: String {
        !isRunning ? "stop.circle" : (isPaused ? "pause.circle.fill" : "play.circle.fill")
    }
    var symbolColor: Color {
        !isRunning ? .gray : (isPaused ? .orange : .green)
    }
    var menuBarSymbol: String {
        !isRunning ? "photo.on.rectangle" : (isPaused ? "pause.rectangle" : "play.rectangle.fill")
    }

    // MARK: 状态

    func refresh() {
        refreshRunning()
        autostart = FileManager.default.fileExists(atPath: loginAgentURL.path)
        if isRunning {
            DistributedNotificationCenter.default().postNotificationName(
                kQueryNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    private func refreshRunning() {
        let running = Self.daemonPID() != nil
        if running != isRunning { isRunning = running }
        if !running {
            isPaused = false
            isManuallyPaused = false
            pauseReasons = ""
        }
    }

    private static func daemonPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: kPIDFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    private func applyState(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        isRunning = (info["running"] as? String) == "1"
        isPaused = (info["paused"] as? String) == "1"
        isManuallyPaused = (info["manual"] as? String) == "1"
        pauseReasons = info["reasons"] as? String ?? ""
    }

    // MARK: 操作

    func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if !videoPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (videoPath as NSString).deletingLastPathComponent)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        videoPath = url.path
        defaults.set(videoPath, forKey: "videoPath")
        // 正在播放时直接换成新视频（新实例会自动替换旧实例）
        if isRunning { start() }
    }

    func start() {
        guard !videoPath.isEmpty, !videoMissing else { return }
        runCLI(["--cmd", "start", "--video", videoPath] + presetArguments())
    }

    func stop() {
        runCLI(["--cmd", "stop"])
    }

    func toggleManualPause() {
        let paused = !isManuallyPaused
        DistributedNotificationCenter.default().postNotificationName(
            kManualPauseNotification, object: nil,
            userInfo: ["paused": paused ? "1" : "0"], deliverImmediately: true)
    }

    func setLowPowerMode(_ enabled: Bool) {
        defaults.set(enabled, forKey: "lowPowerMode")
        if isRunning { start() }
    }

    /// 登录项：LaunchAgent 启动本程序（带 --autoplay），由本程序再拉起壁纸。
    /// 只写/删文件，不 bootstrap/bootout：bootstrap 会立刻再开一个实例，bootout 会把当前实例杀掉。
    func setAutostart(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": kLoginAgentLabel,
                "ProgramArguments": [exe, "--autoplay"],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            do {
                try fm.createDirectory(at: loginAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: loginAgentURL)
                // 旧版命令行自启会和这里重复启动，一并取消
                runCLI(["--cmd", "disable-autostart"], refreshAfter: false)
            } catch {
                NSLog("写入登录项失败: \(error)")
                autostart = false
            }
        } else {
            try? fm.removeItem(at: loginAgentURL)
        }
    }

    private func presetArguments() -> [String] {
        lowPowerMode ? ["--power-preset", "efficiency"] : ["--power-preset", "balanced"]
    }

    private func runCLI(_ arguments: [String], refreshAfter: Bool = true) {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(kLegacyAgentLabel).plist")
        if arguments.contains("disable-autostart") && !FileManager.default.fileExists(atPath: legacy.path) {
            return
        }
        if refreshAfter { isBusy = true }
        let cli = cliPath
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cli)
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                NSLog("运行 wallpaper-cli 失败: \(error)")
            }
            DispatchQueue.main.async {
                guard refreshAfter else { return }
                self.isBusy = false
                self.refresh()
            }
        }
    }
}
