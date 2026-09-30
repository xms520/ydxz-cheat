// ============================================================================
//  跃动小子 (com.baixiangzs.ydxz1) 助手  v1.0
//  引擎: Egret 5.x + eui + EgretNative(iOS) / JavaScriptCore
//
//  注入链:
//    1) fishhook 重绑定 JSGlobalContextCreateInGroup / JSEvaluateScript
//       —— 拿到游戏 JS 的 JSGlobalContextRef
//    2) 拿到 ctx 后 JSEvaluateScript 注入 ydxz_inject.js（内嵌字符串）
//    3) 定时器把面板开关写进 JS: window.__ydxz_cfg
//    4) 定时器读回 window.__ydxz_state() 刷新面板状态 + 写日志
//
//  ⚠️ 侧载环境无 CydiaSubstrate —— 只使用 fishhook + objc runtime，禁止链接 substrate
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include "fishhook.h"

extern const char *ydxz_inject_js(void);
extern const char *ydxz_avatar_b64(void);

#define YDXZ_VERSION "1.0"

// --------------------------------------------------------------------- 日志
static FILE *g_log = NULL;
static NSString *g_docs = nil;

static void mlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void mlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!g_log && g_docs) {
        NSString *p = [g_docs stringByAppendingPathComponent:@"ydxz.log"];
        g_log = fopen(p.UTF8String, "a");
    }
    if (g_log) {
        fprintf(g_log, "[YDXZ] %s\n", s.UTF8String);
        fflush(g_log);
    }
    NSLog(@"[YDXZ] %@", s);
}

static NSString *ydxz_docs(void) {
    if (g_docs) return g_docs;
    NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_docs = a.count ? a.firstObject : NSTemporaryDirectory();
    return g_docs;
}

// ------------------------------------------------------------------ 开关状态
typedef struct {
    int kill;        // 秒杀（FightEntity 系）
    int killTower;   // 秒杀（塔防实体）
    int god;         // 无敌（FightEntity 系）
    int godTower;    // 无敌（塔防实体）
    int fastBox;     // 开箱/战斗 Tween 倍率: 0=关 2/4/8
    int fastBoxAnim; // Spine 动画 timeScale
    int autoBox;     // 自动开箱
    int ad;          // 免广告
    int speed;       // 变速（Tween 推进倍率）
} YDXZFlags;

static YDXZFlags g_f = {0, 0, 0, 0, 0, 0, 0, 0, 0};
static NSString *g_state = @"";      // JS 回读的 __ydxz_state()

static NSDictionary *flags_dict(void) {
    return @{@"kill": @(g_f.kill), @"killTower": @(g_f.killTower),
             @"god": @(g_f.god), @"godTower": @(g_f.godTower),
             @"fastBox": @(g_f.fastBox), @"fastBoxAnim": @(g_f.fastBoxAnim),
             @"autoBox": @(g_f.autoBox), @"ad": @(g_f.ad), @"speed": @(g_f.speed)};
}

static void flags_save(void) {
    NSString *p = [ydxz_docs() stringByAppendingPathComponent:@"ydxz_flags.json"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:flags_dict() options:0 error:nil];
    if (d) [d writeToFile:p atomically:YES];
}

// ------------------------------------------------------- JavaScriptCore 桥
static JSGlobalContextRef g_ctx = NULL;
static BOOL g_jsReady = NO;          // 注入脚本是否已执行
static void ydxz_js_inject_async(void);
static NSString *ydxz_js_eval(NSString *script);
static NSString *ydxz_js_eval_str(NSString *script);
static void ydxz_sync_to_js(void);
static void ydxz_read_state(void);
static void ydxz_ensure_overlay(void);

static JSGlobalContextRef (*orig_JSGlobalContextCreateInGroup)(JSContextGroupRef, JSClassRef) = NULL;
static JSValueRef (*orig_JSEvaluateScript)(JSContextRef, JSStringRef, JSObjectRef,
                                           JSStringRef, int, JSValueRef *) = NULL;

// 取得 ctx（首次创建时保留一份）
static void ydxz_grab_ctx(JSGlobalContextRef ctx) {
    if (!ctx || g_ctx) return;
    g_ctx = JSGlobalContextRetain(ctx);
    mlog(@"JSC context captured: %p", g_ctx);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ydxz_js_inject_async();
    });
}

static JSGlobalContextRef my_JSGlobalContextCreateInGroup(JSContextGroupRef group, JSClassRef cls) {
    JSGlobalContextRef ctx = NULL;
    if (orig_JSGlobalContextCreateInGroup) ctx = orig_JSGlobalContextCreateInGroup(group, cls);
    ydxz_grab_ctx(ctx);
    return ctx;
}

static JSValueRef my_JSEvaluateScript(JSContextRef ctx, JSStringRef script, JSObjectRef thisObject,
                                      JSStringRef sourceURL, int startingLineNumber, JSValueRef *exception) {
    if (!g_ctx && ctx) ydxz_grab_ctx((JSGlobalContextRef)ctx);
    if (orig_JSEvaluateScript)
        return orig_JSEvaluateScript(ctx, script, thisObject, sourceURL, startingLineNumber, exception);
    return NULL;
}

static void ydxz_install_jsc_hooks(void) {
    struct rebinding rb[2];
    rb[0].name = "JSGlobalContextCreateInGroup";
    rb[0].replacement = (void *)my_JSGlobalContextCreateInGroup;
    rb[0].replaced = (void **)&orig_JSGlobalContextCreateInGroup;
    rb[1].name = "JSEvaluateScript";
    rb[1].replacement = (void *)my_JSEvaluateScript;
    rb[1].replaced = (void **)&orig_JSEvaluateScript;
    int r = rebind_symbols(rb, 2);
    mlog(@"fishhook JSC rebind => %d (0=ok)", r);
}

// ============================================================ JS 执行封装
static JSValueRef ydxz_eval_ref(NSString *script) {
    if (!g_ctx || !script) return NULL;
    JSStringRef s = JSStringCreateWithCFString((__bridge CFStringRef)script);
    if (!s) return NULL;
    JSValueRef exc = NULL;
    JSValueRef v = JSEvaluateScript(g_ctx, s, NULL, NULL, 0, &exc);
    JSStringRelease(s);
    if (exc) {
        NSString *msg = nil;
        JSStringRef es = JSValueToStringCopy(g_ctx, exc, NULL);
        if (es) {
            size_t n = JSStringGetMaximumUTF8CStringSize(es);
            char *b = (char *)malloc(n);
            if (b) { JSStringGetUTF8CString(es, b, n); msg = @(b); free(b); }
            JSStringRelease(es);
        }
        if (msg && ![msg isEqualToString:@"ReferenceError: Can't find variable: __ydxz_booted"])
            mlog(@"JS exception: %@", msg);
        return NULL;
    }
    return v;
}

static NSString *ydxz_js_eval_str(NSString *script) {
    JSValueRef v = ydxz_eval_ref(script);
    if (!v) return nil;
    JSStringRef s = JSValueToStringCopy(g_ctx, v, NULL);
    if (!s) return nil;
    NSString *r = nil;
    size_t n = JSStringGetMaximumUTF8CStringSize(s);
    char *b = (char *)malloc(n);
    if (b) { JSStringGetUTF8CString(s, b, n); r = @(b); free(b); }
    JSStringRelease(s);
    return r;
}

static NSString *ydxz_js_eval(NSString *script) { return ydxz_js_eval_str(script); }

// ---------------------------------------------------------- 注入 / 同步 / 回读
static void ydxz_js_inject_async(void) {
    if (!g_ctx) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_ctx) return;
        // 已注入过？
        NSString *done = ydxz_js_eval_str(@"String(!!(window.__ydxz_booted))");
        if (done && [done isEqualToString:@"true"]) { g_jsReady = YES; mlog(@"JS payload 已在位"); return; }

        const char *js = ydxz_inject_js();
        if (!js) { mlog(@"✕ JS payload 缺失"); return; }
        NSString *src = @(js);
        mlog(@"注入 JS payload (%lu 字节)", (unsigned long)src.length);
        JSValueRef v = ydxz_eval_ref(src);
        if (v) {
            g_jsReady = YES;
            NSString *st = ydxz_js_eval_str(@"String(!!window.__ydxz_booted)");
            mlog(@"注入完成 booted=%@", st);
            ydxz_sync_to_js();
            ydxz_read_state();
        } else {
            mlog(@"✕ JS payload 执行失败（无返回值）");
        }
    });
}

static void ydxz_sync_to_js(void) {
    if (!g_ctx || !g_jsReady) return;
    NSString *js = [NSString stringWithFormat:
        @"(function(){try{var c=window.__ydxz_cfg||{};"
         "c.kill=%d;c.killTower=%d;c.god=%d;c.godTower=%d;c.fastBox=%d;c.fastBoxAnim=%d;"
         "c.autoBox=%d;c.ad=%d;c.speed=%d;window.__ydxz_cfg=c;}catch(e){}})()",
        g_f.kill, g_f.killTower, g_f.god, g_f.godTower,
        g_f.fastBox, g_f.fastBoxAnim, g_f.autoBox, g_f.ad, g_f.speed];
    ydxz_eval_ref(js);
}

static void ydxz_read_state(void) {
    if (!g_ctx || !g_jsReady) return;
    NSString *s = ydxz_js_eval_str(@"String((window.__ydxz_state&&window.__ydxz_state())||'')");
    if (s.length) g_state = s;
}

// ------------------------------------------------------------------ 面板 UI
@class YDXZBox;
static UIView *g_ball = nil;
static YDXZBox *g_panel = nil;
static UILabel *g_lbKill = nil, *g_lbGod = nil, *g_lbBox = nil, *g_lbAd = nil;
static UILabel *g_lbTKill = nil, *g_lbTGod = nil, *g_lbStatus = nil;

static UIImage *ydxz_avatar(void) {
    static UIImage *img = nil;
    if (img) return img;
    const char *b64 = ydxz_avatar_b64();
    if (!b64) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:@(b64)
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (d) img = [UIImage imageWithData:d];
    return img;
}

static void ydxz_add_rainbow(UIView *v, CGFloat inner) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = v.bounds;
    g.type = kCAGradientLayerConic;
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(0.5, 0);
    g.colors = @[(id)[UIColor colorWithRed:0.0 green:0.9 blue:1.0 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.5 green:0.3 blue:1.0 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:1.0 green:0.2 blue:0.5 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:1.0 green:0.7 blue:0.1 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.0 green:0.9 blue:1.0 alpha:1].CGColor];
    CAShapeLayer *mask = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:v.bounds];
    CGFloat inset = v.bounds.size.width * (1.0 - inner) / 2.0;
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(v.bounds, inset, inset)]];
    mask.path = p.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    g.mask = mask;
    [v.layer addSublayer:g];
}

static void ydxz_refresh_buttons(void) {
    g_lbKill.text  = g_f.kill  ? [NSString stringWithFormat:@"⚔️ 秒杀  x%@", g_f.kill > 1 ? @(g_f.kill) : @"MAX"] : @"⚔️ 秒杀  OFF";
    g_lbTKill.text = g_f.killTower ? @"🏹 塔防秒杀 ON" : @"🏹 塔防秒杀 OFF";
    g_lbGod.text   = g_f.god   ? @"🛡 无敌  ON"   : @"🛡 无敌  OFF";
    g_lbTGod.text  = g_f.godTower ? @"🏰 塔防无敌 ON" : @"🏰 塔防无敌 OFF";
    g_lbBox.text   = g_f.fastBox ? [NSString stringWithFormat:@"📦 快速开箱 x%d", g_f.fastBox]
                                 : (g_f.autoBox ? @"📦 自动开箱 ON" : @"📦 快速开箱 OFF");
    g_lbAd.text    = g_f.ad    ? @"🚫 免广告 ON"   : @"🚫 免广告 OFF";

    UIColor *on  = [UIColor colorWithRed:0.30 green:1.00 blue:0.45 alpha:1];
    UIColor *on2 = [UIColor colorWithRed:1.00 green:0.78 blue:0.20 alpha:1];
    UIColor *off = [UIColor colorWithWhite:1 alpha:0.40];
    g_lbKill.textColor  = g_f.kill  ? on2 : off;
    g_lbTKill.textColor = g_f.killTower ? on2 : off;
    g_lbGod.textColor   = g_f.god   ? on  : off;
    g_lbTGod.textColor  = g_f.godTower ? on : off;
    g_lbBox.textColor   = (g_f.fastBox || g_f.autoBox) ? on : off;
    g_lbAd.textColor    = g_f.ad    ? on2 : off;

    if (g_lbStatus) {
        NSString *s = g_state.length > 180 ? [g_state substringToIndex:180] : g_state;
        g_lbStatus.text = s.length ? s : @"(等待 JS 状态…)";
    }
}

@interface YDXZBox : UIView
@end

@implementation YDXZBox
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.11 alpha:0.97];
        self.layer.cornerRadius = 18;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.55;
        self.layer.shadowRadius = 14;
        self.userInteractionEnabled = YES;

        UIImageView *av = [[UIImageView alloc] initWithFrame:CGRectMake(14, 14, 42, 42)];
        av.image = ydxz_avatar();
        av.layer.cornerRadius = 21;
        av.layer.masksToBounds = YES;
        av.layer.borderWidth = 2.5;
        av.layer.borderColor = [UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1].CGColor;
        [self addSubview:av];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(64, 12, f.size.width - 110, 24)];
        title.text = @"✦ 昆哥儿科技 ✦";
        title.textColor = [UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1];
        title.font = [UIFont boldSystemFontOfSize:16];
        [self addSubview:title];

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(64, 35, f.size.width - 110, 16)];
        sub.text = [NSString stringWithFormat:@"跃动小子 · 助手 v%s", @YDXZ_VERSION];
        sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        sub.font = [UIFont systemFontOfSize:10];
        [self addSubview:sub];

        UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
        x.frame = CGRectMake(f.size.width - 42, 12, 32, 32);
        [x setTitle:@"✕" forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [x setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:x];

        CGFloat y = 64, h = 38, gap = 6;
        for (int i = 0; i < 6; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(14, y, f.size.width - 28, h);
            b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
            b.layer.cornerRadius = 10;
            b.tag = i;
            [b addTarget:self action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
            UILabel *lb = [[UILabel alloc] initWithFrame:b.bounds];
            lb.textAlignment = NSTextAlignmentCenter;
            lb.font = [UIFont boldSystemFontOfSize:13];
            [b addSubview:lb];
            switch (i) {
                case 0: g_lbKill = lb; break;
                case 1: g_lbGod  = lb; break;
                case 2: g_lbTKill = lb; break;
                case 3: g_lbTGod = lb; break;
                case 4: g_lbBox  = lb; break;
                case 5: g_lbAd   = lb; break;
            }
            [self addSubview:b];
            y += h + gap;
        }

        g_lbStatus = [[UILabel alloc] initWithFrame:CGRectMake(14, y + 2, f.size.width - 28, f.size.height - y - 8)];
        g_lbStatus.numberOfLines = 0;
        g_lbStatus.textColor = [UIColor colorWithWhite:1 alpha:0.35];
        g_lbStatus.font = [UIFont systemFontOfSize:8];
        [self addSubview:g_lbStatus];

        ydxz_refresh_buttons();

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)closeTap { [g_panel removeFromSuperview]; g_panel = nil; }
- (void)btnTap:(UIButton *)b {
    switch (b.tag) {
        case 0: g_f.kill  = g_f.kill  ? 0 : 1; break;                       // 秒杀 开/关
        case 1: g_f.god   = !g_f.god;  break;                               // 无敌
        case 2: g_f.killTower = g_f.killTower ? 0 : 1; break;               // 塔防秒杀
        case 3: g_f.godTower  = !g_f.godTower; break;                       // 塔防无敌
        case 4: // 快速开箱 / 自动开箱 循环: OFF → x2 → x4 → x8 → 自动 → OFF
            if (g_f.fastBox == 0 && !g_f.autoBox) { g_f.fastBox = 2; }
            else if (g_f.fastBox == 2) { g_f.fastBox = 4; }
            else if (g_f.fastBox == 4) { g_f.fastBox = 8; }
            else if (g_f.fastBox == 8) { g_f.fastBox = 0; g_f.autoBox = 1; }
            else { g_f.autoBox = 0; g_f.fastBox = 0; }
            g_f.fastBoxAnim = g_f.fastBox ? 3 : 0;
            break;
        case 5: g_f.ad = !g_f.ad; break;                                    // 免广告
    }
    ydxz_refresh_buttons();
    flags_save();
    ydxz_sync_to_js();
    mlog(@"btn %ld -> kill=%d god=%d kT=%d gT=%d box=%d auto=%d ad=%d",
         (long)b.tag, g_f.kill, g_f.god, g_f.killTower, g_f.godTower,
         g_f.fastBox, g_f.autoBox, g_f.ad);
}
- (void)drag:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:self.superview];
    CGPoint c = self.center; c.x += t.x; c.y += t.y;
    [p setTranslation:CGPointZero inView:self.superview];
    CGRect scr = self.superview.bounds;
    c.x = MAX(self.bounds.size.width / 2, MIN(scr.size.width - self.bounds.size.width / 2, c.x));
    c.y = MAX(self.bounds.size.height / 2, MIN(scr.size.height - self.bounds.size.height / 2, c.y));
    self.center = c;
}
@end

// ------------------------------------------------------------------ 悬浮球
@implementation UIView (YDXZGestures)
- (void)ydxz_ballDrag:(UIPanGestureRecognizer *)p {
    UIView *b = self;
    CGPoint t = [p translationInView:b.superview];
    CGPoint c = b.center; c.x += t.x; c.y += t.y;
    [p setTranslation:CGPointZero inView:b.superview];
    CGRect scr = b.superview.bounds;
    c.x = MAX(b.bounds.size.width / 2, MIN(scr.size.width - b.bounds.size.width / 2, c.x));
    c.y = MAX(b.bounds.size.height / 2, MIN(scr.size.height - b.bounds.size.height / 2, c.y));
    b.center = c;
}
- (void)ydxz_ballTap:(UITapGestureRecognizer *)p {
    UIWindow *w = self.window;
    if (!w) return;
    if (g_panel) { [g_panel removeFromSuperview]; g_panel = nil; return; }
    CGFloat pw = 262, ph = 400;
    CGRect scr = w.bounds;
    CGFloat px = self.center.x - pw / 2;
    px = MAX(10, MIN(scr.size.width - pw - 10, px));
    CGFloat py = self.center.y + 72;
    py = MAX(10, MIN(scr.size.height - ph - 10, py));
    g_panel = [[YDXZBox alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    [w addSubview:g_panel];
    [w bringSubviewToFront:g_panel];
    ydxz_read_state();
    ydxz_refresh_buttons();
    mlog(@"panel opened %.0f,%.0f", px, py);
}
@end

static UIView *ydxz_build_ball(void) {
    CGFloat bs = 58;
    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bs, bs)];
    ball.layer.cornerRadius = bs / 2;
    ball.layer.masksToBounds = NO;
    ball.layer.shadowColor = UIColor.blackColor.CGColor;
    ball.layer.shadowOpacity = 0.6;
    ball.layer.shadowRadius = 6;
    ball.layer.shadowOffset = CGSizeMake(0, 2);
    ydxz_add_rainbow(ball, 0.88);
    UIImageView *ava = [[UIImageView alloc] initWithFrame:CGRectMake(3, 3, bs - 6, bs - 6)];
    ava.image = ydxz_avatar();
    ava.layer.cornerRadius = (bs - 6) / 2;
    ava.layer.masksToBounds = YES;
    [ball addSubview:ava];
    [ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:ball
                                                                     action:@selector(ydxz_ballTap:)]];
    [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:ball
                                                                     action:@selector(ydxz_ballDrag:)]];
    return ball;
}

static UIWindow *ydxz_window(void) {
    UIWindow *w = nil;
    id<UIApplicationDelegate> d = [UIApplication sharedApplication].delegate;
    if ([d respondsToSelector:@selector(window)]) w = [d window];
    if (w) return w;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *ww in ws.windows) { if (ww.isKeyWindow) return ww; }
        if (ws.windows.count) return ws.windows.firstObject;
    }
    return nil;
}

static void ydxz_ensure_overlay(void) {
    UIWindow *w = ydxz_window();
    if (!w) return;
    BOOL need = NO;
    if (!g_ball) { g_ball = ydxz_build_ball(); need = YES; }
    else if (g_ball.superview != w) { need = YES; }
    else if (w.subviews.lastObject != g_ball) { [w bringSubviewToFront:g_ball]; }
    if (need) {
        CGRect scr = w.bounds;
        g_ball.center = CGPointMake(scr.size.width - 57, scr.size.height * 0.40);
        [w addSubview:g_ball];
        [w bringSubviewToFront:g_ball];
        mlog(@"ball attached %.0fx%.0f", scr.size.width, scr.size.height);
    }
    if (g_panel && g_panel.superview == w && w.subviews.lastObject != g_panel)
        [w bringSubviewToFront:g_panel];
}

// ------------------------------------------------------------------- 定时器
static void ydxz_on_tick(void) {
    ydxz_ensure_overlay();
    if (!g_ctx) return;
    if (!g_jsReady) { ydxz_js_inject_async(); return; }
    ydxz_sync_to_js();
    ydxz_read_state();
    if (g_panel) ydxz_refresh_buttons();
}

// ---------------------------------------------------------------- 广告兜底
// ⚠️ 不 hook showRewardAd（无法伪造 SDK 回调）；只保留免广告的 JS 侧实现。
//    如需 native 兜底，可在 AppDelegate 的 onRewardAdError: 时吞掉错误，风险高，默认关闭。

// ------------------------------------------------------------ install / ctor
static void ydxz_install(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    mlog(@"=========== 跃动小子助手 v%s 加载 ===========", YDXZ_VERSION);
    ydxz_install_jsc_hooks();

    /* 保底：5 秒后若仍未拿到 ctx → 说明 fishhook 未生效（链式修复/加固），
       走 objc 侧兜底：直接尝试用 JSContext 实例拿 globalContext。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_ctx) return;
        mlog(@"⚠️ 未捕获 JSContext，尝试 JSContext 实例兜底");
        Class c = objc_getClass("JSContext");
        if (!c) { mlog(@"✕ JSContext 类不存在"); return; }
        /* 遍历已创建的 JSContext 实例不可行，改为 hook -[JSContext initWithVirtualMachine:] */
        Class cls = objc_getClass("JSContext");
        Method m = class_getInstanceMethod(cls, @selector(initWithVirtualMachine:));
        if (m) {
            IMP orig = method_getImplementation(m);
            __block IMP o = orig;
            IMP newImp = imp_implementationWithBlock(^id(id self_, id vm) {
                id ctx = ((id (*)(id, SEL, id))o)(self_, @selector(initWithVirtualMachine:), vm);
                if (ctx) {
                    @try {
                        JSContext *jc = (JSContext *)ctx;
                        JSGlobalContextRef gr = (JSGlobalContextRef)[jc JSGlobalContextRef];
                        if (gr) { mlog(@"兜底拿到 ctx %p", gr); ydxz_grab_ctx(gr); }
                    } @catch (NSException *e) { mlog(@"兜底异常 %@", e); }
                }
                return ctx;
            });
            method_setImplementation(m, newImp);
            mlog(@"已 hook -[JSContext initWithVirtualMachine:]");
        } else {
            mlog(@"✕ 取不到 initWithVirtualMachine:");
        }
    });
}

__attribute__((constructor))
static void ydxz_ctor(void) {
    @autoreleasepool {
        mlog(@"ctor v%s", YDXZ_VERSION);

        /* 主线程定时器：驱动 overlay + JS 同步。用 NSTimer 替代 CADisplayLink，
           避免依赖任何游戏对象。 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ydxz_install();
            NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tt) {
                @autoreleasepool { ydxz_on_tick(); }
            }];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
