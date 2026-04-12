//go:build darwin

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "bridge.h"

static NSMutableArray<NSWindow *> *wallpaperWindows = nil;
static NSMutableArray<WKWebView *> *wallpaperWebViews = nil;
static WKWebView *webView = nil;
static id webDelegate = nil;
static NSString *currentTempHTMLPath = nil;
static NSString *currentTempHTMLDirectory = nil;
static NSMutableArray<NSDictionary<NSString *, id> *> *notificationObservers = nil;
static NSTimer *idleDetectionTimer = nil;
static BOOL isSystemIdle = NO;

static const NSTimeInterval kIdleDetectionInterval = 5.0;
static const NSTimeInterval kIdleThreshold = 60.0;

static void broadcastJS(NSString *script) {
    for (WKWebView *view in wallpaperWebViews) {
        [view evaluateJavaScript:script completionHandler:nil];
    }
}

static void addNotificationObserver(id center, id token) {
    if (!center || !token) return;
    if (!notificationObservers) {
        notificationObservers = [NSMutableArray array];
    }
    [notificationObservers addObject:@{
        @"center": center,
        @"token": token,
    }];
}

static void updateIdleState(void) {
    CFTimeInterval idleSeconds =
        CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,
                                               kCGAnyInputEventType);
    BOOL shouldBeIdle = idleSeconds >= kIdleThreshold;
    if (shouldBeIdle == isSystemIdle) return;

    isSystemIdle = shouldBeIdle;
    if (!wallpaperWebViews) return;

    if (isSystemIdle) {
        broadcastJS(@"externalPause()");
    } else {
        broadcastJS(@"externalResume()");
    }
}

// MARK: - 辅助函数
static NSString *renderHTMLToTempFile(NSString *templatePath, NSString *videoPath) {
    NSError *err = nil;
    NSString *html = [NSString stringWithContentsOfFile:templatePath
                                               encoding:NSUTF8StringEncoding
                                                  error:&err];
    if (err) return nil;
    
    // 使用 NSURL 处理路径，确保编码正确
    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
    NSString *fileURL = [videoURL absoluteString];
    
    html = [html stringByReplacingOccurrencesOfString:@"{{VIDEO_PATH}}"
                                          withString:fileURL];

    NSString *videoDirectory = [[videoPath stringByDeletingLastPathComponent] stringByStandardizingPath];
    NSString *runUUID = [[NSUUID UUID] UUIDString];
    NSString *tempRootDir = [videoDirectory stringByAppendingPathComponent:@".wallpaper4mac"];
    NSString *tempDir = [tempRootDir stringByAppendingPathComponent:runUUID];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&err]) {
        NSLog(@"❌ 无法创建 HTML 渲染目录 %@: %@", tempDir, err);
        return nil;
    }

    NSString *fileName = [NSString stringWithFormat:@"wallpaper_%@.html", runUUID];
    NSString *tempPath = [tempDir stringByAppendingPathComponent:fileName];
    NSLog(@"📄 生成临时文件: %@", tempPath);
    
    [html writeToFile:tempPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    
    if (err) return nil;
    currentTempHTMLDirectory = [tempDir copy];
    return tempPath;
}

// MARK: - Objective-C 实现
@interface WallpaperDelegate : NSObject<WKNavigationDelegate>
@end

@implementation WallpaperDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [webView evaluateJavaScript:@"const v=document.getElementById('bg'); if(v){v.play().catch(()=>{});}" completionHandler:nil];
}
@end

static void setupSystemNotifications() {
    NSNotificationCenter *workspaceNC = [[NSWorkspace sharedWorkspace] notificationCenter];
    NSDistributedNotificationCenter *distributedNC = [NSDistributedNotificationCenter defaultCenter];
    NSNotificationCenter *defaultNC = [NSNotificationCenter defaultCenter];
    
    // 系统睡眠时暂停
    id willSleepToken =
        [workspaceNC addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        if (wallpaperWebViews) broadcastJS(@"externalPause()");
    }];
    addNotificationObserver(workspaceNC, willSleepToken);
    
    // 系统唤醒时恢复
    id didWakeToken =
        [workspaceNC addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        if (wallpaperWebViews) broadcastJS(@"externalResume()");
        isSystemIdle = NO;
    }];
    addNotificationObserver(workspaceNC, didWakeToken);

    // 锁屏时暂停
    id lockedToken =
        [distributedNC addObserverForName:@"com.apple.screenIsLocked" object:nil queue:nil
                               usingBlock:^(NSNotification *note) {
        if (wallpaperWebViews) broadcastJS(@"externalPause()");
    }];
    addNotificationObserver(distributedNC, lockedToken);

    // 解锁时恢复
    id unlockedToken =
        [distributedNC addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:nil
                               usingBlock:^(NSNotification *note) {
        if (wallpaperWebViews) broadcastJS(@"externalResume()");
        isSystemIdle = NO;
    }];
    addNotificationObserver(distributedNC, unlockedToken);
    
    // 应用终止前清理
    id terminateToken =
        [defaultNC addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                           usingBlock:^(NSNotification *note) {
        CleanupWallpaper();
    }];
    addNotificationObserver(defaultNC, terminateToken);

    if (!idleDetectionTimer) {
        idleDetectionTimer = [NSTimer timerWithTimeInterval:kIdleDetectionInterval
                                                    repeats:YES
                                                      block:^(__unused NSTimer *timer) {
            updateIdleState();
        }];
        [[NSRunLoop mainRunLoop] addTimer:idleDetectionTimer forMode:NSRunLoopCommonModes];
        updateIdleState();
    }
}

// MARK: - C 桥接函数
int InitWallpaper(const char *videoPathC, const char *htmlTemplateC) {
    NSLog(@"🎬 InitWallpaper 被调用");
    @autoreleasepool {
        // 确保 NSApp 初始化
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSString *videoPath = [NSString stringWithUTF8String:videoPathC];
        NSString *htmlTemplate = [NSString stringWithUTF8String:htmlTemplateC];
        
        // 路径校验
        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            fprintf(stderr, "❌ 视频文件不存在: %s\n", videoPathC);
            return -1;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:htmlTemplate]) {
            fprintf(stderr, "❌ HTML 模板不存在: %s\n", htmlTemplateC);
            return -1;
        }
        
        // 渲染 HTML 到临时文件
        NSString *tempHtmlPath = renderHTMLToTempFile(htmlTemplate, videoPath);
        if (!tempHtmlPath) {
            fprintf(stderr, "❌ HTML 渲染失败\n");
            return -1;
        }
        currentTempHTMLPath = [tempHtmlPath copy];
        
        // 配置 WKWebView
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        [config.preferences setValue:@NO forKey:@"developerExtrasEnabled"];

        NSRect primaryRect = [[NSScreen mainScreen] frame];
        webView = [[WKWebView alloc] initWithFrame:primaryRect configuration:config];
        webDelegate = [[WallpaperDelegate alloc] init];
        webView.navigationDelegate = webDelegate;
        [webView setValue:@NO forKey:@"drawsBackground"];
        
        // 加载 HTML 文件，仅授予视频所在目录读权限，避免回退到根目录。
        NSURL *htmlURL = [NSURL fileURLWithPath:tempHtmlPath];
        NSString *videoDirectory = [[videoPath stringByDeletingLastPathComponent] stringByStandardizingPath];
        NSURL *accessURL = [NSURL fileURLWithPath:videoDirectory isDirectory:YES];
        [webView loadFileURL:htmlURL allowingReadAccessToURL:accessURL];

        // 为每个显示器创建一个桌面层窗口，共享同一个 WKWebView 内容
        wallpaperWindows = [NSMutableArray array];
        wallpaperWebViews = [NSMutableArray array];
        for (NSScreen *screen in [NSScreen screens]) {
            NSRect screenRect = [screen frame];
            NSWindow *window = [[NSWindow alloc]
                initWithContentRect:screenRect
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO
                             screen:screen];

            // 使用桌面层级，让窗口位于桌面图标之下的壁纸层
            [window setLevel:CGWindowLevelForKey(kCGDesktopWindowLevelKey)];
            [window setOpaque:NO];
            [window setBackgroundColor:[NSColor clearColor]];
            [window setIgnoresMouseEvents:YES];
            [window setHasShadow:NO];
            [window setCollectionBehavior:
                NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorStationary |
                NSWindowCollectionBehaviorFullScreenAuxiliary];

            WKWebView *windowWebView;
            if (screen == [NSScreen mainScreen]) {
                windowWebView = webView;
                [windowWebView setFrame:screenRect];
            } else {
                windowWebView = [[WKWebView alloc] initWithFrame:screenRect configuration:config];
                windowWebView.navigationDelegate = webDelegate;
                [windowWebView setValue:@NO forKey:@"drawsBackground"];
                [windowWebView loadFileURL:htmlURL allowingReadAccessToURL:accessURL];
            }

            [window setContentView:windowWebView];
            [window orderFrontRegardless];
            [wallpaperWindows addObject:window];
            [wallpaperWebViews addObject:windowWebView];
        }
        
        // 设置系统通知
        setupSystemNotifications();
        
        NSLog(@"✅ 壁纸已启动: %@", videoPath);
        return 0;
    }
}

void StopApp() {
    NSLog(@"🛑 StopApp 被调用，发送退出事件");
    @autoreleasepool {
        // 必须在主线程执行 UI 操作
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp stop:nil];
            // 发送一个空事件来唤醒 RunLoop，确保 stop 立即生效
            NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:0
                                                 context:nil
                                                 subtype:0
                                                   data1:0
                                                   data2:0];
            [NSApp postEvent:event atStart:YES];
        });
    }
}

void RunApp() {
    @autoreleasepool {
        [NSApp run];
    }
}

void CleanupWallpaper() {
    NSLog(@"🧹 CleanupWallpaper 被调用");
    @autoreleasepool {
        if (idleDetectionTimer) {
            [idleDetectionTimer invalidate];
            idleDetectionTimer = nil;
        }
        isSystemIdle = NO;

        if (notificationObservers) {
            for (NSDictionary<NSString *, id> *observer in notificationObservers) {
                [observer[@"center"] removeObserver:observer[@"token"]];
            }
            notificationObservers = nil;
        }

        if (wallpaperWindows) {
            for (NSWindow *window in wallpaperWindows) {
                [window close];
            }
            wallpaperWindows = nil;
            wallpaperWebViews = nil;
            webView = nil;
            webDelegate = nil;
            NSLog(@"👋 壁纸已清理");
        }
        if (currentTempHTMLPath) {
            [[NSFileManager defaultManager] removeItemAtPath:currentTempHTMLPath error:nil];
            NSLog(@"🗑️ 临时文件已删除: %@", currentTempHTMLPath);
            currentTempHTMLPath = nil;
        }
        if (currentTempHTMLDirectory) {
            [[NSFileManager defaultManager] removeItemAtPath:currentTempHTMLDirectory error:nil];
            NSLog(@"🗑️ 临时目录已删除: %@", currentTempHTMLDirectory);
            currentTempHTMLDirectory = nil;
        }
    }
}
