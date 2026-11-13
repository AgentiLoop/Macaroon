// NeXTSkin: an Ammonia tweak that dresses Apple's own apps in MacCube's NeXT look (see ../SIP-OFF-PLAN.md).
// Test version, loaded only into the apps named in NeXTSkin.dylib.allowlist (TextEdit):
//  • title bar: the standard buttons and title are hidden and NeXT's black bar is drawn over the title bar,
//    miniaturize box on the left, close box on the right, bold white centred title; drag it to move the window
//  • resize bar: NeXT's bevelled bar along the bottom edge (end segments resize the width too)
//  • scrollers: NeXT scrollers (dark track, bevelled knob); vertical on the left with both arrows at the bottom,
//    horizontal with both arrows at its left end
//  • title row: NeXT.s 23 pt instead of 32
//  • corners: square (AppKit corner radius 0, no corner mask), like NeXT windows
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

/// Vertical: arrows at the bottom (down below up), black line on the right. Horizontal: arrows at the left end
/// (left then right, like the File Viewer's), black line along the top.
- (BOOL)horizontal { return self.bounds.size.width > self.bounds.size.height; }
- (NSScrollView *)scrollView { return [self.superview isKindOfClass:NSScrollView.class] ? (NSScrollView *)self.superview : nil; }
- (NSRect)backButton { return self.horizontal ? NSMakeRect(0, 0, kBar, kBar) : NSMakeRect(0, kBar, kBar, kBar); }      // up / left
- (NSRect)forwardButton { return self.horizontal ? NSMakeRect(kBar, 0, kBar, kBar) : NSMakeRect(0, 0, kBar, kBar); }  // down / right
- (NSRect)track {
    return self.horizontal ? NSMakeRect(2 * kBar, 0, MAX(0, self.bounds.size.width - 2 * kBar), kBar)
                           : NSMakeRect(0, 2 * kBar, kBar, MAX(0, self.bounds.size.height - 2 * kBar));
}
- (CGFloat)length { return self.horizontal ? self.track.size.width : self.track.size.height; }
/// Document size along this scroller's axis, and the visible part of it.
- (CGFloat)contentLength {
    NSScrollView *sv = self.scrollView;
    return self.horizontal ? sv.documentView.frame.size.width : sv.documentView.frame.size.height;
}
- (CGFloat)visibleLength {
    NSClipView *clip = self.scrollView.contentView;
    return self.horizontal ? clip.bounds.size.width : clip.bounds.size.height;
}
- (CGFloat)maxOffset { return MAX(0, self.contentLength - self.visibleLength); }
- (BOOL)scrollable { return self.scrollView && self.knobProportion < 1 && self.maxOffset > 0; }
- (NSRect)knob {
    NSRect track = self.track;
    CGFloat length = self.length, size = MIN(length, MAX(kBar, length * self.knobProportion));
    CGFloat travel = (length - size) * self.doubleValue;
    return self.horizontal ? NSMakeRect(track.origin.x + travel, 0, size, kBar)
                           : NSMakeRect(0, NSMaxY(track) - size - travel, kBar, size);
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL horizontal = self.horizontal;
    Fill(Dark(), self.track);
    if (self.scrollable) Bevel(NSInsetRect(self.knob, 1, 1));
    for (int i = 0; i < 2; i++) {
        BOOL back = i == 0;
        NSRect button = back ? self.backButton : self.forwardButton;
        Bevel(button);
        CGFloat x = NSMidX(button), y = NSMidY(button), d = back ? -1 : 1; // points left/up when back
        NSBezierPath *t = [NSBezierPath bezierPath];
        if (horizontal) {
            [t moveToPoint:NSMakePoint(x - 3 * d, y - 4)];
            [t lineToPoint:NSMakePoint(x + 3 * d, y)];
            [t lineToPoint:NSMakePoint(x - 3 * d, y + 4)];
        } else {
            [t moveToPoint:NSMakePoint(x - 4, y + 3 * d)];
            [t lineToPoint:NSMakePoint(x, y - 3 * d)];
            [t lineToPoint:NSMakePoint(x + 4, y + 3 * d)];
        }
        [t closePath];
        [NSColor.blackColor setFill];
        [t fill];
    }
    if (horizontal) Fill(NSColor.blackColor, NSMakeRect(0, kBar, self.bounds.size.width, 1));
    else Fill(NSColor.blackColor, NSMakeRect(kBar, 0, 1, self.bounds.size.height));
}

/// Offset from the top (vertical) or left (horizontal) of the document.
- (CGFloat)offset {
    NSScrollView *sv = self.scrollView;
    NSView *document = sv.documentView;
    NSClipView *clip = sv.contentView;
    if (self.horizontal) return clip.bounds.origin.x - document.frame.origin.x;
    return document.isFlipped ? clip.bounds.origin.y : document.frame.size.height - NSMaxY(clip.bounds);
}

- (void)scrollToOffset:(CGFloat)offset {
    NSScrollView *sv = self.scrollView;
    NSView *document = sv.documentView;
    if (!document) return;
    NSClipView *clip = sv.contentView;
    CGFloat maxOffset = self.maxOffset, o = MIN(maxOffset, MAX(0, offset));
    NSPoint origin = clip.bounds.origin;
    if (self.horizontal) origin.x = document.frame.origin.x + o;
    else origin.y = document.isFlipped ? o : maxOffset - o;
    [clip scrollToPoint:origin];
    [sv reflectScrolledClipView:clip];
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *window = self.window;
    NSScrollView *sv = self.scrollView;
    if (!window || !sv) return;
    BOOL horizontal = self.horizontal;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.backButton) || NSPointInRect(p, self.forwardButton)) {
        // Arrow buttons step a line and repeat while held
        CGFloat line = horizontal ? sv.horizontalLineScroll : sv.verticalLineScroll;
        CGFloat step = (NSPointInRect(p, self.backButton) ? -1 : 1) * MAX(line, 16);
        [self scrollToOffset:self.offset + step];
        while (![window nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate dateWithTimeIntervalSinceNow:0.06]
                                       inMode:NSEventTrackingRunLoopMode dequeue:YES]) {
            [self scrollToOffset:self.offset + step];
        }
        return;
    }
    if (!self.scrollable) return;
    NSRect knob = self.knob, track = self.track;
    CGFloat maxOffset = self.maxOffset, length = self.length;
    CGFloat knobSize = horizontal ? knob.size.width : knob.size.height;
    // Distance from the pointer to the knob's leading edge (top or left)
    CGFloat grab = NSPointInRect(p, knob) ? (horizontal ? p.x - knob.origin.x : NSMaxY(knob) - p.y) : knobSize / 2;
    CGFloat (^target)(NSPoint) = ^CGFloat(NSPoint q) {
        CGFloat along = horizontal ? q.x - grab - track.origin.x : NSMaxY(track) - (q.y + grab);
        return along / MAX(length - knobSize, 1) * maxOffset;
    };
    [self scrollToOffset:target(p)];
    while (YES) {
        NSEvent *next = [window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (next.type != NSEventTypeLeftMouseDragged) break;
        [self scrollToOffset:target([self convertPoint:next.locationInWindow fromView:nil])];
    }
}
@end

// MARK: Scroll views: the scroller moves to the left

/// The square where the left vertical scroller meets the horizontal one: NeXT grey, black edges toward the content.
@interface NXCorner : NSView
@end

@implementation NXCorner
- (void)drawRect:(NSRect)dirtyRect {
    Fill(Face(), self.bounds);
    Fill(NSColor.blackColor, NSMakeRect(kBar, 0, 1, self.bounds.size.height));
    Fill(NSColor.blackColor, NSMakeRect(0, self.isFlipped ? 0 : kBar, self.bounds.size.width, 1));
}
@end

static IMP originalTile;

/// -[NSScrollView tile], replaced once for every scroll view (subclasses like TextEdit's ScalingScrollView call
/// super, and KVO-observed views are covered too): AppKit lays out as usual, then the NeXT vertical scroller moves
/// to the left (the horizontal one, if any, starts after it) and both stop above the NeXT resize bar.
static void NXTile(NSScrollView *sv, SEL _cmd) {
    ((void (*)(id, SEL))originalTile)(sv, _cmd);
    NSScroller *scroller = sv.verticalScroller, *hscroller = sv.horizontalScroller;
    BOOL vertical = [scroller isKindOfClass:NXScroller.class] && !scroller.isHidden && sv.hasVerticalScroller;
    BOOL horizontal = [hscroller isKindOfClass:NXScroller.class] && !hscroller.isHidden && sv.hasHorizontalScroller;
    if (!vertical && !horizontal) return;
    NSRect bar = scroller.frame, hbar = hscroller.frame, content = sv.contentView.frame;
    if (vertical) {
        CGFloat left = MIN(bar.origin.x, content.origin.x);
        bar.origin.x = left;
        content.origin.x = left + bar.size.width;
        if (horizontal) hbar.origin.x = content.origin.x;
    }
    // Stop above the NeXT resize bar laid over the window's bottom edge (it hid half the down arrow)
    if (objc_getAssociatedObject(sv.window, kSkinnedKey)) {
        CGFloat bottom = NSMinY([sv convertRect:sv.bounds toView:nil]), overlap = kResizeHeight - bottom;
        if (overlap > 0) {
            CGFloat up = sv.isFlipped ? -overlap : overlap;
            if (horizontal) {
                hbar.origin.y += up;
                if (!sv.isFlipped) { bar.origin.y += overlap; content.origin.y += overlap; }
            } else if (!sv.isFlipped) {
                bar.origin.y += overlap; content.origin.y += overlap;
            }
            bar.size.height = MAX(0, bar.size.height - overlap);
            content.size.height = MAX(0, content.size.height - overlap);
        }
    }
    if (vertical) scroller.frame = bar;
    if (horizontal) hscroller.frame = hbar;
    sv.contentView.frame = content;
    // Where the two scrollers meet: AppKit's corner box stays at the right (it showed as a white patch), and the
    // bottom-left corner under the vertical scroller was left empty. Hide the one, fill the other NeXT grey.
    static const void *kCornerKey = &kCornerKey;
    NSView *corner = objc_getAssociatedObject(sv, kCornerKey);
    if (vertical && horizontal) {
        for (NSView *v in sv.subviews) {
            if (v == scroller || v == hscroller || v == corner || v == sv.contentView || [v isKindOfClass:NSRulerView.class]) continue;
            if (v.frame.size.width <= kBar + 2 && v.frame.size.height <= kBar + 2) v.hidden = YES;
        }
        if (!corner) {
            corner = [[NXCorner alloc] initWithFrame:NSZeroRect];
            objc_setAssociatedObject(sv, kCornerKey, corner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (corner.superview != sv) [sv addSubview:corner positioned:NSWindowAbove relativeTo:nil];
        corner.frame = NSMakeRect(bar.origin.x, hbar.origin.y, bar.size.width, hbar.size.height);
        corner.hidden = NO;
    } else {
        corner.hidden = YES;
    }
}

static void SkinScrollView(NSScrollView *sv) {
    BOOL v = sv.hasVerticalScroller && ![sv.verticalScroller isKindOfClass:NXScroller.class];
    BOOL h = sv.hasHorizontalScroller && ![sv.horizontalScroller isKindOfClass:NXScroller.class];
    if (!v && !h) return;
    if (!originalTile) {
        Method m = class_getInstanceMethod(NSScrollView.class, @selector(tile));
        originalTile = method_setImplementation(m, (IMP)NXTile);
    }
    sv.scrollerStyle = NSScrollerStyleLegacy;
    sv.autohidesScrollers = NO;
    if (v) sv.verticalScroller = [[NXScroller alloc] initWithFrame:NSMakeRect(0, 0, kBar + 1, 100)];
    if (h) sv.horizontalScroller = [[NXScroller alloc] initWithFrame:NSMakeRect(0, 0, 100, kBar + 1)];
    [sv tile];
    [sv setNeedsDisplay:YES];
}

static void SkinScrollViews(NSView *view) {
    if ([view isKindOfClass:NSScrollView.class]) SkinScrollView((NSScrollView *)view);
    for (NSView *sub in view.subviews) SkinScrollViews(sub);
}

// MARK: Windows

static void RefreshCorners(NSWindow *window);
static void NeXTTitleHeight(void);

static void SkinWindow(NSWindow *window) {
    if (!(window.styleMask & NSWindowStyleMaskTitled) || [window isKindOfClass:NSPanel.class] || window.sheetParent) return;
    NSView *close = [window standardWindowButton:NSWindowCloseButton];
    NSView *titlebar = close.superview;
    if (!objc_getAssociatedObject(window, kSkinnedKey) && titlebar) {
        objc_setAssociatedObject(window, kSkinnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        // NeXT is light (white page). On the content only: changing the window's appearance swaps in a different
        // frame view that drops the title bar container and TextEdit's formatting bar.
        window.contentView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        NSView *frameView = window.contentView.superview;
        NXResizeBar *resize = [[NXResizeBar alloc] initWithFrame:NSMakeRect(0, 0, frameView.bounds.size.width, kResizeHeight)];
        resize.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        [frameView addSubview:resize positioned:NSWindowAbove relativeTo:nil];
        RefreshCorners(window);
        SEL relayout = NSSelectorFromString(@"_titleBarViewHeightChanged"); // picks up the 23 pt title row
        if ([frameView respondsToSelector:relayout]) ((void (*)(id, SEL))objc_msgSend)(frameView, relayout);
        NSLog(@"[NeXTSkin] skinned window %@ (title bar %.0f pt)", window.title, titlebar.bounds.size.height);
    }
    // Every pass: AppKit rebuilds the title bar view (appearance changes, accessories), re-shows the buttons,
    // and new scroll views appear (new documents, the ruler)
    titlebar = [window standardWindowButton:NSWindowCloseButton].superview;
    NXTitleBar *bar = nil;
    for (NSView *v in titlebar.subviews) if ([v isKindOfClass:NXTitleBar.class]) bar = (NXTitleBar *)v;
    if (titlebar) {
        // Only the title row: titlebar accessories below it (TextEdit's formatting bar) stay visible. Refitted
        // every pass, since the title bar view can be mid-rebuild (window-sized) when first seen.
        CGFloat accessories = 0;
        for (NSTitlebarAccessoryViewController *a in window.titlebarAccessoryViewControllers)
            if (!a.isHidden && a.layoutAttribute == NSLayoutAttributeBottom) accessories += a.view.frame.size.height;
        NSRect row = titlebar.bounds;
        row.origin.y = accessories;
        row.size.height = MAX(kTitleHeight, row.size.height - accessories);
        if (!bar) {
            bar = [[NXTitleBar alloc] initWithFrame:row];
            bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
            [titlebar addSubview:bar positioned:NSWindowAbove relativeTo:nil];
        } else if (!NSEqualRects(bar.frame, row)) {
            bar.frame = row;
        }
    }
    for (NSWindowButton b = NSWindowCloseButton; b <= NSWindowZoomButton; b++) [window standardWindowButton:b].hidden = YES;
    SkinScrollViews(window.contentView);
}

static void SkinAll(void) {
    for (NSWindow *window in NSApp.windows) SkinWindow(window);
}

// MARK: Square corners

/// Replaces an instance method (if the class has it) with a block; private AppKit, so missing methods are skipped.
static void Replace(NSString *className, NSString *selector, id block) {
    Class cls = NSClassFromString(className);
    Method m = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selector)) : NULL;
    if (!m) { NSLog(@"[NeXTSkin] no -[%@ %@]", className, selector); return; }
    class_replaceMethod(cls, NSSelectorFromString(selector), imp_implementationWithBlock(block), method_getTypeEncoding(m));
}

/// NeXT windows are square: AppKit's window corner radius becomes 0 and the corner mask goes away, so the
/// window server neither rounds nor clips the corners (and the shadow follows the square shape).
static void SquareCorners(void) {
    for (NSString *cls in @[@"NSThemeFrame", @"NSWindow"]) {
        Replace(cls, @"_cornerRadius", ^CGFloat(id self) { return 0; });
        Replace(cls, @"_cornerMask", ^id(id self) { return nil; });
        Replace(cls, @"_shouldRoundCornersForSurface", ^BOOL(id self) { return NO; });
    }
    Replace(@"NSThemeFrame", @"_getCachedDefaultWindowCornerRadius", ^CGFloat(id self) { return 0; });
    Replace(@"NSThemeFrame", @"topCornerRounded", ^BOOL(id self) { return NO; });
    Replace(@"NSThemeFrame", @"bottomCornerRounded", ^BOOL(id self) { return NO; });
    Replace(@"NSWindow", @"_topCornerRadius", ^CGFloat(id self) { return 0; });
    Replace(@"NSWindow", @"_bottomCornerRadius", ^CGFloat(id self) { return 0; });
}

/// NeXT's title row is 23 pt; macOS 26+ makes it 32. Skinned windows get NeXT's height (accessories such as
/// TextEdit's formatting bar are laid out below it, as before).
static void NeXTTitleHeight(void) {
    Method m = class_getInstanceMethod(NSClassFromString(@"NSThemeFrame"), NSSelectorFromString(@"_titlebarHeight"));
    if (!m) { NSLog(@"[NeXTSkin] no -[NSThemeFrame _titlebarHeight]"); return; }
    CGFloat (*original)(id, SEL) = (CGFloat (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^CGFloat(NSView *frame) {
        CGFloat height = original(frame, NSSelectorFromString(@"_titlebarHeight"));
        return objc_getAssociatedObject(frame.window, kSkinnedKey) && height > kTitleHeight ? kTitleHeight : height;
    }));
}

/// Windows already on screen keep their cached rounded mask until told it changed.
static void RefreshCorners(NSWindow *window) {
    SEL changed = NSSelectorFromString(@"_cornerMaskChanged");
    if ([window respondsToSelector:changed]) ((void (*)(id, SEL))objc_msgSend)(window, changed);
    [window invalidateShadow];
}

static void Install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SquareCorners();
        NeXTTitleHeight();
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
