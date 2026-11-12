// NeXTSkin: an Ammonia tweak that dresses Apple's own apps in TinyMacII's NeXT look (see ../SIP-OFF-PLAN.md).
// Test version, loaded only into the apps named in NeXTSkin.dylib.allowlist (TextEdit):
//  • title bar: the standard buttons and title are hidden and NeXT's black bar is drawn over the title bar,
//    miniaturize box on the left, close box on the right, bold white centred title; drag it to move the window
//  • resize bar: NeXT's bevelled bar along the bottom edge (end segments resize the width too)
//  • scrollers: vertical scrollers become NeXT's, on the left, dark track, bevelled knob, both arrows at the bottom
// Drawing matches NeXTKit.swift. Built arm64 + arm64e by build.sh.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const CGFloat kTitleHeight = 23, kResizeHeight = 9, kBar = 18;
static const void *kSkinnedKey = &kSkinnedKey;

static NSColor *Face(void) { return [NSColor colorWithCalibratedWhite:0.667 alpha:1]; }
static NSColor *Dark(void) { return [NSColor colorWithCalibratedWhite:0.333 alpha:1]; }
static NSFont *BoldFont(void) { return [NSFont fontWithName:@"Helvetica-Bold" size:12] ?: [NSFont boldSystemFontOfSize:12]; }
static void Fill(NSColor *color, NSRect r) { [color setFill]; NSRectFill(r); }

/// NeXT's raised bevel (white top/left, black bottom/right, dark inner edge), in an unflipped view.
static void Bevel(NSRect r) {
    Fill(Face(), r);
    Fill(NSColor.whiteColor, NSMakeRect(r.origin.x, NSMaxY(r) - 1, r.size.width, 1));
    Fill(NSColor.whiteColor, NSMakeRect(r.origin.x, r.origin.y, 1, r.size.height));
    Fill(NSColor.blackColor, NSMakeRect(r.origin.x, r.origin.y, r.size.width, 1));
    Fill(NSColor.blackColor, NSMakeRect(NSMaxX(r) - 1, r.origin.y, 1, r.size.height));
    Fill(Dark(), NSMakeRect(r.origin.x + 1, r.origin.y + 1, r.size.width - 2, 1));
    Fill(Dark(), NSMakeRect(NSMaxX(r) - 2, r.origin.y + 1, 1, r.size.height - 2));
}

// MARK: Title bar

@interface NXTitleBar : NSView
@end

@implementation NXTitleBar
- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSRect)miniaturizeBox { return NSMakeRect(4, NSMidY(self.bounds) - 7.5, 15, 15); }
- (NSRect)closeBox { return NSMakeRect(NSMaxX(self.bounds) - 19, NSMidY(self.bounds) - 7.5, 15, 15); }

- (void)drawRect:(NSRect)dirtyRect {
    BOOL key = self.window.isKeyWindow;
    Fill(key ? NSColor.blackColor : Dark(), self.bounds);
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSDictionary *attributes = @{NSFontAttributeName: BoldFont(), NSForegroundColorAttributeName: key ? NSColor.whiteColor : Face(),
                                 NSParagraphStyleAttributeName: style};
    NSString *title = self.window.title ?: @"";
    CGFloat height = [title sizeWithAttributes:attributes].height;
    [title drawInRect:NSMakeRect(24, floor((self.bounds.size.height - height) / 2), self.bounds.size.width - 48, height) withAttributes:attributes];
    NSRect mini = self.miniaturizeBox, close = self.closeBox;
    Bevel(mini);
    [NSColor.blackColor setStroke];
    [NSBezierPath strokeRect:NSInsetRect(mini, 4.5, 4.5)];
    Bevel(close);
    NSRect r = NSInsetRect(close, 4, 4);
    NSBezierPath *x = [NSBezierPath bezierPath];
    [x moveToPoint:r.origin]; [x lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r))];
    [x moveToPoint:NSMakePoint(r.origin.x, NSMaxY(r))]; [x lineToPoint:NSMakePoint(NSMaxX(r), r.origin.y)];
    x.lineWidth = 1.5;
    [x stroke];
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *window = self.window;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.closeBox)) { [window performClose:nil]; return; }
    if (NSPointInRect(p, self.miniaturizeBox)) { [window performMiniaturize:nil]; return; }
    if (event.clickCount == 2) { [window performZoom:nil]; return; }
    [window makeKeyAndOrderFront:nil];
    [window performWindowDragWithEvent:event];
}
@end

// MARK: Resize bar

@interface NXResizeBar : NSView
@end

@implementation NXResizeBar
- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    Bevel(self.bounds);
    for (NSNumber *n in @[@28, @(NSMaxX(self.bounds) - 28)]) {
        CGFloat x = n.doubleValue;
        Fill(NSColor.blackColor, NSMakeRect(x, 0, 1, self.bounds.size.height));
        Fill(NSColor.whiteColor, NSMakeRect(x + 1, 1, 1, self.bounds.size.height - 2));
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *window = self.window;
    CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
    BOOL left = x < 28, right = x > NSMaxX(self.bounds) - 28;
    NSPoint start = NSEvent.mouseLocation;
    NSRect frame = window.frame;
    NSSize minimum = window.minSize;
    while (YES) {
        NSEvent *next = [window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (next.type != NSEventTypeLeftMouseDragged) break;
        NSPoint p = NSEvent.mouseLocation;
        NSRect f = frame;
        f.size.height = MAX(minimum.height, frame.size.height + start.y - p.y);
        f.origin.y = NSMaxY(frame) - f.size.height;
        if (right) f.size.width = MAX(minimum.width, frame.size.width + p.x - start.x);
        if (left) {
            f.size.width = MAX(minimum.width, frame.size.width - (p.x - start.x));
            f.origin.x = NSMaxX(frame) - f.size.width;
        }
        [window setFrame:f display:YES];
    }
}
@end

// MARK: Scroller

@interface NXScroller : NSScroller
@end

@implementation NXScroller
+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)size scrollerStyle:(NSScrollerStyle)style { return kBar + 1; }
+ (BOOL)isCompatibleWithOverlayScrollers { return NO; }
- (BOOL)isFlipped { return NO; }

- (NSScrollView *)scrollView { return [self.superview isKindOfClass:NSScrollView.class] ? (NSScrollView *)self.superview : nil; }
- (NSRect)downButton { return NSMakeRect(0, 0, kBar, kBar); }
- (NSRect)upButton { return NSMakeRect(0, kBar, kBar, kBar); }
- (NSRect)track { return NSMakeRect(0, 2 * kBar, kBar, MAX(0, self.bounds.size.height - 2 * kBar)); }
- (BOOL)scrollable {
    NSScrollView *sv = self.scrollView;
    return self.knobProportion < 1 && sv && sv.documentView.frame.size.height > sv.contentView.bounds.size.height;
}
- (NSRect)knob {
    NSRect track = self.track;
    CGFloat height = MIN(track.size.height, MAX(kBar, track.size.height * self.knobProportion));
    return NSMakeRect(0, NSMaxY(track) - height - (track.size.height - height) * self.doubleValue, kBar, height);
}

- (void)drawRect:(NSRect)dirtyRect {
    Fill(Dark(), self.track);
    if (self.scrollable) Bevel(NSInsetRect(self.knob, 1, 1));
    for (int i = 0; i < 2; i++) {
        BOOL up = i == 0;
        NSRect button = up ? self.upButton : self.downButton;
        Bevel(button);
        CGFloat x = NSMidX(button), y = NSMidY(button);
        NSBezierPath *t = [NSBezierPath bezierPath];
        [t moveToPoint:NSMakePoint(x - 4, up ? y - 3 : y + 3)];
        [t lineToPoint:NSMakePoint(x, up ? y + 3 : y - 3)];
        [t lineToPoint:NSMakePoint(x + 4, up ? y - 3 : y + 3)];
        [t closePath];
        [NSColor.blackColor setFill];
        [t fill];
    }
    Fill(NSColor.blackColor, NSMakeRect(kBar, 0, 1, self.bounds.size.height));
}

- (CGFloat)top {
    NSScrollView *sv = self.scrollView;
    NSView *document = sv.documentView;
    NSClipView *clip = sv.contentView;
    return document.isFlipped ? clip.bounds.origin.y : document.frame.size.height - NSMaxY(clip.bounds);
}

/// Scrolls the document so its top is at `top` points (clamped).
- (void)scrollToTop:(CGFloat)top {
    NSScrollView *sv = self.scrollView;
    NSView *document = sv.documentView;
    if (!document) return;
    NSClipView *clip = sv.contentView;
    CGFloat maxTop = MAX(0, document.frame.size.height - clip.bounds.size.height);
    CGFloat y = MIN(maxTop, MAX(0, top));
    [clip scrollToPoint:NSMakePoint(clip.bounds.origin.x, document.isFlipped ? y : maxTop - y)];
    [sv reflectScrolledClipView:clip];
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *window = self.window;
    NSScrollView *sv = self.scrollView;
    if (!window || !sv) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.upButton) || NSPointInRect(p, self.downButton)) {
        // Arrow buttons step a line and repeat while held
        CGFloat step = (NSPointInRect(p, self.upButton) ? -1 : 1) * MAX(sv.verticalLineScroll, 16);
        [self scrollToTop:self.top + step];
        while (![window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate dateWithTimeIntervalSinceNow:0.06]
                                       inMode:NSEventTrackingRunLoopMode dequeue:YES]) {
            [self scrollToTop:self.top + step];
        }
        return;
    }
    if (!self.scrollable) return;
    NSRect knob = self.knob, track = self.track;
    CGFloat maxTop = MAX(0, sv.documentView.frame.size.height - sv.contentView.bounds.size.height);
    CGFloat grab = NSPointInRect(p, knob) ? NSMaxY(knob) - p.y : knob.size.height / 2;
    CGFloat (^target)(CGFloat) = ^CGFloat(CGFloat y) {
        return (NSMaxY(track) - (y + grab)) / MAX(track.size.height - knob.size.height, 1) * maxTop;
    };
    [self scrollToTop:target(p.y)];
    while (YES) {
        NSEvent *next = [window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (next.type != NSEventTypeLeftMouseDragged) break;
        [self scrollToTop:target([self convertPoint:next.locationInWindow fromView:nil].y)];
    }
}
@end

// MARK: Scroll views: the scroller moves to the left

static NSString *const kSubclassPrefix = @"NXSkin_";

/// -tile for the per-class subclass: AppKit lays out as usual, then the vertical scroller swaps to the left.
static void NXTile(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    while (cls && ![NSStringFromClass(cls) hasPrefix:kSubclassPrefix]) cls = class_getSuperclass(cls); // past KVO subclasses
    struct objc_super sup = {self, class_getSuperclass(cls)};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
    NSScrollView *sv = self;
    NSScroller *scroller = sv.verticalScroller;
    if (![scroller isKindOfClass:NXScroller.class] || scroller.isHidden) return;
    NSRect bar = scroller.frame, content = sv.contentView.frame;
    CGFloat left = MIN(bar.origin.x, content.origin.x);
    bar.origin.x = left;
    content.origin.x = left + bar.size.width;
    scroller.frame = bar;
    sv.contentView.frame = content;
}

static void SkinScrollView(NSScrollView *sv) {
    if (!sv.hasVerticalScroller || [sv.verticalScroller isKindOfClass:NXScroller.class]) return;
    Class original = object_getClass(sv);
    if ([NSStringFromClass(original) hasPrefix:@"NSKVONotifying_"]) return; // leave KVO-observed views alone
    NSString *name = [kSubclassPrefix stringByAppendingString:NSStringFromClass(original)];
    Class subclass = NSClassFromString(name);
    if (!subclass) {
        subclass = objc_allocateClassPair(original, name.UTF8String, 0);
        if (!subclass) return;
        class_addMethod(subclass, @selector(tile), (IMP)NXTile, "v@:");
        objc_registerClassPair(subclass);
    }
    object_setClass(sv, subclass);
    sv.scrollerStyle = NSScrollerStyleLegacy;
    sv.autohidesScrollers = NO;
    sv.verticalScroller = [[NXScroller alloc] initWithFrame:NSMakeRect(0, 0, kBar + 1, 100)];
    [sv tile];
    [sv setNeedsDisplay:YES];
}

static void SkinScrollViews(NSView *view) {
    if ([view isKindOfClass:NSScrollView.class]) SkinScrollView((NSScrollView *)view);
    for (NSView *sub in view.subviews) SkinScrollViews(sub);
}

// MARK: Windows

static void SkinWindow(NSWindow *window) {
    if (!(window.styleMask & NSWindowStyleMaskTitled) || [window isKindOfClass:NSPanel.class] || window.sheetParent) return;
    NSView *close = [window standardWindowButton:NSWindowCloseButton];
    NSView *titlebar = close.superview;
    if (!objc_getAssociatedObject(window, kSkinnedKey) && titlebar) {
        objc_setAssociatedObject(window, kSkinnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        NXTitleBar *bar = [[NXTitleBar alloc] initWithFrame:titlebar.bounds];
        bar.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [titlebar addSubview:bar positioned:NSWindowAbove relativeTo:nil];
        NSView *frameView = window.contentView.superview;
        NXResizeBar *resize = [[NXResizeBar alloc] initWithFrame:NSMakeRect(0, 0, frameView.bounds.size.width, kResizeHeight)];
        resize.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        [frameView addSubview:resize positioned:NSWindowAbove relativeTo:nil];
        NSLog(@"[NeXTSkin] skinned window %@ (title bar %.0f pt)", window.title, titlebar.bounds.size.height);
    }
    // Every pass: AppKit can re-show the buttons, and new scroll views appear (new documents, the ruler)
    for (NSWindowButton b = NSWindowCloseButton; b <= NSWindowZoomButton; b++) [window standardWindowButton:b].hidden = YES;
    SkinScrollViews(window.contentView);
}

static void SkinAll(void) {
    for (NSWindow *window in NSApp.windows) SkinWindow(window);
}

static void Install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[NeXTSkin] loaded into %@", NSProcessInfo.processInfo.processName);
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                              NSWindowDidBecomeMainNotification, NSWindowDidUpdateNotification]) {
                [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                    NSWindow *window = note.object;
                    SkinWindow(window);
                    if (![name isEqualToString:NSWindowDidUpdateNotification]) {
                        for (NSView *v in [window standardWindowButton:NSWindowCloseButton].superview.subviews)
                            if ([v isKindOfClass:NXTitleBar.class]) v.needsDisplay = YES; // key / not key colours
                    }
                }];
            }
            SkinAll();
        });
    });
}

__attribute__((constructor)) static void NXSkinInit(void) { Install(); }

/// Ammonia's entry point (called after loading); the constructor has already done the work.
__attribute__((visibility("default"))) void LoadFunction(void *interceptor) { Install(); }
