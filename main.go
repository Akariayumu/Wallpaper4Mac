//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa -framework WebKit -framework CoreGraphics
#include "bridge.h"
#include <stdlib.h>
*/
import "C"
import (
	"bytes"
	"embed"
	"encoding/xml"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/gofrs/flock"
)

//go:embed assets/player.html
var embeddedAssets embed.FS

const (
	lockFile = "/tmp/desktop-wallpaper.lock"
	pidFile  = "/tmp/desktop-wallpaper.pid"
)

var (
	videoPath         string
	cmd               string
	daemon            bool
	foreground        bool
	startupStatusFile string
	lowPower          bool
	powerPreset       string
	listPowerPresets  bool
	idleThreshold     time.Duration
	idlePollInterval  time.Duration
	watchdogInterval  time.Duration
	explicitFlags     map[string]bool
	activePowerPreset string
)

func init() {
	flag.StringVar(&videoPath, "video", "", "MP4/MOV 视频文件路径（绝对路径）")
	flag.StringVar(&cmd, "cmd", "start", "命令: start|stop|status|enable-autostart|disable-autostart")
	flag.BoolVar(&daemon, "daemon", false, "后台运行模式（内部使用）")
	flag.BoolVar(&foreground, "foreground", false, "前台运行模式（调试用）")
	flag.StringVar(&startupStatusFile, "startup-status-file", "", "后台启动状态文件（内部使用）")
	flag.BoolVar(&lowPower, "low-power", false, "启用更激进的省电预设")
	flag.StringVar(&powerPreset, "power-preset", "balanced", "省电预设: balanced|efficiency")
	flag.BoolVar(&listPowerPresets, "list-power-presets", false, "列出可用省电预设并退出")
	flag.DurationVar(&idleThreshold, "idle-threshold", 5*time.Minute, "无输入多久后暂停播放，例如 5m")
	flag.DurationVar(&idlePollInterval, "idle-poll-interval", 15*time.Second, "检测空闲状态的轮询间隔，例如 15s")
	flag.DurationVar(&watchdogInterval, "watchdog-interval", 30*time.Second, "WebKit 播放恢复看门狗间隔，例如 30s；设为 0 可关闭")
}

func main() {
	runtime.LockOSThread()
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	normalizeArgs()
	flag.Parse()
	explicitFlags = map[string]bool{}
	flag.Visit(func(f *flag.Flag) {
		explicitFlags[f.Name] = true
	})

	if listPowerPresets {
		printPowerPresets()
		return
	}

	if cmd == "start" && !daemon && !foreground {
		if videoPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4")
			flag.Usage()
			os.Exit(1)
		}
		if err := startBackground(); err != nil {
			fmt.Printf("❌ 后台启动失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("✅ 已转入后台运行（可用 `wallpaper --cmd status` 查看，`wallpaper --cmd stop` 退出）")
		return
	}

	// 单实例锁
	lock := flock.New(lockFile)
	if cmd != "stop" && cmd != "status" {
		log.Println("🔒 尝试获取单实例锁...")
		locked, err := lock.TryLock()
		if err != nil || !locked {
			// 尝试自动终止旧进程
			pid, _ := readPID()
			if pid > 0 {
				log.Printf("⚠️  检测到旧实例 (PID: %d)，正在终止...", pid)
				proc, err := os.FindProcess(pid)
				if err == nil {
					log.Println("📡 发送 SIGTERM 信号...")
					proc.Signal(syscall.SIGTERM)
					// 等待释放：轮询进程是否存在
					done := false
					for i := 0; i < 50; i++ { // 最多等 5 秒
						time.Sleep(100 * time.Millisecond)
						// 检查进程是否还在
						if err := proc.Signal(syscall.Signal(0)); err != nil {
							// 进程已消失
							log.Println("✅ 旧进程已退出")
							done = true
							break
						}
					}

					if !done {
						// 强制清理
						log.Println("⚠️  旧实例未响应，尝试强制清理 (Kill)...")
						proc.Kill()
						time.Sleep(200 * time.Millisecond)
					}

					// 再次确认锁
					log.Println("🔒 再次尝试获取锁...")
					if l, _ := lock.TryLock(); l {
						locked = true
						log.Println("✅ 锁获取成功")
					} else {
						log.Println("❌ 锁获取失败")
					}
				}
			}

			if !locked {
				fmt.Println("❌ 无法获取锁，请手动运行: wallpaper stop")
				failStartup("无法获取锁，请手动运行: wallpaper stop")
			}
		} else {
			log.Println("✅ 首次锁获取成功")
		}
		// 写入当前 PID
		if err := writePID(); err != nil {
			fmt.Printf("❌ 无法写入 PID 文件: %v\n", err)
			lock.Unlock()
			failStartup("无法写入 PID 文件: %v", err)
		}
		defer func() {
			log.Println("🔓 释放锁并清理 PID 文件")
			lock.Unlock()
			os.Remove(pidFile)
		}()
	}

	switch cmd {
	case "start":
		if videoPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4")
			flag.Usage()
			os.Exit(1)
		}
		startWallpaper(videoPath)
	case "stop":
		stopWallpaper()
	case "status":
		checkStatus()
	case "enable-autostart":
		if videoPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4")
			os.Exit(1)
		}
		enableAutostart(videoPath)
	case "disable-autostart":
		disableAutostart()
	default:
		fmt.Printf("❌ 未知命令: %s (支持: start|stop|status|enable-autostart|disable-autostart)\n", cmd)
		os.Exit(1)
	}
}

func failStartup(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	writeStartupStatus("error:" + msg)
	fmt.Println("❌ " + msg)
	os.Exit(1)
}

func writeStartupStatus(status string) {
	if startupStatusFile == "" {
		return
	}
	_ = os.WriteFile(startupStatusFile, []byte(status), 0600)
}

func escapePlistString(value string) (string, error) {
	var buf bytes.Buffer
	if err := xml.EscapeText(&buf, []byte(value)); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func enableAutostart(video string) {
	if err := resolvePowerPreset(); err != nil {
		fmt.Printf("❌ 省电预设无效: %v\n", err)
		return
	}

	absPath, err := filepath.Abs(video)
	if err != nil {
		fmt.Printf("❌ 路径无效: %v\n", err)
		return
	}

	exePath, err := os.Executable()
	if err != nil {
		fmt.Printf("❌ 无法获取程序路径: %v\n", err)
		return
	}

	escapedExePath, err := escapePlistString(exePath)
	if err != nil {
		fmt.Printf("❌ 无法转义程序路径: %v\n", err)
		return
	}
	escapedVideoPath, err := escapePlistString(absPath)
	if err != nil {
		fmt.Printf("❌ 无法转义视频路径: %v\n", err)
		return
	}

	var extraArgs strings.Builder
	if activePowerPreset != "" {
		extraArgs.WriteString(fmt.Sprintf("\n\t        <string>--power-preset</string>\n\t        <string>%s</string>", activePowerPreset))
	}
	if idleThreshold > 0 {
		escapedIdleThreshold, err := escapePlistString(idleThreshold.String())
		if err != nil {
			fmt.Printf("❌ 无法转义 idle-threshold: %v\n", err)
			return
		}
		extraArgs.WriteString(fmt.Sprintf("\n\t        <string>--idle-threshold</string>\n\t        <string>%s</string>", escapedIdleThreshold))
	}
	if idlePollInterval > 0 {
		escapedIdlePoll, err := escapePlistString(idlePollInterval.String())
		if err != nil {
			fmt.Printf("❌ 无法转义 idle-poll-interval: %v\n", err)
			return
		}
		extraArgs.WriteString(fmt.Sprintf("\n\t        <string>--idle-poll-interval</string>\n\t        <string>%s</string>", escapedIdlePoll))
	}
	if watchdogInterval >= 0 {
		escapedWatchdog, err := escapePlistString(watchdogInterval.String())
		if err != nil {
			fmt.Printf("❌ 无法转义 watchdog-interval: %v\n", err)
			return
		}
		extraArgs.WriteString(fmt.Sprintf("\n\t        <string>--watchdog-interval</string>\n\t        <string>%s</string>", escapedWatchdog))
	}

	plistContent := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
	<dict>
	    <key>Label</key>
	    <string>com.user.onlywallpaper</string>
	    <key>ProgramArguments</key>
	    <array>
	        <string>%s</string>
	        <string>--cmd</string>
	        <string>start</string>
	        <string>--video</string>
	        <string>%s</string>
%s
	        <string>--daemon</string>
	    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>`, escapedExePath, escapedVideoPath, extraArgs.String())

	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Printf("❌ 无法获取用户目录: %v\n", err)
		return
	}

	launchAgentsDir := filepath.Join(homeDir, "Library", "LaunchAgents")
	if err := os.MkdirAll(launchAgentsDir, 0755); err != nil {
		fmt.Printf("❌ 无法创建 LaunchAgents 目录: %v\n", err)
		return
	}

	plistPath := filepath.Join(launchAgentsDir, "com.user.onlywallpaper.plist")
	if err := os.WriteFile(plistPath, []byte(plistContent), 0644); err != nil {
		fmt.Printf("❌ 写入 plist 失败: %v\n", err)
		return
	}

	fmt.Printf("📄 已生成 plist 文件: %s\n", plistPath)

	// Unload first to avoid error if already loaded
	exec.Command("launchctl", "unload", plistPath).Run()

	if err := exec.Command("launchctl", "load", plistPath).Run(); err != nil {
		fmt.Printf("❌ 加载自启动服务失败: %v\n", err)
		fmt.Println("💡 请尝试手动运行: launchctl load " + plistPath)
	} else {
		fmt.Println("✅ 已配置开机自启")
	}
}

func disableAutostart() {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Printf("❌ 无法获取用户目录: %v\n", err)
		return
	}

	plistPath := filepath.Join(homeDir, "Library", "LaunchAgents", "com.user.onlywallpaper.plist")

	if _, err := os.Stat(plistPath); os.IsNotExist(err) {
		fmt.Println("⚠️  未找到自启配置文件")
		return
	}

	exec.Command("launchctl", "unload", plistPath).Run()

	if err := os.Remove(plistPath); err != nil {
		fmt.Printf("❌ 删除配置文件失败: %v\n", err)
	} else {
		fmt.Println("✅ 已取消开机自启")
	}
}

func normalizeArgs() {
	if len(os.Args) < 2 {
		return
	}
	for _, arg := range os.Args[1:] {
		if arg == "--cmd" || strings.HasPrefix(arg, "--cmd=") {
			return
		}
	}
	sub := os.Args[1]
	if strings.HasPrefix(sub, "-") {
		return
	}
	switch sub {
	case "stop", "status":
		os.Args = append([]string{os.Args[0], "--cmd", sub}, os.Args[2:]...)
	case "enable-autostart", "disable-autostart":
		os.Args = append([]string{os.Args[0], "--cmd", sub}, os.Args[2:]...)
	case "start":
		os.Args = append([]string{os.Args[0]}, os.Args[2:]...)
	}
}

func startWallpaper(video string) {
	if err := resolvePowerPreset(); err != nil {
		failStartup("省电预设无效: %v", err)
	}
	applyPowerPreset()
	if err := validatePowerSettings(); err != nil {
		failStartup("省电参数无效: %v", err)
	}

	// 路径规范化
	absPath, err := filepath.Abs(video)
	if err != nil {
		failStartup("无效路径: %v", err)
	}

	// 校验 MP4
	if absPath != "" && !strings.HasSuffix(strings.ToLower(absPath), ".mp4") && !strings.HasSuffix(strings.ToLower(absPath), ".mov") {
		failStartup("仅支持 .mp4/.mov 格式视频")
	}

	// 从嵌入的文件系统中提取模板到临时位置
	templateContent, err := embeddedAssets.ReadFile("assets/player.html")
	if err != nil {
		failStartup("无法读取内嵌的 HTML 模板: %v", err)
	}

	// 创建临时 HTML 文件
	tmpFile, err := os.CreateTemp("", "player-*.html")
	if err != nil {
		failStartup("无法创建临时文件: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.Write(templateContent); err != nil {
		tmpFile.Close()
		failStartup("无法写入模板数据: %v", err)
	}
	tmpFile.Close()

	templatePath := tmpFile.Name()

	// 初始化壁纸
	fmt.Printf("🎬 正在启动动态壁纸: %s\n", filepath.Base(absPath))
	fmt.Println("🔋 省电特性:")
	fmt.Printf("   • 当前预设: %s\n", powerPresetLabel(activePowerPreset))
	fmt.Println("   • Metal 硬件加速解码")
	fmt.Println("   • 锁屏/睡眠自动暂停")
	if idleThreshold > 0 {
		fmt.Printf("   • %s 无操作自动暂停\n", idleThreshold)
	}
	if watchdogInterval > 0 {
		fmt.Printf("   • WebKit 恢复看门狗: %s\n", watchdogInterval)
	}
	fmt.Println("   • 静音播放（禁用音频解码）")
	fmt.Println()

	cVideo := C.CString(absPath)
	cTemplate := C.CString(templatePath)
	defer C.free(unsafe.Pointer(cVideo))
	defer C.free(unsafe.Pointer(cTemplate))

	ret := C.InitWallpaper(
		cVideo,
		cTemplate,
		C.double(idleThreshold.Seconds()),
		C.double(idlePollInterval.Seconds()),
		C.int(boolToInt(idleThreshold > 0)),
		C.int(watchdogInterval.Milliseconds()),
	)
	if ret != 0 {
		failStartup("壁纸启动失败（查看上方错误）")
	}
	writeStartupStatus(fmt.Sprintf("ready:%d", os.Getpid()))

	// 优雅退出处理
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigCh
		log.Printf("\n👋 接收到信号: %v，正在清理壁纸资源...", sig)
		C.StopApp()
	}()

	fmt.Println("✅ 壁纸已激活（按 Ctrl+C 或运行 `wallpaper stop` 退出）")

	// 运行主事件循环（阻塞主线程）
	log.Println("🚀 启动主事件循环 (RunApp)")
	C.RunApp()

	// 主循环结束后清理
	log.Println("🧹 主循环结束，执行最终清理")
	C.CleanupWallpaper()
}

func applyPowerPreset() {
	if activePowerPreset != "efficiency" {
		return
	}
	if !explicitFlags["idle-threshold"] {
		idleThreshold = 90 * time.Second
	}
	if !explicitFlags["idle-poll-interval"] {
		idlePollInterval = 30 * time.Second
	}
	if !explicitFlags["watchdog-interval"] {
		watchdogInterval = 60 * time.Second
	}
}

func resolvePowerPreset() error {
	preset := strings.ToLower(strings.TrimSpace(powerPreset))
	switch preset {
	case "", "default", "balanced":
		preset = "balanced"
	case "low", "low-power", "efficiency", "efficient":
		preset = "efficiency"
	default:
		return fmt.Errorf("--power-preset 仅支持 balanced|efficiency")
	}

	if lowPower {
		if explicitFlags["power-preset"] && preset != "efficiency" {
			return fmt.Errorf("--low-power 与 --power-preset=%s 冲突", powerPreset)
		}
		preset = "efficiency"
	}

	powerPreset = preset
	activePowerPreset = preset
	return nil
}

func powerPresetLabel(preset string) string {
	switch preset {
	case "efficiency":
		return "efficiency（更积极省电）"
	default:
		return "balanced（默认）"
	}
}

func printPowerPresets() {
	fmt.Println("可用省电预设:")
	fmt.Println("  balanced   默认预设。保持当前行为：5m 空闲暂停、15s 空闲轮询、30s 恢复看门狗。")
	fmt.Println("  efficiency 更积极省电：90s 空闲暂停、30s 空闲轮询、60s 恢复看门狗。")
	fmt.Println()
	fmt.Println("示例:")
	fmt.Println("  wallpaper --video /path/to/video.mov --power-preset efficiency")
	fmt.Println("  wallpaper --video /path/to/video.mov --low-power")
}

func validatePowerSettings() error {
	if idleThreshold < 0 {
		return fmt.Errorf("--idle-threshold 不能小于 0")
	}
	if idlePollInterval < 0 {
		return fmt.Errorf("--idle-poll-interval 不能小于 0")
	}
	if watchdogInterval < 0 {
		return fmt.Errorf("--watchdog-interval 不能小于 0")
	}
	if idleThreshold > 0 && idlePollInterval == 0 {
		return fmt.Errorf("启用空闲暂停时，--idle-poll-interval 不能为 0")
	}
	return nil
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func startBackground() error {
	// 前置验证：在启动后台进程前检查基本条件，确保错误能输出到前台
	if videoPath == "" {
		return fmt.Errorf("视频路径不能为空")
	}

	absPath, err := filepath.Abs(videoPath)
	if err != nil {
		return fmt.Errorf("无效的视频路径: %v", err)
	}

	// 检查视频文件是否存在
	if _, err := os.Stat(absPath); os.IsNotExist(err) {
		return fmt.Errorf("视频文件不存在: %s", absPath)
	}

	// 检查视频格式
	if !strings.HasSuffix(strings.ToLower(absPath), ".mp4") && !strings.HasSuffix(strings.ToLower(absPath), ".mov") {
		return fmt.Errorf("仅支持 .mp4/.mov 格式视频")
	}

	// 检查嵌入的模板
	if _, err := embeddedAssets.ReadFile("assets/player.html"); err != nil {
		return fmt.Errorf("内嵌的 HTML 模板损坏: %v", err)
	}

	// 所有验证通过，启动后台进程
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	args := append([]string{}, os.Args[1:]...)
	hasDaemon := false
	for _, arg := range args {
		if arg == "--daemon" || strings.HasPrefix(arg, "--daemon=") {
			hasDaemon = true
			break
		}
	}
	if !hasDaemon {
		args = append(args, "--daemon")
	}

	cmd := exec.Command(exePath, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	devNull, err := os.OpenFile("/dev/null", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	cmd.Stdin = devNull
	cmd.Stdout = devNull
	cmd.Stderr = devNull
	if err := cmd.Start(); err != nil {
		devNull.Close()
		return err
	}
	devNull.Close()
	return cmd.Process.Release()
}

func stopWallpaper() {
	// 读取 PID
	pid, err := readPID()
	if err != nil || pid == 0 {
		fmt.Println("⚠️  未检测到运行中的壁纸实例")
		os.Remove(pidFile)
		return
	}

	if !isProcessRunning(pid) {
		fmt.Println("⚠️  发现陈旧 PID，已清理状态文件")
		os.Remove(pidFile)
		return
	}

	// 查找并终止进程
	proc, err := os.FindProcess(pid)
	if err != nil {
		fmt.Println("⚠️  进程已不存在")
		os.Remove(pidFile)
		return
	}

	fmt.Println("🛑 正在停止动态壁纸...")
	err = proc.Signal(syscall.SIGTERM)
	if err != nil {
		fmt.Printf("❌ 停止失败: %v\n", err)
		return
	}

	// 等待锁释放
	lock := flock.New(lockFile)
	for i := 0; i < 20; i++ {
		locked, _ := lock.TryLock()
		if locked {
			lock.Unlock()
			os.Remove(pidFile)
			fmt.Println("✅ 壁纸已停止")
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Println("⚠️  停止操作超时，请手动检查")
}

func checkStatus() {
	lock := flock.New(lockFile)
	locked, _ := lock.TryLock()
	if locked {
		lock.Unlock()
		if pid, err := readPID(); err == nil && pid > 0 && isProcessRunning(pid) {
			fmt.Printf("⚠️  检测到状态不一致: PID %d 仍在运行，但锁已释放\n", pid)
			return
		}
		os.Remove(pidFile)
		fmt.Println("⏹️  壁纸状态: 未运行")
	} else {
		pid, err := readPID()
		if err != nil || pid == 0 {
			fmt.Println("⚠️  壁纸状态: 锁存在，但 PID 缺失")
			return
		}
		if !isProcessRunning(pid) {
			fmt.Printf("⚠️  壁纸状态: 检测到陈旧锁 (PID %d 不存在)\n", pid)
			return
		}
		fmt.Printf("✅ 壁纸状态: 运行中 (PID %d)\n", pid)
	}
}

func writePID() error {
	return os.WriteFile(pidFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644)
}

func readPID() (int, error) {
	data, err := os.ReadFile(pidFile)
	if err != nil {
		return 0, err
	}
	var pid int
	fmt.Sscanf(string(data), "%d", &pid)
	return pid, nil
}

func isProcessRunning(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, syscall.Signal(0))
	return err == nil
}
