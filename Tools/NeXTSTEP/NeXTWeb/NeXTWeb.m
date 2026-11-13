/* NeXTWeb: a web browser for NeXTSTEP 3.3 that shows today's web. A 68040 can't run a modern web engine, so
 * NeXTWeb is the window, the buttons, the mouse and the keyboard, and the pages themselves are loaded and drawn
 * by WebKit on the Mac that runs the Previous emulator (NeXTWebServer, server.swift, which also describes what
 * the two say to each other). The pages arrive as pictures in the NeXT's 12-bit colour, only the parts that
 * changed.
 *
 * The window: Back, Forward and Reload (Stop while a page loads), the address field (an address, or words to
 * search the web for), the page with NeXT's scroller on its left, and a status line. Menus: Info, Edit, Go,
 * Windows, Hide, Quit. Arrow keys and the scroller scroll; Copy, Cut and Paste work between the page and the
 * NeXT's pasteboard.
 *
 * Built in NeXTSTEP with cc from the Developer CD (build.sh). No nib: the window and menus are made here.
 * Defaults (owner NeXTWeb): Home, the page to start with; Server, the Mac's address (10.0.2.2 in Previous).
 */
#import <appkit/appkit.h>
#import <libc.h>
#import <stdarg.h>
#import <signal.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#define PORT 3129
#define TOOLBAR 38      /* height of the row of buttons */
#define STATUS 20       /* height of the status line */

static id controller, window, page, address, status, scroller, backButton, forwardButton, reloadButton;
static int server = -1;             /* the socket to NeXTWebServer */
static unsigned char *input;        /* what has arrived and isn't a whole message yet */
static int inputLength, inputSize;
static unsigned short *pixels;      /* the page as NeXTWebServer drew it, top row first, RGBA 4444 */
static int pixelsWide, pixelsHigh;
static BOOL loading;
static char *alert;                 /* a page's alert, waiting to be shown */

static void received(int fd, void *data);

static void disconnect(void)
{
    if (server < 0) return;
    DPSRemoveFD(server);
    close(server);
    server = -1;
    [status setStringValue:"Lost the web engine on the Mac (NeXTWebServer). Reload connects again."];
}

static void sendLine(const char *line)
{
    if (server < 0) return;
    if (write(server, line, strlen(line)) < 0 || write(server, "\n", 1) < 0) disconnect();
}

static void say(const char *format, ...)
{
    char line[8192];
    va_list arguments;

    va_start(arguments, format);
    vsprintf(line, format, arguments);
    va_end(arguments);
    sendLine(line);
}

static void sendSize(void)
{
    NXRect bounds;

    [page getBounds:&bounds];
    say("size %d %d", (int)bounds.size.width, (int)bounds.size.height);
}

static void connectToServer(void)
{
    struct sockaddr_in to;

    bzero((char *)&to, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = htons(PORT);
    to.sin_addr.s_addr = inet_addr((char *)NXGetDefaultValue("NeXTWeb", "Server"));
    server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0 || connect(server, (struct sockaddr *)&to, sizeof to) < 0) {
        if (server >= 0) close(server);
        server = -1;
        [status setStringValue:"Can't reach the web engine on the Mac (NeXTWebServer). Reload tries again."];
        return;
    }
    inputLength = 0;
    /* at the priority of modal loops, so that the page keeps up while the scroller's knob is dragged */
    DPSAddFD(server, received, NULL, NX_MODALRESPTHRESHOLD);
    sendSize();
}

/* MARK: The page */

/* Draws part of the page's pixels. The page view's focus must be locked. */
static void drawPixels(int x, int y, int width, int height)
{
    NXRect bounds, rect;
    const unsigned char *data[5];

    [page getBounds:&bounds];
    NXSetRect(&rect, x, bounds.size.height - (y + height), width, height);
    data[0] = (const unsigned char *)(pixels + y * pixelsWide + x);
    data[1] = data[2] = data[3] = data[4] = NULL;
    NXDrawBitmap(&rect, width, height, 4, 4, 16, pixelsWide * 2, NO, YES, NX_RGBColorSpace, data);
}

/* RECT: x, y, width, height and the run-length packed pixels of that part of the page. */
static void receivedRect(const unsigned char *p, int length)
{
    const unsigned char *end = p + length;
    int x, y, width, height, left, row = 0, count;
    unsigned short *out, pixel;

    if (!pixels || length < 8) return;
    x = (p[0] << 8) | p[1];
    y = (p[2] << 8) | p[3];
    width = (p[4] << 8) | p[5];
    height = (p[6] << 8) | p[7];
    if (!width || !height || x + width > pixelsWide || y + height > pixelsHigh) return;
    p += 8;
    out = pixels + y * pixelsWide + x;
    left = width;
    while (p + 3 <= end && row < height) {
        count = *p++;
        if (count < 128) {
            for (count++; count > 0 && row < height && p + 2 <= end; count--) {
                *out++ = (p[0] << 8) | p[1];
                p += 2;
                if (--left == 0) { left = width; row++; out += pixelsWide - width; }
            }
        } else {
            pixel = (p[0] << 8) | p[1];
            p += 2;
            for (count -= 126; count > 0 && row < height; count--) {
                *out++ = pixel;
                if (--left == 0) { left = width; row++; out += pixelsWide - width; }
            }
        }
    }
    [page lockFocus];
    drawPixels(x, y, width, height);
    [page unlockFocus];
}

static void receivedMessage(const char *tag, const unsigned char *data, int length)
{
    char text[2048];
    int a = 0, b = 0, c = 0;
    id pasteboard;

    if (!strncmp(tag, "RECT", 4)) { receivedRect(data, length); return; }
    if (!strncmp(tag, "DONE", 4)) {
        /* the frame is on the screen: ready for the next one */
        [window flushWindow];
        NXPing();
        say("ack");
        return;
    }
    if (!strncmp(tag, "COPY", 4)) {
        pasteboard = [Pasteboard new];
        [pasteboard declareTypes:&NXAsciiPboardType num:1 owner:nil];
        [pasteboard writeType:NXAsciiPboardType data:(const char *)data length:length];
        return;
    }
    if (length > sizeof text - 1) length = sizeof text - 1;
    bcopy((char *)data, text, length);
    text[length] = 0;
    sscanf(text, "%d %d %d", &a, &b, &c);
    if (!strncmp(tag, "SIZE", 4)) {
        if (a < 1 || b < 1 || a > 4096 || b > 4096) return;
        if (pixels) free(pixels);
        pixelsWide = a;
        pixelsHigh = b;
        /* one row more than the page: NXDrawBitmap is given whole rows, also for a rect that ends in the last one */
        pixels = (unsigned short *)calloc(a * (b + 1), sizeof(unsigned short));
    } else if (!strncmp(tag, "TITL", 4)) {
        [window setTitle:text];
    } else if (!strncmp(tag, "ADDR", 4)) {
        if (![address currentEditor]) [address setStringValue:text];
    } else if (!strncmp(tag, "STAT", 4)) {
        [status setStringValue:text];
    } else if (!strncmp(tag, "NAVI", 4)) {
        [backButton setEnabled:a != 0];
        [forwardButton setEnabled:b != 0];
        if (loading != (c != 0)) {
            loading = c != 0;
            [reloadButton setTitle:loading ? "Stop" : "Reload"];
        }
    } else if (!strncmp(tag, "SCRL", 4)) {
        /* top, height of the page, height of the view */
        if (b > c && c > 0) {
            [scroller setFloatValue:(float)a / (b - c) :(float)c / b];
            [scroller setEnabled:YES];
        } else {
            [scroller setEnabled:NO];
        }
    } else if (!strncmp(tag, "ALRT", 4)) {
        if (!alert) alert = NXCopyStringBuffer(text);
    }
}

/* Something arrived from NeXTWebServer: takes what is there and handles the messages that are complete. */
static void received(int fd, void *data)
{
    static BOOL busy;
    int count, at = 0, length;
    unsigned char *message;

    if (busy) return;
    busy = YES;
    if (inputSize - inputLength < 16384) {
        inputSize = inputSize ? inputSize * 2 : 65536;
        input = (unsigned char *)realloc(input, inputSize);
    }
    count = read(fd, input + inputLength, inputSize - inputLength);
    if (count <= 0) {
        disconnect();
        busy = NO;
        return;
    }
    inputLength += count;
    while (inputLength - at >= 8) {
        message = input + at;
        length = (message[4] << 24) | (message[5] << 16) | (message[6] << 8) | message[7];
        if (length < 0 || inputLength - at < 8 + length) break;
        receivedMessage((const char *)message, message + 8, length);
        at += 8 + length;
    }
    if (at) {
        inputLength -= at;
        bcopy(input + at, input, inputLength);
    }
    busy = NO;
}

@interface PageView : View
{
    BOOL down;          /* the mouse button is down in the page */
    NXPoint mouse;      /* where the mouse was last, in the page */
}
- trackMouse;
@end

@implementation PageView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse { return YES; }

- drawSelf:(const NXRect *)rects :(int)rectCount
{
    int top, bottom, width;

    if (!pixels || pixelsWide < bounds.size.width || pixelsHigh < bounds.size.height) {
        PSsetgray(NX_LTGRAY);
        NXRectFill(&rects[0]);
    }
    if (!pixels) return self;
    top = bounds.size.height - (rects[0].origin.y + rects[0].size.height);
    bottom = bounds.size.height - rects[0].origin.y;
    if (top < 0) top = 0;
    if (bottom > pixelsHigh) bottom = pixelsHigh;
    width = pixelsWide < bounds.size.width ? pixelsWide : bounds.size.width;
    if (bottom > top) drawPixels(0, top, width, bottom - top);
    return self;
}

- superviewSizeChanged:(const NXSize *)oldSize
{
    [super superviewSizeChanged:oldSize];
    sendSize();
    return self;
}

- sendMouse:(int)what at:(const NXPoint *)location clicks:(int)clicks
{
    mouse = *location;
    [self convertPoint:&mouse fromView:nil];
    say("mouse %c %d %d %d", what, (int)mouse.x, (int)(bounds.size.height - mouse.y), clicks);
    return self;
}

- mouseDown:(NXEvent *)event
{
    down = YES;
    [self sendMouse:'m' at:&event->location clicks:0];
    return [self sendMouse:'d' at:&event->location clicks:event->data.mouse.click];
}

- mouseUp:(NXEvent *)event
{
    down = NO;
    return [self sendMouse:'u' at:&event->location clicks:event->data.mouse.click];
}

/* Called a few times a second: tells the page where the mouse is now, for what pages do under the mouse and
 * for dragging. */
- trackMouse
{
    NXPoint location, old = mouse;

    if (!down && ![window isKeyWindow]) return self;
    [window getMouseLocation:&location];
    [self convertPoint:&location fromView:nil];
    if (location.x == old.x && location.y == old.y) return self;
    mouse = location;
    if (down || NXPointInRect(&location, &bounds)) {
        say("mouse %c %d %d 0", down ? 'g' : 'm', (int)location.x, (int)(bounds.size.height - location.y));
    }
    return self;
}

/* Keys go to the page: characters as they are, the arrow keys as 1001 to 1004 (left, up, right, down),
 * NeXT's delete as backspace. */
- keyDown:(NXEvent *)event
{
    int code = event->data.key.charCode, flags = 0;

    if (event->flags & NX_COMMANDMASK) return [super keyDown:event];
    if (event->data.key.charSet == NX_SYMBOLSET) {
        if (code < 0xAC || code > 0xAF) return self;
        code = 1001 + code - 0xAC;
    } else if (code == 127) {
        code = 8;
    }
    if (event->flags & NX_SHIFTMASK) flags |= 1;
    if (event->flags & NX_CONTROLMASK) flags |= 2;
    say("key %d %d", code, flags);
    return self;
}

- copy:sender { say("copy"); return self; }
- cut:sender { say("cut"); return self; }
- selectAll:sender { say("selectall"); return self; }

- paste:sender
{
    id pasteboard = [Pasteboard new];
    char *text, *line;
    int length, i;

    if (![pasteboard readType:NXAsciiPboardType data:&text length:&length]) return self;
    line = (char *)malloc(2 * length + 8);
    strcpy(line, "text ");
    for (i = 0; i < length; i++) sprintf(line + 5 + 2 * i, "%02x", (unsigned char)text[i]);
    if (length > 0) sendLine(line);
    free(line);
    [pasteboard deallocatePasteboardData:text length:length];
    return self;
}

@end

/* The sunken frame around the scroller and the page. */
@interface BezelView : View
@end

@implementation BezelView
- drawSelf:(const NXRect *)rects :(int)rectCount
{
    NXDrawGrayBezel(&bounds, NULL);
    return self;
}
@end

/* MARK: The window and the menus */

@interface Controller : Object
@end

/* A few times a second: the mouse, and a page's alert if one is waiting (shown from here, not while its message
 * is being handled). */
static void poll(DPSTimedEntry entry, double now, void *data)
{
    static BOOL showing;
    char *text;

    [page trackMouse];
    if (alert && !showing) {
        showing = YES;
        text = alert;
        alert = NULL;
        NXRunAlertPanel("NeXTWeb", "%s", "OK", NULL, NULL, text);
        free(text);
        showing = NO;
    }
}

@implementation Controller

- appDidInit:sender
{
    /* a window made in code draws nothing by itself: without this the title bar, buttons and address field stay blank */
    [window display];
    connectToServer();
    say("open %.4000s", NXGetDefaultValue("NeXTWeb", "Home"));
    [window makeKeyAndOrderFront:self];
    [window makeFirstResponder:page];
    DPSAddTimedEntry(0.15, poll, NULL, NX_MODALRESPTHRESHOLD);
    return self;
}

- go:sender
{
    if (server < 0) connectToServer();
    say("open %.4000s", [address stringValue]);
    [window makeFirstResponder:page];
    return self;
}

- back:sender { say("back"); return self; }
- forward:sender { say("forward"); return self; }
- stop:sender { say("stop"); return self; }
- home:sender { say("open %.4000s", NXGetDefaultValue("NeXTWeb", "Home")); return self; }
- openLocation:sender { [address selectText:self]; return self; }

- reload:sender
{
    if (server < 0) return [self go:sender];
    say("reload");
    return self;
}

/* The Reload button, which is Stop while a page loads. */
- reloadOrStop:sender
{
    return loading ? [self stop:sender] : [self reload:sender];
}

- scroll:sender
{
    switch ([sender hitPart]) {
    case NX_DECLINE: say("scroll line -1"); break;
    case NX_INCLINE: say("scroll line 1"); break;
    case NX_DECPAGE: say("scroll page -1"); break;
    case NX_INCPAGE: say("scroll page 1"); break;
    case NX_KNOB: case NX_JUMP: say("scrollto %d", (int)([sender floatValue] * 1000)); break;
    }
    return self;
}

- info:sender
{
    NXRunAlertPanel("NeXTWeb", "A web browser for NEXTSTEP 3.3 that shows today's web. The pages are loaded and "
                    "drawn by WebKit on the Mac that runs Previous (NeXTWebServer), and shown here.", "OK", NULL, NULL);
    return self;
}

- windowWillClose:sender
{
    [NXApp terminate:self];
    return self;
}

@end

static id button(const char *title, SEL action, float x, float width, id content, float height)
{
    NXRect rect;
    id it;

    NXSetRect(&rect, x, height - TOOLBAR + 7, width, 24);
    it = [[Button alloc] initFrame:&rect title:title tag:0 target:controller action:action key:0 enabled:YES];
    [it setAutosizing:NX_MINYMARGINSIZABLE];
    [content addSubview:it];
    return it;
}

static void makeWindow(void)
{
    NXRect rect;
    NXSize smallest = {360, 240};
    id content, bezel;
    float width = 831, height = 622;    /* a page of 800 by 560 */

    NXSetRect(&rect, 60, 130, width, height);
    window = [[Window alloc] initContent:&rect style:NX_RESIZEBARSTYLE backing:NX_BUFFERED
                              buttonMask:NX_CLOSEBUTTONMASK | NX_MINIATURIZEBUTTONMASK defer:NO];
    [window setTitle:"NeXTWeb"];
    [window setMinSize:&smallest];
    [window setDelegate:controller];
    content = [window contentView];
    [content setAutoresizeSubviews:YES];

    backButton = button("Back", @selector(back:), 4, 56, content, height);
    forwardButton = button("Forward", @selector(forward:), 62, 68, content, height);
    reloadButton = button("Reload", @selector(reloadOrStop:), 132, 62, content, height);
    [backButton setEnabled:NO];
    [forwardButton setEnabled:NO];

    NXSetRect(&rect, 200, height - TOOLBAR + 8, width - 204, 22);
    address = [[TextField alloc] initFrame:&rect];
    [address setTarget:controller];
    [address setAction:@selector(go:)];
    [address setAutosizing:NX_WIDTHSIZABLE | NX_MINYMARGINSIZABLE];
    [content addSubview:address];

    NXSetRect(&rect, 6, 2, width - 12, STATUS - 4);
    status = [[TextField alloc] initFrame:&rect];
    [status setEditable:NO];
    [status setSelectable:NO];
    [status setBezeled:NO];
    [status setBackgroundGray:NX_LTGRAY];
    [status setAutosizing:NX_WIDTHSIZABLE];
    [content addSubview:status];

    NXSetRect(&rect, 4, STATUS, width - 8, height - STATUS - TOOLBAR);
    bezel = [[BezelView alloc] initFrame:&rect];
    [bezel setAutosizing:NX_WIDTHSIZABLE | NX_HEIGHTSIZABLE];
    [bezel setAutoresizeSubviews:YES];
    [content addSubview:bezel];

    NXSetRect(&rect, 2, 2, NX_SCROLLERWIDTH, height - STATUS - TOOLBAR - 4);
    scroller = [[Scroller alloc] initFrame:&rect];
    [scroller setTarget:controller];
    [scroller setAction:@selector(scroll:)];
    [scroller setAutosizing:NX_HEIGHTSIZABLE];
    [bezel addSubview:scroller];

    NXSetRect(&rect, 3 + NX_SCROLLERWIDTH, 2, width - 8 - 5 - NX_SCROLLERWIDTH, height - STATUS - TOOLBAR - 4);
    page = [[PageView alloc] initFrame:&rect];
    [page setAutosizing:NX_WIDTHSIZABLE | NX_HEIGHTSIZABLE];
    [bezel addSubview:page];
}

static id submenu(id menu, const char *title)
{
    id it = [[Menu alloc] initTitle:title];

    [menu setSubmenu:it forItem:[menu addItem:title action:@selector(submenuAction:) keyEquivalent:0]];
    return it;
}

static void item(id menu, const char *title, SEL action, int key)
{
    [[menu addItem:title action:action keyEquivalent:key] setTarget:controller];
}

static void makeMenus(void)
{
    id menu = [[Menu alloc] initTitle:"NeXTWeb"], info, edit, go, windows;

    info = submenu(menu, "Info");
    item(info, "Info Panel...", @selector(info:), 0);
    [info sizeToFit];

    edit = submenu(menu, "Edit");
    [edit addItem:"Cut" action:@selector(cut:) keyEquivalent:'x'];
    [edit addItem:"Copy" action:@selector(copy:) keyEquivalent:'c'];
    [edit addItem:"Paste" action:@selector(paste:) keyEquivalent:'v'];
    [edit addItem:"Select All" action:@selector(selectAll:) keyEquivalent:'a'];
    [edit sizeToFit];

    go = submenu(menu, "Go");
    item(go, "Back", @selector(back:), '[');
    item(go, "Forward", @selector(forward:), ']');
    item(go, "Reload", @selector(reload:), 'r');
    item(go, "Stop", @selector(stop:), '.');
    item(go, "Home", @selector(home:), 'H');
    item(go, "Open Location...", @selector(openLocation:), 'l');
    [go sizeToFit];

    windows = submenu(menu, "Windows");
    [windows addItem:"Arrange in Front" action:@selector(arrangeInFront:) keyEquivalent:0];
    [windows addItem:"Miniaturize Window" action:@selector(performMiniaturize:) keyEquivalent:'m'];
    [windows addItem:"Close Window" action:@selector(performClose:) keyEquivalent:'w'];
    [windows sizeToFit];
    [NXApp setWindowsMenu:windows];

    [menu addItem:"Hide" action:@selector(hide:) keyEquivalent:'h'];
    [menu addItem:"Quit" action:@selector(terminate:) keyEquivalent:'q'];
    [menu sizeToFit];
    [NXApp setMainMenu:menu];
}

static NXDefaultsVector defaults = {
    {"Home", "https://duckduckgo.com/"},
    {"Server", "10.0.2.2"},
    {NULL, NULL}
};

void main(int argc, char *argv[])
{
    NXApp = [Application new];
    NXRegisterDefaults("NeXTWeb", defaults);
    signal(SIGPIPE, SIG_IGN);
    controller = [[Controller alloc] init];
    makeWindow();
    makeMenus();
    [NXApp setDelegate:controller];
    [NXApp run];
    [NXApp free];
    exit(0);
}
