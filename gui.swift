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
private let kGitHubRepoURL = URL(string: "https://github.com/Akariayumu/Wallpaper4Mac")!

private struct GitHubMarkShape: Shape {
    private static let curves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (3.58, 0.0, 0.0, 3.58, 0.0, 8.0),
        (0.0, 11.54, 2.29, 14.53, 5.47, 15.59),
        (5.87, 15.66, 6.02, 15.42, 6.02, 15.21),
        (6.02, 15.02, 6.01, 14.39, 6.01, 13.72),
        (4.0, 14.09, 3.48, 13.23, 3.32, 12.78),
        (3.23, 12.55, 2.84, 11.84, 2.5, 11.65),
        (2.22, 11.5, 1.82, 11.13, 2.49, 11.12),
        (3.12, 11.11, 3.57, 11.7, 3.72, 11.94),
        (4.44, 13.15, 5.59, 12.81, 6.05, 12.6),
        (6.12, 12.08, 6.33, 11.73, 6.56, 11.53),
        (4.78, 11.33, 2.92, 10.64, 2.92, 7.58),
        (2.92, 6.71, 3.23, 5.99, 3.74, 5.43),
        (3.66, 5.23, 3.38, 4.41, 3.82, 3.31),
        (3.82, 3.31, 4.49, 3.1, 6.02, 4.13),
        (6.66, 3.95, 7.34, 3.86, 8.02, 3.86),
        (8.7, 3.86, 9.38, 3.95, 10.02, 4.13),
        (11.55, 3.09, 12.22, 3.31, 12.22, 3.31),
        (12.66, 4.41, 12.38, 5.23, 12.3, 5.43),
        (12.81, 5.99, 13.12, 6.7, 13.12, 7.58),
        (13.12, 10.65, 11.25, 11.33, 9.47, 11.53),
        (9.76, 11.78, 10.01, 12.26, 10.01, 13.01),
        (10.01, 14.08, 10.0, 14.94, 10.0, 15.21),
        (10.0, 15.42, 10.15, 15.67, 10.55, 15.59),
        (13.71, 14.53, 16.0, 11.54, 16.0, 8.0),
        (16.0, 3.58, 12.42, 0.0, 8.0, 0.0),
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / 16.0
        let ox = rect.midX - side / 2.0
        let oy = rect.midY - side / 2.0
        var p = Path()
        p.move(to: CGPoint(x: ox + 8.0 * s, y: oy))
        for c in Self.curves {
            p.addCurve(
                to: CGPoint(x: ox + c.4 * s, y: oy + c.5 * s),
                control1: CGPoint(x: ox + c.0 * s, y: oy + c.1 * s),
                control2: CGPoint(x: ox + c.2 * s, y: oy + c.3 * s)
            )
        }
        p.closeSubpath()
        return p
    }
}

private struct GitHubCornerButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(kGitHubRepoURL)
        } label: {
            GitHubMarkShape()
                .fill(isHovered ? Color.primary : Color.secondary)
                .frame(width: 14, height: 14)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.primary.opacity(isHovered ? 0.14 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("打开 GitHub 仓库 (Akariayumu/Wallpaper4Mac)")
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 状态显示 + 右上角 GitHub 仓库入口
            HStack(alignment: .top, spacing: 10) {
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
                Spacer(minLength: 8)
                GitHubCornerButton()
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
