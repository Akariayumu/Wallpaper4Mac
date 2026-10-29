//go:build darwin

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <WebKit/WebKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <objc/runtime.h>
#import "bridge.h"

static NSMutableArray<NSWindow *> *wallpaperWindows = nil;
static NSMutableArray<WKWebView *> *wallpaperWebViews = nil;
static WKWebView *webView = nil;
static id webDelegate = nil;
static WKProcessPool *sharedProcessPool = nil;
static NSString *currentTempHTMLPath = nil;
static NSString *currentTempHTMLDirectory = nil;
static NSMutableArray<NSDictionary<NSString *, id> *> *notificationObservers = nil;
static NSTimer *idleDetectionTimer = nil;
static NSTimer *idleResumeTimer = nil;
static BOOL isSystemIdle = NO;
static BOOL isSleepPaused = NO;
static BOOL isScreenLocked = NO;
static BOOL shouldPauseWhenIdle = YES;
static BOOL isPlaybackPaused = NO;
static NSTimeInterval configuredIdleDetectionInterval = 15.0;
static NSTimeInterval configuredIdleThreshold = 300.0;

// 屏幕关闭、电池供电、前台全屏、其他应用聚焦超过 kFocusPauseDelay 时暂停
static BOOL isDisplayAsleep = NO;
static BOOL isOnBattery = NO;
static BOOL isDesktopCovered = NO;
static BOOL isManuallyPaused = NO;
static CFRunLoopSourceRef powerSourceLoopSource = NULL;
static NSTimer *focusTimer = nil;
static NSDate *frontmostSince = nil;
static const NSTimeInterval kFocusPauseDelay = 5.0;

static void broadcastJS(NSString *script) {
    for (WKWebView *view in wallpaperWebViews) {
        [view evaluateJavaScript:script completionHandler:nil];
    }
}

// 菜单栏 GUI 通过分布式通知查询状态、手动暂停；状态变化时广播给它
static NSString *const kStateNotification = @"com.xstation.wallpaper4mac.state";
static NSString *const kQueryNotification = @"com.xstation.wallpaper4mac.query";
static NSString *const kManualPauseNotification = @"com.xstation.wallpaper4mac.setManualPause";

static void postPlaybackState(BOOL running) {
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    if (isManuallyPaused) [reasons addObject:@"手动暂停"];
    if (isOnBattery) [reasons addObject:@"电池供电"];
    if (isDisplayAsleep) [reasons addObject:@"屏幕已关闭"];
    if (isScreenLocked) [reasons addObject:@"已锁屏"];
    if (isSleepPaused) [reasons addObject:@"系统睡眠"];
    if (isDesktopCovered) [reasons addObject:@"其他应用在前台"];
    if (shouldPauseWhenIdle && isSystemIdle) [reasons addObject:@"长时间无操作"];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kStateNotification
                      object:nil
                    userInfo:@{
                        @"running": running ? @"1" : @"0",
                        @"paused": isPlaybackPaused ? @"1" : @"0",
                        @"manual": isManuallyPaused ? @"1" : @"0",
                        @"reasons": [reasons componentsJoinedByString:@"、"],
                    }
          deliverImmediately:YES];
}

static void syncPlaybackState(void) {
    BOOL shouldPause = (shouldPauseWhenIdle && isSystemIdle) || isSleepPaused || isScreenLocked ||
                       isDisplayAsleep || isOnBattery || isDesktopCovered || isManuallyPaused;
    if (shouldPause != isPlaybackPaused) {
        isPlaybackPaused = shouldPause;
        NSLog(@"%@ idle=%d sleep=%d locked=%d displayOff=%d battery=%d covered=%d manual=%d",
              shouldPause ? @"⏸️ 暂停" : @"▶️ 恢复",
              isSystemIdle, isSleepPaused, isScreenLocked, isDisplayAsleep, isOnBattery, isDesktopCovered,
              isManuallyPaused);
        broadcastJS(shouldPause ? @"externalPause()" : @"externalResume()");
    }
    // 原因变了但暂停状态没变时也通知 GUI，菜单里的原因保持最新
    postPlaybackState(YES);
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
    if (!shouldPauseWhenIdle) return;
    CFTimeInterval idleSeconds =
        CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,
                                               kCGAnyInputEventType);
    BOOL shouldBeIdle = idleSeconds >= configuredIdleThreshold;
    // 唤醒/解锁会直接清掉 isSystemIdle，这里顺带停掉快速检查
    if (!isSystemIdle && idleResumeTimer) {
        [idleResumeTimer invalidate];
        idleResumeTimer = nil;
    }
    if (shouldBeIdle == isSystemIdle) return;

    isSystemIdle = shouldBeIdle;
    syncPlaybackState();

    // 空闲暂停期间快速检查输入，触摸/鼠标/键盘一动就恢复，不用等下一次 15~30 秒的轮询
    [idleResumeTimer invalidate];
    idleResumeTimer = nil;
    if (isSystemIdle) {
        idleResumeTimer = [NSTimer timerWithTimeInterval:0.25
                                                 repeats:YES
                                                   block:^(__unused NSTimer *timer) {
            updateIdleState();
        }];
        idleResumeTimer.tolerance = 0.1;
        [[NSRunLoop mainRunLoop] addTimer:idleResumeTimer forMode:NSRunLoopCommonModes];
    }
}

static void updatePowerSourceState(void) {
    BOOL onBattery = NO;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info) {
        CFStringRef type = IOPSGetProvidingPowerSourceType(info);
        onBattery = type && CFStringCompare(type, CFSTR(kIOPMBatteryPowerKey), 0) == kCFCompareEqualTo;
        CFRelease(info);
    }
    if (onBattery == isOnBattery) return;
    isOnBattery = onBattery;
    syncPlaybackState();
}

static void powerSourceChanged(__unused void *context) {
    updatePowerSourceState();
}

// 前台应用在屏幕上是否有普通窗口；*fullScreen 返回其中是否有窗口铺满某个显示器。
// 只用窗口的 pid/层级/位置，不读窗口标题，所以不需要屏幕录制权限。
static BOOL appHasVisibleWindow(pid_t pid, BOOL *fullScreen) {
    *fullScreen = NO;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return NO;
    BOOL hasWindow = NO;
    for (NSDictionary *info in (__bridge NSArray *)list) {
        if ([info[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([info[(id)kCGWindowAlpha] doubleValue] <= 0.0) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds)) continue;
        if (bounds.size.width < 50 || bounds.size.height < 50) continue;
        hasWindow = YES;
        for (NSScreen *screen in [NSScreen screens]) {
            if (CGSizeEqualToSize(bounds.size, NSSizeToCGSize(screen.frame.size))) {
                *fullScreen = YES;
                break;
            }
        }
        if (*fullScreen) break;
    }
    CFRelease(list);
    return hasWindow;
}

static void updateDesktopCovered(void) {
    [focusTimer invalidate];
    focusTimer = nil;

    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    BOOL fullScreen = NO;
    BOOL covered = NO;
    if (app && app.processIdentifier != getpid()) {
        BOOL hasWindow = appHasVisibleWindow(app.processIdentifier, &fullScreen);
        // 访达在前台通常就是在看桌面，只在它全屏时才算遮住
        BOOL isFinder = [app.bundleIdentifier isEqualToString:@"com.apple.finder"];
        if (fullScreen) {
            covered = YES;
        } else if (hasWindow && !isFinder) {
            NSTimeInterval focused = frontmostSince ? -[frontmostSince timeIntervalSinceNow] : 0;
            if (focused >= kFocusPauseDelay) {
                covered = YES;
            } else {
                focusTimer = [NSTimer timerWithTimeInterval:kFocusPauseDelay - focused
                                                    repeats:NO
                                                      block:^(__unused NSTimer *timer) {
                    updateDesktopCovered();
                }];
                focusTimer.tolerance = 0.5;
                [[NSRunLoop mainRunLoop] addTimer:focusTimer forMode:NSRunLoopCommonModes];
            }
        }
    }
    if (covered == isDesktopCovered) return;
    isDesktopCovered = covered;
    syncPlaybackState();
}

// MARK: - 辅助函数
static NSString *renderHTMLToTempFile(NSString *templatePath, NSString *videoPath, int watchdogIntervalMS) {
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
    html = [html stringByReplacingOccurrencesOfString:@"{{WATCHDOG_INTERVAL_MS}}"
                                           withString:[NSString stringWithFormat:@"%d", MAX(0, watchdogIntervalMS)]];

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

static WKWebViewConfiguration *createWebViewConfiguration(void) {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    config.suppressesIncrementalRendering = YES;
    config.allowsAirPlayForMediaPlayback = NO;
    // 该属性在 macOS 15 SDK 里不存在（player.html 已用 disablepictureinpicture 关掉画中画）
    if ([config respondsToSelector:@selector(setAllowsPictureInPictureMediaPlayback:)]) {
        [config setValue:@NO forKey:@"allowsPictureInPictureMediaPlayback"];
    }
    if (!sharedProcessPool) {
        sharedProcessPool = [[WKProcessPool alloc] init];
    }
    config.processPool = sharedProcessPool;
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [config.preferences setValue:@NO forKey:@"developerExtrasEnabled"];
    return config;
}

// MARK: - Objective-C 实现
@interface WallpaperDelegate : NSObject<WKNavigationDelegate>
@end

@implementation WallpaperDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    // 页面加载前可能已经因电池/全屏等进入暂停，加载完成后按当前状态执行
    if (isPlaybackPaused) {
        [webView evaluateJavaScript:@"externalPause()" completionHandler:nil];
        return;
    }
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
        isSleepPaused = YES;
        syncPlaybackState();
    }];
    addNotificationObserver(workspaceNC, willSleepToken);
    
    // 系统唤醒时恢复
    id didWakeToken =
        [workspaceNC addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        isSleepPaused = NO;
        isSystemIdle = NO;
        syncPlaybackState();
    }];
    addNotificationObserver(workspaceNC, didWakeToken);

    // 锁屏时暂停
    id lockedToken =
        [distributedNC addObserverForName:@"com.apple.screenIsLocked" object:nil queue:nil
                               usingBlock:^(NSNotification *note) {
        isScreenLocked = YES;
        syncPlaybackState();
    }];
    addNotificationObserver(distributedNC, lockedToken);

    // 解锁时恢复
    id unlockedToken =
        [distributedNC addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:nil
                               usingBlock:^(NSNotification *note) {
        isScreenLocked = NO;
        isSystemIdle = NO;
        syncPlaybackState();
    }];
    addNotificationObserver(distributedNC, unlockedToken);

    // 屏幕关闭时暂停（系统不一定睡眠）
    id screensSleepToken =
        [workspaceNC addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        isDisplayAsleep = YES;
        syncPlaybackState();
    }];
    addNotificationObserver(workspaceNC, screensSleepToken);

    id screensWakeToken =
        [workspaceNC addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        isDisplayAsleep = NO;
        syncPlaybackState();
    }];
    addNotificationObserver(workspaceNC, screensWakeToken);

    // 切换前台应用：重新计时聚焦时长
    id activateToken =
        [workspaceNC addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        frontmostSince = [NSDate date];
        updateDesktopCovered();
    }];
    addNotificationObserver(workspaceNC, activateToken);

    // 进出全屏会切换空间；全屏动画结束后窗口尺寸才稳定，再查一次
    id spaceToken =
        [workspaceNC addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil
                             usingBlock:^(NSNotification *note) {
        updateDesktopCovered();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            updateDesktopCovered();
        });
    }];
    addNotificationObserver(workspaceNC, spaceToken);

    // 菜单栏 GUI：查询状态、手动暂停/继续
    id queryToken =
        [distributedNC addObserverForName:kQueryNotification object:nil queue:nil
                               usingBlock:^(NSNotification *note) {
        postPlaybackState(YES);
    }];
    addNotificationObserver(distributedNC, queryToken);

    id manualPauseToken =
        [distributedNC addObserverForName:kManualPauseNotification object:nil queue:nil
                               usingBlock:^(NSNotification *note) {
        isManuallyPaused = [note.userInfo[@"paused"] isEqual:@"1"];
        syncPlaybackState();
    }];
    addNotificationObserver(distributedNC, manualPauseToken);

    // 接电/拔电
    if (!powerSourceLoopSource) {
        powerSourceLoopSource = IOPSNotificationCreateRunLoopSource(powerSourceChanged, NULL);
        if (powerSourceLoopSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceLoopSource, kCFRunLoopCommonModes);
        }
    }
    frontmostSince = [NSDate date];
    updatePowerSourceState();
    updateDesktopCovered();

    // 应用终止前清理
    id terminateToken =
        [defaultNC addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                           usingBlock:^(NSNotification *note) {
        CleanupWallpaper();
    }];
    addNotificationObserver(defaultNC, terminateToken);

    if (shouldPauseWhenIdle && configuredIdleThreshold > 0 && configuredIdleDetectionInterval > 0 && !idleDetectionTimer) {
        idleDetectionTimer = [NSTimer timerWithTimeInterval:configuredIdleDetectionInterval
                                                    repeats:YES
                                                      block:^(__unused NSTimer *timer) {
            updateIdleState();
            // 前台应用关掉所有窗口时没有通知，顺带复查一次
            updateDesktopCovered();
        }];
        idleDetectionTimer.tolerance = MIN(configuredIdleDetectionInterval * 0.25, 5.0);
        [[NSRunLoop mainRunLoop] addTimer:idleDetectionTimer forMode:NSRunLoopCommonModes];
        updateIdleState();
    }
}

// MARK: - C 桥接函数
int InitWallpaper(const char *videoPathC,
                  const char *htmlTemplateC,
                  double idleThresholdSeconds,
                  double idlePollIntervalSeconds,
                  int pauseWhenIdle,
                  int watchdogIntervalMS) {
    NSLog(@"🎬 InitWallpaper 被调用");
    @autoreleasepool {
        // 确保 NSApp 初始化
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSString *videoPath = [NSString stringWithUTF8String:videoPathC];
        NSString *htmlTemplate = [NSString stringWithUTF8String:htmlTemplateC];
        configuredIdleThreshold = idleThresholdSeconds > 0 ? idleThresholdSeconds : 300.0;
        configuredIdleDetectionInterval = idlePollIntervalSeconds > 0 ? idlePollIntervalSeconds : 15.0;
        shouldPauseWhenIdle = pauseWhenIdle != 0;
        isSystemIdle = NO;
        isSleepPaused = NO;
        isScreenLocked = NO;
        isPlaybackPaused = NO;
        
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
        NSString *tempHtmlPath = renderHTMLToTempFile(htmlTemplate, videoPath, watchdogIntervalMS);
        if (!tempHtmlPath) {
            fprintf(stderr, "❌ HTML 渲染失败\n");
            return -1;
        }
        currentTempHTMLPath = [tempHtmlPath copy];
        
        // 配置 WKWebView
        WKWebViewConfiguration *config = createWebViewConfiguration();

        NSRect primaryRect = [[NSScreen mainScreen] frame];
        webView = [[WKWebView alloc] initWithFrame:primaryRect configuration:config];
        webDelegate = [[WallpaperDelegate alloc] init];
        webView.navigationDelegate = webDelegate;
        [webView setValue:@NO forKey:@"drawsBackground"];
        if ([webView respondsToSelector:@selector(setUnderPageBackgroundColor:)]) {
            [webView setUnderPageBackgroundColor:[NSColor clearColor]];
        }
        
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
                windowWebView = [[WKWebView alloc] initWithFrame:screenRect configuration:createWebViewConfiguration()];
                windowWebView.navigationDelegate = webDelegate;
                [windowWebView setValue:@NO forKey:@"drawsBackground"];
                if ([windowWebView respondsToSelector:@selector(setUnderPageBackgroundColor:)]) {
                    [windowWebView setUnderPageBackgroundColor:[NSColor clearColor]];
                }
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
        [focusTimer invalidate];
        focusTimer = nil;
        [idleResumeTimer invalidate];
        idleResumeTimer = nil;
        if (powerSourceLoopSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceLoopSource, kCFRunLoopCommonModes);
            CFRelease(powerSourceLoopSource);
            powerSourceLoopSource = NULL;
        }
        isDisplayAsleep = NO;
        isOnBattery = NO;
        isDesktopCovered = NO;
        isManuallyPaused = NO;
        isSystemIdle = NO;
        isSleepPaused = NO;
        isScreenLocked = NO;
        isPlaybackPaused = NO;
        postPlaybackState(NO);

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
            sharedProcessPool = nil;
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
