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
#import <pthread.h>
#import <IOKit/hid/IOHIDLib.h>

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

// ---------------------------------------------------------------------------
// Block raw physical Ares from IOHIDDeviceOpen (prevents 100% CPU winebus flood)
// ---------------------------------------------------------------------------
static IOReturn my_IOHIDDeviceOpen(IOHIDDeviceRef device, IOOptionBits options) {
    if (device) {
        CFNumberRef vidNum = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
        CFNumberRef pidNum = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
        int vid = 0, pid = 0;
        if (vidNum) CFNumberGetValue(vidNum, kCFNumberIntType, &vid);
        if (pidNum) CFNumberGetValue(pidNum, kCFNumberIntType, &pid);
        if (vid == 0x2563 && pid == 0x057A) {
            NSLog(@"[AresCrossOverBridge] Blocked raw IOHIDDeviceOpen for Ares (0x2563:0x057A)");
            return kIOReturnNotOpen;
        }
    }
    return IOHIDDeviceOpen(device, options);
}
DYLD_INTERPOSE(my_IOHIDDeviceOpen, IOHIDDeviceOpen);

static void my_IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report, CFIndex reportLength, IOHIDReportCallback callback, void *context) {
    if (device) {
        CFNumberRef vidNum = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
        CFNumberRef pidNum = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
        int vid = 0, pid = 0;
        if (vidNum) CFNumberGetValue(vidNum, kCFNumberIntType, &vid);
        if (pidNum) CFNumberGetValue(pidNum, kCFNumberIntType, &pid);
        if (vid == 0x2563 && pid == 0x057A) {
            NSLog(@"[AresCrossOverBridge] Blocked IOHIDRegisterInputReportCallback for Ares");
            return;
        }
    }
    IOHIDDeviceRegisterInputReportCallback(device, report, reportLength, callback, context);
}
DYLD_INTERPOSE(my_IOHIDDeviceRegisterInputReportCallback, IOHIDDeviceRegisterInputReportCallback);

// ---------------------------------------------------------------------------
// AresPacket protocol
// ---------------------------------------------------------------------------
#define ARES_MAGIC 0x41524553 // 'ARES'
#define ARES_PORT 49152

struct __attribute__((packed)) AresPacket {
    uint32_t magic;
    uint16_t buttons;
    int8_t   lx, ly, rx, ry;
    uint8_t  hat;
    uint8_t  padding[3];
};

// ---------------------------------------------------------------------------
// SDL types for direct event injection
// ---------------------------------------------------------------------------
typedef union {
    uint32_t type;
    struct {
        uint32_t type;       // SDL_JOYDEVICEADDED = 0x605
        uint32_t timestamp;
        int32_t  which;
    } jdevice;
    uint8_t padding[56];
} AresSDLEvent;

#define SDL_JOYDEVICEADDED 0x605

typedef int  (*SDL_PushEvent_fn)(AresSDLEvent *);
typedef int  (*SDL_NumJoysticks_fn)(void);
typedef int  (*SDL_SetHint_fn)(const char *, const char *);

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------
static GCController      *g_aresController       = nil;
static dispatch_source_t  g_socketSource         = nil;
static pid_t              g_spawnedTranslatorPid = -1;

static GCControllerButtonInput   *s_btnX = nil, *s_btnA = nil, *s_btnB = nil, *s_btnY = nil;
static GCControllerButtonInput   *s_btnL1 = nil, *s_btnR1 = nil;
static GCControllerButtonInput   *s_btnL2 = nil, *s_btnR2 = nil;
static GCControllerButtonInput   *s_btnMinus = nil, *s_btnPlus = nil;
static GCControllerButtonInput   *s_btnL3 = nil, *s_btnR3 = nil, *s_btnHome = nil;
static GCControllerDirectionPad  *s_leftStick = nil, *s_rightStick = nil, *s_dpad = nil;

static uint16_t s_prevButtons = 0xFFFF;
static int8_t   s_prevLX = -128, s_prevLY = -128, s_prevRX = -128, s_prevRY = -128;
static uint8_t  s_prevHat = 0xFF;

// ---------------------------------------------------------------------------
// Lifecycle: auto-start AresTranslator with the game, auto-stop on game exit
// ---------------------------------------------------------------------------
static void ensureTranslatorRunning(void) {
    if (system("pgrep -x AresTranslator > /dev/null 2>&1") == 0) {
        return; // Already running
    }

    const char *path = "/Users/shardul/Projects/AresCrossOver/AresTranslator";
    if (access(path, X_OK) != 0) {
        NSLog(@"[AresCrossOverBridge] Translator binary not found at %s", path);
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        int nullFd = open("/dev/null", O_RDWR);
        if (nullFd >= 0) {
            dup2(nullFd, STDIN_FILENO);
            dup2(nullFd, STDOUT_FILENO);
            dup2(nullFd, STDERR_FILENO);
            close(nullFd);
        }
        execl(path, "AresTranslator", NULL);
        _exit(1);
    } else if (pid > 0) {
        g_spawnedTranslatorPid = pid;
        NSLog(@"[AresCrossOverBridge] Auto-spawned AresTranslator (PID %d)", pid);
    }
}

static void stopTranslatorIfSpawned(void) {
    if (g_spawnedTranslatorPid > 0) {
        NSLog(@"[AresCrossOverBridge] Stopping auto-spawned AresTranslator (PID %d)", g_spawnedTranslatorPid);
        kill(g_spawnedTranslatorPid, SIGTERM);
        g_spawnedTranslatorPid = -1;
    }
}

// ---------------------------------------------------------------------------
// GCController swizzle
// ---------------------------------------------------------------------------
static NSArray<GCController *> * (*orig_controllers)(id, SEL) = NULL;

static NSArray<GCController *> * swizzled_controllers(id self, SEL _cmd) {
    NSArray *orig = orig_controllers ? orig_controllers(self, _cmd) : @[];
    if (!g_aresController) return orig;
    NSMutableArray *res = orig ? [orig mutableCopy] : [NSMutableArray array];
    if (![res containsObject:g_aresController]) [res addObject:g_aresController];
    return res;
}

// Forward declarations
static void setupControllerIfNeeded(void);
static BOOL tryInjectSDLEvent(void);

// ---------------------------------------------------------------------------
// Try to inject SDL_JOYDEVICEADDED into the SDL event queue
// Returns YES if SDL is initialized and event was pushed
// ---------------------------------------------------------------------------
static BOOL tryInjectSDLEvent(void) {
    SDL_NumJoysticks_fn numJ = (SDL_NumJoysticks_fn)dlsym(RTLD_DEFAULT, "SDL_NumJoysticks");
    if (!numJ) return NO;

    SDL_PushEvent_fn pushFn = (SDL_PushEvent_fn)dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    if (!pushFn) return NO;

    SDL_SetHint_fn setHint = (SDL_SetHint_fn)dlsym(RTLD_DEFAULT, "SDL_SetHint");
    if (setHint) {
        setHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
        setHint("SDL_GAMECONTROLLER_USE_BUTTON_LABELS", "0");
    }

    if (!g_aresController) {
        setupControllerIfNeeded();
    }

    if (g_aresController) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:GCControllerDidConnectNotification
                          object:g_aresController];
    }

    AresSDLEvent e;
    memset(&e, 0, sizeof(e));
    e.jdevice.type  = SDL_JOYDEVICEADDED;
    e.jdevice.which = 0;
    int result = pushFn(&e);
    NSLog(@"[AresCrossOverBridge] Injected SDL_JOYDEVICEADDED (result=%d, joysticks=%d)", result, numJ());

    return YES;
}

// ---------------------------------------------------------------------------
// POSIX thread: fast initial detection (50ms) + permanent keep-alive loop
// ---------------------------------------------------------------------------
static void* sdlRetryThreadFunc(void *arg) {
    (void)arg;

    // Phase 1: Fast retry every 50ms (up to 100 attempts = 5s)
    BOOL connected = NO;
    for (int attempt = 1; attempt <= 100; attempt++) {
        @autoreleasepool {
            if (tryInjectSDLEvent()) {
                NSLog(@"[AresCrossOverBridge] Fast detection succeeded on attempt #%d (%d ms)", attempt, attempt * 50);
                connected = YES;
                break;
            }
        }
        usleep(50000); // 50ms
    }

    if (!connected) {
        NSLog(@"[AresCrossOverBridge] Fast detection timed out, will keep trying in keepalive loop");
    }

    // Phase 2: Permanent keep-alive loop — runs every 3 seconds
    while (1) {
        sleep(3);
        @autoreleasepool {
            SDL_NumJoysticks_fn numJ = (SDL_NumJoysticks_fn)dlsym(RTLD_DEFAULT, "SDL_NumJoysticks");
            if (numJ) {
                int count = numJ();
                if (count == 0) {
                    NSLog(@"[AresCrossOverBridge] Keepalive: 0 joysticks detected, re-injecting...");
                    tryInjectSDLEvent();
                }
            }
        }
    }
    return NULL;
}

static void startSDLRetryThread(void) {
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&thread, &attr, sdlRetryThreadFunc, NULL);
    pthread_attr_destroy(&attr);
    if (rc == 0) {
        NSLog(@"[AresCrossOverBridge] SDL retry thread started");
    } else {
        NSLog(@"[AresCrossOverBridge] Failed to start SDL retry thread: %s", strerror(rc));
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static inline float normalizeAxis(int8_t val) {
    float norm = (float)val / 127.0f;
    if (norm > 1.0f) norm = 1.0f;
    if (norm < -1.0f) norm = -1.0f;
    if (fabsf(norm) < 0.08f) norm = 0.0f;
    return norm;
}

static void updateDpad(GCControllerDirectionPad *dpad, uint8_t hatValue) {
    if (!dpad) return;
    float dx = 0.0f, dy = 0.0f;
    switch (hatValue) {
        case 0: dy =  1.0f; break;
        case 1: dx =  1.0f; dy =  1.0f; break;
        case 2: dx =  1.0f; break;
        case 3: dx =  1.0f; dy = -1.0f; break;
        case 4: dy = -1.0f; break;
        case 5: dx = -1.0f; dy = -1.0f; break;
        case 6: dx = -1.0f; break;
        case 7: dx = -1.0f; dy =  1.0f; break;
        default: break;
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
        NSLog(@"[AresCrossOverBridge] Failed to create GCController snapshot");
        return;
    }

    @try { [g_aresController setValue:@"Cosmic Byte Ares" forKey:@"vendorName"]; } @catch (id ex) {}

    GCExtendedGamepad *ext = g_aresController.extendedGamepad;
    if (ext) {
        s_btnX = ext.buttonX; s_btnA = ext.buttonA;
        s_btnB = ext.buttonB; s_btnY = ext.buttonY;
        s_btnL1 = ext.leftShoulder; s_btnR1 = ext.rightShoulder;
        s_btnL2 = ext.leftTrigger;  s_btnR2 = ext.rightTrigger;
        s_btnMinus = ext.buttonOptions; s_btnPlus = ext.buttonMenu;
        s_btnL3 = ext.leftThumbstickButton; s_btnR3 = ext.rightThumbstickButton;
        s_btnHome = ext.buttonHome;
        s_leftStick = ext.leftThumbstick; s_rightStick = ext.rightThumbstick;
        s_dpad = ext.dpad;
    }

    NSLog(@"[AresCrossOverBridge] GCController snapshot created & cached: %@", g_aresController);

    [[NSNotificationCenter defaultCenter] postNotificationName:GCControllerDidConnectNotification
                                                        object:g_aresController];
}

static uint64_t g_pktCount = 0;

static void processPacket(const struct AresPacket *pkt) {
    if (pkt->magic != ARES_MAGIC) return;

    g_pktCount++;
    if (g_pktCount == 1 || (g_pktCount % 300 == 0)) {
        NSLog(@"[AresCrossOverBridge] Processed %llu packets (buttons=0x%04x lx=%d ly=%d rx=%d ry=%d hat=%d)",
              g_pktCount, pkt->buttons, pkt->lx, pkt->ly, pkt->rx, pkt->ry, pkt->hat);
    }

    if (!g_aresController) setupControllerIfNeeded();

    if (pkt->lx != s_prevLX || pkt->ly != s_prevLY) {
        s_prevLX = pkt->lx; s_prevLY = pkt->ly;
        if (s_leftStick) [s_leftStick setValueForXAxis:normalizeAxis(pkt->lx) yAxis:normalizeAxis(pkt->ly)];
    }
    if (pkt->rx != s_prevRX || pkt->ry != s_prevRY) {
        s_prevRX = pkt->rx; s_prevRY = pkt->ry;
        if (s_rightStick) [s_rightStick setValueForXAxis:normalizeAxis(pkt->rx) yAxis:normalizeAxis(pkt->ry)];
    }
    if (pkt->hat != s_prevHat) {
        s_prevHat = pkt->hat;
        updateDpad(s_dpad, pkt->hat);
    }

    uint16_t b = pkt->buttons;
    if (b != s_prevButtons) {
        uint16_t changed = b ^ s_prevButtons;
        s_prevButtons = b;
        if ((changed & (1<<0))  && s_btnX)     [s_btnX setValue:(b&(1<<0)) ?1.f:0.f];
        if ((changed & (1<<1))  && s_btnA)     [s_btnA setValue:(b&(1<<1)) ?1.f:0.f];
        if ((changed & (1<<2))  && s_btnB)     [s_btnB setValue:(b&(1<<2)) ?1.f:0.f];
        if ((changed & (1<<3))  && s_btnY)     [s_btnY setValue:(b&(1<<3)) ?1.f:0.f];
        if ((changed & (1<<4))  && s_btnL1)    [s_btnL1 setValue:(b&(1<<4)) ?1.f:0.f];
        if ((changed & (1<<5))  && s_btnR1)    [s_btnR1 setValue:(b&(1<<5)) ?1.f:0.f];
        if ((changed & (1<<6))  && s_btnL2)    [s_btnL2 setValue:(b&(1<<6)) ?1.f:0.f];
        if ((changed & (1<<7))  && s_btnR2)    [s_btnR2 setValue:(b&(1<<7)) ?1.f:0.f];
        if ((changed & (1<<8))  && s_btnMinus) [s_btnMinus setValue:(b&(1<<8)) ?1.f:0.f];
        if ((changed & (1<<9))  && s_btnPlus)  [s_btnPlus setValue:(b&(1<<9)) ?1.f:0.f];
        if ((changed & (1<<10)) && s_btnL3)    [s_btnL3 setValue:(b&(1<<10))?1.f:0.f];
        if ((changed & (1<<11)) && s_btnR3)    [s_btnR3 setValue:(b&(1<<11))?1.f:0.f];
        if ((changed & (1<<12)) && s_btnHome)  [s_btnHome setValue:(b&(1<<12))?1.f:0.f];
    }
}

static void startUDPServer(void) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { NSLog(@"[AresCrossOverBridge] socket() failed: %s", strerror(errno)); return; }

    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    fcntl(sock, F_SETFL, O_NONBLOCK);

    struct sockaddr_in sin = {0};
    sin.sin_family      = AF_INET;
    sin.sin_port        = htons(ARES_PORT);
    sin.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (bind(sock, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        NSLog(@"[AresCrossOverBridge] bind() failed: %s", strerror(errno));
        close(sock); return;
    }
    NSLog(@"[AresCrossOverBridge] Listening on 127.0.0.1:%d", ARES_PORT);

    dispatch_queue_t bgQ = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    g_socketSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 0, bgQ);
    dispatch_source_set_event_handler(g_socketSource, ^{
        @autoreleasepool {
            struct AresPacket pkt;
            while (recv(sock, &pkt, sizeof(pkt), 0) == sizeof(pkt)) processPacket(&pkt);
        }
    });
    dispatch_source_set_cancel_handler(g_socketSource, ^{ close(sock); });
    dispatch_resume(g_socketSource);
}

// ---------------------------------------------------------------------------
// Constructor & Destructor
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void AresCrossOverBridge_Init(void) {
    NSLog(@"[AresCrossOverBridge] Init in PID %d", getpid());

    // Auto-start translator helper when Wine/game starts
    ensureTranslatorRunning();
    atexit(stopTranslatorIfSpawned);

    Class gcClass = NSClassFromString(@"GCController");
    if (!gcClass) {
        NSLog(@"[AresCrossOverBridge] GCController not found, skipping");
        return;
    }

    // Swizzle +[GCController controllers]
    Method origMethod = class_getClassMethod(gcClass, @selector(controllers));
    if (origMethod) {
        orig_controllers = (NSArray<GCController *> * (*)(id, SEL))method_getImplementation(origMethod);
        method_setImplementation(origMethod, (IMP)swizzled_controllers);
        NSLog(@"[AresCrossOverBridge] Swizzled +[GCController controllers]");
    }

    setupControllerIfNeeded();
    startUDPServer();
    startSDLRetryThread();

    NSLog(@"[AresCrossOverBridge] Init complete");
}

__attribute__((destructor))
static void AresCrossOverBridge_Fini(void) {
    NSLog(@"[AresCrossOverBridge] Fini in PID %d", getpid());
    stopTranslatorIfSpawned();
}
