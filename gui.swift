//go:build darwin
// +build darwin

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 可以在这里添加启动逻辑
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 清理资源
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // 状态显示
            HStack {
                Image(systemName: viewModel.isRunning ? "play.circle.fill" : "stop.circle")
                    .font(.title)
                    .foregroundColor(viewModel.isRunning ? .green : .gray)
                Text(viewModel.status)
                    .font(.caption)
            }
            
            Divider()
            
            // 选择视频
            Button(action: viewModel.selectVideo) {
                Label("选择视频", systemImage: "folder")
            }
            .disabled(viewModel.isRunning)
            
            if !viewModel.videoPath.isEmpty {
                Text(viewModel.videoPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            // 启动/停止
            HStack(spacing: 16) {
                Button(action: viewModel.start) {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(viewModel.isRunning || viewModel.videoPath.isEmpty)
                .buttonStyle(.borderedProminent)
                
                Button(action: viewModel.stop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isRunning)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            
            Divider()
            
            // 开机自启
            Toggle("开机自启", isOn: $viewModel.autostart)
                .onChange(of: viewModel.autostart) { oldValue, newValue in
                    viewModel.toggleAutostart()
                }
            
            Spacer()
        }
        .padding()
        .frame(width: 300, height: 280)
    }
}

struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = WallpaperViewModel()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.isRunning ? "play.circle.fill" : "stop.circle")
                .foregroundColor(viewModel.isRunning ? .green : .gray)
        }
        .menuBarExtraStyle(.window)
    }
}

class WallpaperViewModel: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var videoPath: String = ""
    @Published var autostart: Bool = false
    @Published var status: String = "未运行"
    
    init() {
        checkStatus()
    }
    
    func checkStatus() {
        let task = Process()
        let cliPath = Bundle.main.bundlePath + "/Contents/MacOS/wallpaper-cli"
        task.launchPath = cliPath
        task.arguments = ["--cmd", "status"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        DispatchQueue.main.async {
            self.isRunning = output.contains("运行中")
            self.status = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            videoPath = url.path
        }
    }
    
    func start() {
        guard !videoPath.isEmpty else { return }
        
        let task = Process()
        let cliPath = Bundle.main.bundlePath + "/Contents/MacOS/wallpaper-cli"
        task.launchPath = cliPath
        task.arguments = ["--video", videoPath]
        task.launch()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.checkStatus()
        }
    }
    
    func stop() {
        let task = Process()
        let cliPath = Bundle.main.bundlePath + "/Contents/MacOS/wallpaper-cli"
        task.launchPath = cliPath
        task.arguments = ["--cmd", "stop"]
        task.launch()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.checkStatus()
        }
    }
    
    func toggleAutostart() {
        let task = Process()
        let cliPath = Bundle.main.bundlePath + "/Contents/MacOS/wallpaper-cli"
        task.launchPath = cliPath
        
        if autostart {
            task.arguments = ["--cmd", "enable-autostart", "--video", videoPath]
        } else {
            task.arguments = ["--cmd", "disable-autostart"]
        }
        task.launch()
    }
}
