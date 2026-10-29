# OnlyWallpaper

macOS 动态壁纸工具，使用 `WKWebView` 播放本地 MP4/MOV 视频作为桌面背景。项目现在把重点放在两件事上：

- 应用侧默认保持稳定，同时提供更清晰的低功耗预设。
- 文档和脚本直接帮助你把源视频转成更省电的壁纸素材，尤其是在 macOS 上优先使用硬件加速 `HEVC/H.265`。

## 核心建议

如果你关心真实功耗，素材本身通常比应用代码更重要。优先按下面的顺序优化：

1. 使用 `HEVC/H.265`，优先 `hvc1` 标记的 `.mp4` 或 `.mov`。
2. 删除音轨。应用始终静音，保留音频只会增加文件大小和潜在解码工作。
3. 把帧率压到 `24` 或 `30 fps`。壁纸通常不需要 `60 fps`。
4. 把分辨率控制在显示器附近。
   常见建议：单屏 1080p 用 `1080p`，Retina/1440p 桌面优先 `1440p`，只有确实需要时再用 `4K`。

## 安装依赖

```bash
xcode-select --install
brew install ffmpeg
```

`ffmpeg`/`ffprobe` 用于 README 里的转码与检查脚本，不是运行壁纸本身的硬依赖。

## 编译

```bash
CGO_ENABLED=1 go build -o wallpaper
```

二进制会内嵌 `assets/player.html`，不需要额外拷贝资源目录。

### 菜单栏程序（GUI）

```bash
scripts/build-app.sh            # 生成 build/Wallpaper4Mac.app
scripts/build-app.sh --install  # 并复制到 /Applications
```

`Wallpaper4Mac.app` 里包含菜单栏界面（`gui.swift`）和命令行主程序 `wallpaper-cli`。菜单栏可以：

- 查看播放状态和暂停原因（电池供电、其他应用在前台等）
- 手动暂停 / 继续，启动 / 停止
- 选择视频（会记住；播放中选择会直接换上）
- 切换低功耗预设
- 开关“登录时自动播放”：写入 `~/Library/LaunchAgents/com.xstation.wallpaper4mac.plist`，登录后打开本程序并播放上次的视频

界面和壁纸进程之间用分布式通知通信，不轮询。退出菜单栏程序不会停止壁纸。

## 快速开始

启动：

```bash
./wallpaper --video /absolute/path/to/wallpaper.mp4
```

使用更积极的低功耗预设：

```bash
./wallpaper --video /absolute/path/to/wallpaper.mp4 --power-preset efficiency
```

停止：

```bash
./wallpaper stop
```

查看状态：

```bash
./wallpaper status
```

列出预设：

```bash
./wallpaper --list-power-presets
```

## 省电预设

应用提供两个稳定的播放预设：

| 预设 | 行为 | 适合场景 |
|------|------|----------|
| `balanced` | `5m` 空闲暂停，`15s` 空闲轮询，`30s` WebKit 恢复检查 | 默认行为，兼顾稳定性 |
| `efficiency` | `90s` 空闲暂停，`30s` 空闲轮询，`60s` WebKit 恢复检查 | 更积极省电，推荐笔记本和电池场景 |

兼容旧参数：

```bash
./wallpaper --video /path/to/video.mp4 --low-power
```

等价于：

```bash
./wallpaper --video /path/to/video.mp4 --power-preset efficiency
```

你也可以单独覆盖某个值：

```bash
./wallpaper --video /path/to/video.mp4 \
  --power-preset efficiency \
  --idle-threshold 2m \
  --watchdog-interval 45s
```

## 推荐的视频准备流程

先检查素材：

```bash
./scripts/inspect-video.sh /path/to/source.mov
```

再转成更适合壁纸的 HEVC 文件。默认推荐 `1440p / 30fps / 无音频`：

```bash
./scripts/transcode-wallpaper.sh /path/to/source.mov ~/Movies/wallpaper-1440p-hevc.mp4
```

更省电的版本，压到 `1080p / 24fps`：

```bash
./scripts/transcode-wallpaper.sh /path/to/source.mov ~/Movies/wallpaper-1080p.mp4 --profile 1080p --fps 24
```

如果你只想保持原始分辨率但仍转成更友好的编码：

```bash
./scripts/transcode-wallpaper.sh /path/to/source.mov ~/Movies/wallpaper-source-hevc.mp4 --profile source
```

脚本会在 macOS 上优先使用 `hevc_videotoolbox`，也就是系统硬件编码；如果环境里没有该编码器，会自动回退到软件编码。

## 直接用 ffmpeg 的命令

如果你不想用脚本，下面是一条适合 macOS 的手动转码命令：

```bash
ffmpeg -hide_banner -y \
  -i input.mov \
  -map 0:v:0 -an -sn -dn \
  -map_metadata -1 -map_chapters -1 \
  -vf "scale=w='min(iw,2560)':h='min(ih,1440)':force_original_aspect_ratio=decrease:force_divisible_by=2" \
  -r 30 \
  -pix_fmt yuv420p \
  -c:v hevc_videotoolbox \
  -tag:v hvc1 \
  -b:v 6000k -maxrate 8000k -bufsize 12000k \
  -movflags +faststart \
  output-1440p-hevc.mp4
```

如果只想看素材关键信息：

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,avg_frame_rate,pix_fmt \
  -of default=noprint_wrappers=1 input.mov
```

## 开机自启

推荐用菜单栏程序里的“登录时自动播放”。命令行方式如下（两者不要同时开启）。

设置开机自启时，当前省电预设和相关参数会一起写入 LaunchAgent：

```bash
./wallpaper --cmd enable-autostart --video /absolute/path/to/wallpaper.mp4 --power-preset efficiency
```

取消开机自启：

```bash
./wallpaper --cmd disable-autostart
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--video` | MP4/MOV 视频路径 |
| `--cmd` | `start` / `stop` / `status` / `enable-autostart` / `disable-autostart` |
| `--power-preset` | `balanced` 或 `efficiency` |
| `--low-power` | `--power-preset efficiency` 的兼容别名 |
| `--list-power-presets` | 输出预设说明并退出 |
| `--idle-threshold` | 无输入多久后暂停播放 |
| `--idle-poll-interval` | 空闲状态检测轮询间隔 |
| `--watchdog-interval` | WebKit 播放恢复检查间隔，`0` 为关闭 |

## 当前已做的低功耗处理

- 静音播放，避免音频解码。
- 锁屏、睡眠、解锁、唤醒时自动同步暂停/恢复。
- 关闭屏幕、电池供电、前台应用全屏时暂停。
- 其他应用（访达除外）在前台超过 5 秒时暂停，回到桌面恢复。
- 空闲暂停后检测到触摸/鼠标/键盘输入立即恢复，不用等下一次轮询。
- 空闲检测定时器支持容差，减少无意义唤醒。
- WebView 禁用 PiP、AirPlay、持久化站点数据和开发附加功能。
- GUI 默认开启推荐的低功耗预设。

## 注意事项

- 仅支持本地 `.mp4` / `.mov` 文件。
- 新实例会自动尝试停止旧实例，保持单实例运行。
- 真正影响功耗最大的通常不是播放器，而是源视频的编码、分辨率和帧率。
