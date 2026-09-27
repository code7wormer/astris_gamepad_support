#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <dlfcn.h>
#import <IOKit/hidsystem/IOHIDLib.h>

#define ARES_MAGIC 0x41524553 // 'ARES'
#define ARES_PORT 49152

// Swift sends this state as a 16-byte value with two trailing alignment bytes.
// Read the original 14-byte wire payload and let recv discard those trailing
// bytes; this is the known-good layout used by the bridge.
struct __attribute__((packed)) AresPacket {
    uint32_t magic;      // 'ARES'
    uint16_t buttons;    // Bitmask for buttons (bits 0..12)
    int8_t   lx;         // -127 .. 127
    int8_t   ly;         // -127 .. 127
    int8_t   rx;         // -127 .. 127
    int8_t   ry;         // -127 .. 127
    uint8_t  hat;        // 0..7 (direction), 8 (centered)
    uint8_t  padding[3];
};

static GCController *g_aresController = nil;
static dispatch_source_t g_socketSource = nil;
static dispatch_source_t g_sdlTraceTimer = nil;
static void *g_sdlJoystick = NULL;
static int16_t (*g_sdlGetAxis)(void *, int) = NULL;
static uint8_t (*g_sdlGetButton)(void *, int) = NULL;
static uint8_t (*g_sdlGetHat)(void *, int) = NULL;
static int g_sdlAxisCount = 0;
static int g_sdlButtonCount = 0;
static int g_sdlHatCount = 0;
static int16_t g_lastAxes[16] = {0};
static uint8_t g_lastButtons[32] = {0};
static uint8_t g_lastHats[4] = {0};
static uint16_t g_lastTraceButtons = 0;
static uint8_t g_lastTraceHat = 8;

static void logAzaharSDLJoysticksIfRequested(void) {
    if (strcmp(getenv("ARES_DEBUG") ?: "", "1") != 0) return;

    typedef struct { uint8_t data[16]; } SDL_JoystickGUID;
    typedef int (*SDL_NumJoysticksFn)(void);
    typedef int (*SDL_InitSubSystemFn)(uint32_t);
    typedef void *(*SDL_JoystickOpenFn)(int);
    typedef SDL_JoystickGUID (*SDL_JoystickGetGUIDFn)(void *);
    typedef void (*SDL_JoystickGetGUIDStringFn)(SDL_JoystickGUID, char *, int);
    typedef const char *(*SDL_JoystickNameForIndexFn)(int);
    typedef int (*SDL_JoystickNumAxesFn)(void *);

    SDL_NumJoysticksFn numJoysticks = (SDL_NumJoysticksFn)dlsym(RTLD_DEFAULT, "SDL_NumJoysticks");
    SDL_InitSubSystemFn initJoystick = (SDL_InitSubSystemFn)dlsym(RTLD_DEFAULT, "SDL_InitSubSystem");
    SDL_JoystickOpenFn joystickOpen = (SDL_JoystickOpenFn)dlsym(RTLD_DEFAULT, "SDL_JoystickOpen");
    SDL_JoystickGetGUIDFn joystickGUID = (SDL_JoystickGetGUIDFn)dlsym(RTLD_DEFAULT, "SDL_JoystickGetGUID");
    SDL_JoystickGetGUIDStringFn guidString = (SDL_JoystickGetGUIDStringFn)dlsym(RTLD_DEFAULT, "SDL_JoystickGetGUIDString");
    SDL_JoystickNameForIndexFn joystickName = (SDL_JoystickNameForIndexFn)dlsym(RTLD_DEFAULT, "SDL_JoystickNameForIndex");
    SDL_JoystickNumAxesFn numAxes = (SDL_JoystickNumAxesFn)dlsym(RTLD_DEFAULT, "SDL_JoystickNumAxes");
    if (!numJoysticks || !joystickOpen || !joystickGUID || !guidString) {
        NSLog(@"[AresGCBridge] SDL joystick probe unavailable (Azahar has not loaded SDL input APIs)");
        return;
    }
    // SDL_INIT_JOYSTICK. Azahar may defer this subsystem until its controls
    // dialog opens; initialize it solely for the native-device probe.
    if (initJoystick) initJoystick(0x00000200);
    int count = numJoysticks();
    NSLog(@"[AresGCBridge] SDL native joystick count: %d", count);

    for (int index = 0; index < count; index++) {
        void *joystick = joystickOpen(index);
        if (!joystick) continue;
        char guid[33] = {0};
        guidString(joystickGUID(joystick), guid, sizeof(guid));
        NSLog(@"[AresGCBridge] SDL joystick %d: %s | GUID: %s", index,
              joystickName ? joystickName(index) : "Unknown", guid);
        if (index == 0 && numAxes) {
            g_sdlJoystick = joystick;
            g_sdlAxisCount = MIN(numAxes(joystick), 16);
            // Azahar's SDL build does not export NumButtons/NumHats, but its
            // getters are bounds-safe. Probe the common controller ranges.
            g_sdlButtonCount = 16;
            g_sdlHatCount = 1;
            g_sdlGetAxis = (int16_t (*)(void *, int))dlsym(RTLD_DEFAULT, "SDL_JoystickGetAxis");
            g_sdlGetButton = (uint8_t (*)(void *, int))dlsym(RTLD_DEFAULT, "SDL_JoystickGetButton");
            g_sdlGetHat = (uint8_t (*)(void *, int))dlsym(RTLD_DEFAULT, "SDL_JoystickGetHat");
            NSLog(@"[AresGCBridge] SDL virtual layout: %d axes, %d buttons, %d hats",
                  g_sdlAxisCount, g_sdlButtonCount, g_sdlHatCount);
        }
    }
}

static void requestInputMonitoringIfNeeded(void) {
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (access == kIOHIDAccessTypeGranted) {
        NSLog(@"[AresGCBridge] Input Monitoring: granted to host app");
        return;
    }
    NSLog(@"[AresGCBridge] Input Monitoring: requesting permission for host app");
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
}

static void traceAzaharSDLStateIfRequested(void) {
    if (!g_sdlJoystick || !g_sdlGetAxis || !g_sdlGetButton || !g_sdlGetHat) return;
    for (int i = 0; i < g_sdlAxisCount; i++) {
        int16_t value = g_sdlGetAxis(g_sdlJoystick, i);
        if (value != g_lastAxes[i]) {
            g_lastAxes[i] = value;
            NSLog(@"[AresGCBridge] SDL axis %d = %d", i, value);
        }
    }
    for (int i = 0; i < g_sdlButtonCount; i++) {
        uint8_t value = g_sdlGetButton(g_sdlJoystick, i);
        if (value != g_lastButtons[i]) {
            g_lastButtons[i] = value;
            NSLog(@"[AresGCBridge] SDL button %d = %d", i, value);
        }
    }
    for (int i = 0; i < g_sdlHatCount; i++) {
        uint8_t value = g_sdlGetHat(g_sdlJoystick, i);
        if (value != g_lastHats[i]) {
            g_lastHats[i] = value;
            NSLog(@"[AresGCBridge] SDL hat %d = %d", i, value);
        }
    }
}

// Swizzled +[GCController controllers]
static NSArray<GCController *> * (*orig_controllers)(id, SEL) = NULL;

static NSArray<GCController *> * swizzled_controllers(id self, SEL _cmd) {
    NSArray *orig = orig_controllers ? orig_controllers(self, _cmd) : @[];
    if (!g_aresController) {
        return orig;
    }
    NSMutableArray *res = orig ? [orig mutableCopy] : [NSMutableArray array];
    if (![res containsObject:g_aresController]) {
        [res addObject:g_aresController];
    }
    return res;
}

static inline float normalizeAxis(int8_t val) {
    float norm = (float)val / 127.0f;
    if (norm > 1.0f) norm = 1.0f;
    if (norm < -1.0f) norm = -1.0f;
    if (fabsf(norm) < 0.08f) norm = 0.0f; // deadzone
    return norm;
}

static void updateButton(GCControllerButtonInput *btn, BOOL pressed) {
    if (!btn) return;
    // Snapshot controllers are explicitly writable.  Use the public setter so
    // GameController dispatches the normal value/pressed-change handlers that
    // Astris registers on its controller profile.
    [btn setValue:pressed ? 1.0f : 0.0f];
}

static void updateThumbstick(GCControllerDirectionPad *stick, float x, float y) {
    if (!stick) return;
    [stick setValueForXAxis:x yAxis:y];
}

static void updateDpad(GCControllerDirectionPad *dpad, uint8_t hatValue) {
    if (!dpad) return;
    float dx = 0.0f, dy = 0.0f;
    switch (hatValue) {
        case 0: dy =  1.0f; break;             // Up
        case 1: dx =  1.0f; dy =  1.0f; break; // Up-Right
        case 2: dx =  1.0f; break;             // Right
        case 3: dx =  1.0f; dy = -1.0f; break; // Down-Right
        case 4: dy = -1.0f; break;             // Down
        case 5: dx = -1.0f; dy = -1.0f; break; // Down-Left
        case 6: dx = -1.0f; break;             // Left
        case 7: dx = -1.0f; dy =  1.0f; break; // Up-Left
        default: break;                        // 8: Centered
    }
    [dpad setValueForXAxis:dx yAxis:dy];
}

static void setupControllerIfNeeded(void) {
    if (g_aresController) return;

    Class gcClass = NSClassFromString(@"GCController");
    if (!gcClass) return;

    SEL withExtSel = NSSelectorFromString(@"controllerWithExtendedGamepad");
    if (![gcClass respondsToSelector:withExtSel]) return;

    id (*createExt)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    g_aresController = createExt(gcClass, withExtSel);
    if (!g_aresController) {
        NSLog(@"[AresGCBridge] Failed to create snapshot GCController");
        return;
    }

    @try {
        [g_aresController setValue:@"Cosmic Byte Ares" forKey:@"vendorName"];
    } @catch (id ex) {}

    GCExtendedGamepad *ext = g_aresController.extendedGamepad;
    NSLog(@"[AresGCBridge] GCController snapshot created: %@", g_aresController);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GCControllerDidConnectNotification
                                                            object:g_aresController];
        NSLog(@"[AresGCBridge] Posted GCControllerDidConnectNotification");
    });
}

static void processPacket(const struct AresPacket *pkt) {
    if (pkt->magic != ARES_MAGIC) return;

    if (strcmp(getenv("ARES_DEBUG") ?: "", "1") == 0 &&
        (pkt->buttons != g_lastTraceButtons || pkt->hat != g_lastTraceHat)) {
        g_lastTraceButtons = pkt->buttons;
        g_lastTraceHat = pkt->hat;
        NSLog(@"[AresGCBridge] Ares state: buttons=0x%04X hat=%u", pkt->buttons, pkt->hat);
    }

    if (!g_aresController) {
        setupControllerIfNeeded();
    }
    GCExtendedGamepad *ext = g_aresController.extendedGamepad;
    if (!ext) return;

    // Analog sticks
    float lx = normalizeAxis(pkt->lx);
    float ly = normalizeAxis(pkt->ly); // Note: translator handles inversion
    updateThumbstick(ext.leftThumbstick, lx, ly);

    float rx = normalizeAxis(pkt->rx);
    float ry = normalizeAxis(pkt->ry); // Note: translator handles inversion
    updateThumbstick(ext.rightThumbstick, rx, ry);

    // D-Pad
    updateDpad(ext.dpad, pkt->hat);

    // Buttons bitmask
    uint16_t b = pkt->buttons;
    updateButton(ext.buttonX, (b & (1 << 0)) != 0);
    updateButton(ext.buttonA, (b & (1 << 1)) != 0);
    updateButton(ext.buttonB, (b & (1 << 2)) != 0);
    updateButton(ext.buttonY, (b & (1 << 3)) != 0);
    updateButton(ext.leftShoulder, (b & (1 << 4)) != 0);
    updateButton(ext.rightShoulder, (b & (1 << 5)) != 0);
    updateButton(ext.leftTrigger, (b & (1 << 6)) != 0);
    updateButton(ext.rightTrigger, (b & (1 << 7)) != 0);
    updateButton(ext.buttonOptions, (b & (1 << 8)) != 0);  // Minus
    updateButton(ext.buttonMenu, (b & (1 << 9)) != 0);     // Plus
    updateButton(ext.leftThumbstickButton, (b & (1 << 10)) != 0);
    updateButton(ext.rightThumbstickButton, (b & (1 << 11)) != 0);
    updateButton(ext.buttonHome, (b & (1 << 12)) != 0);
}

static void startUDPServer(void) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        NSLog(@"[AresGCBridge] socket() failed: %s", strerror(errno));
        return;
    }

    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
    fcntl(sock, F_SETFL, O_NONBLOCK);

    struct sockaddr_in sin = {0};
    sin.sin_family = AF_INET;
    sin.sin_port = htons(ARES_PORT);
    sin.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (bind(sock, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        NSLog(@"[AresGCBridge] bind() failed on 127.0.0.1:%d: %s", ARES_PORT, strerror(errno));
        close(sock);
        return;
    }

    NSLog(@"[AresGCBridge] Listening for Ares packets on 127.0.0.1:%d", ARES_PORT);

    g_socketSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_socketSource, ^{
        struct AresPacket pkt;
        while (recv(sock, &pkt, sizeof(pkt), 0) == sizeof(pkt)) {
            processPacket(&pkt);
        }
    });
    dispatch_source_set_cancel_handler(g_socketSource, ^{
        close(sock);
    });
    dispatch_resume(g_socketSource);
}

__attribute__((constructor))
static void AresGCBridge_Init(void) {
    NSLog(@"[AresGCBridge] Initializing bridge in PID %d...", getpid());

    // Azahar's native SDL backend needs to bind the physical Ares, not the
    // synthetic snapshot.  This diagnostic mode loads only long enough to
    // report Azahar's own physical SDL GUID.
    if (strcmp(getenv("ARES_SDL_PROBE_ONLY") ?: "", "1") == 0) {
        requestInputMonitoringIfNeeded();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            logAzaharSDLJoysticksIfRequested();
        });
        return;
    }

    requestInputMonitoringIfNeeded();

    Class gcClass = NSClassFromString(@"GCController");
    if (!gcClass) {
        NSLog(@"[AresGCBridge] GCController class not found, skipping");
        return;
    }

    // Swizzle +[GCController controllers]
    Method origMethod = class_getClassMethod(gcClass, @selector(controllers));
    if (origMethod) {
        orig_controllers = (NSArray<GCController *> * (*)(id, SEL))method_getImplementation(origMethod);
        method_setImplementation(origMethod, (IMP)swizzled_controllers);
        NSLog(@"[AresGCBridge] Swizzled +[GCController controllers]");
    }

    // Pre-create controller and register
    setupControllerIfNeeded();

    // Start UDP server to receive packets from AresTranslator
    startUDPServer();
    // Azahar initializes its statically linked SDL after constructors have
    // run. Delay the optional probe so its joystick list is populated.
    if (strcmp(getenv("ARES_DEBUG") ?: "", "1") == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            logAzaharSDLJoysticksIfRequested();
            g_sdlTraceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
            dispatch_source_set_timer(g_sdlTraceTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                      100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(g_sdlTraceTimer, ^{ traceAzaharSDLStateIfRequested(); });
            dispatch_resume(g_sdlTraceTimer);
        });
    }
}
