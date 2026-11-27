// Identical pads (pad_hid_mac.h) with fake IOKit entries and fake GameController controllers: only an entry that sends reports counts as a pad of its model, so one
// Pro Controller with a second, silent entry stays with GameController (GitHub issue #2237), while two that both stream are read as twins (GitHub issue #1218).
// Raw HID layouts: Steam Link's virtual Xbox 360 pad (045e:028e, GitHub issue #2465) through discovery and the value callback
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GameController.h>
#import <GameController/GCSyntheticDeviceKeys.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../dm_input.h"

@interface TestDev : NSObject
@property int vid, pid; @property long loc; @property uint64_t entry; @property NSString *transport;
@property uint8_t *buffer; @property IOHIDReportCallback callback; @property void *context;
@property NSString *name; @property NSArray *elements; @property IOHIDValueCallback valueCallback; @property void *valueContext;
@end
@implementation TestDev
@end
@interface TestElem : NSObject
@property uint32_t page, usage;
@end
@implementation TestElem
@end
static TestElem *elem(uint32_t page, uint32_t usage) { TestElem *e = [TestElem new]; e.page = page; e.usage = usage; return e; }
@interface TestValue : NSObject
@property TestElem *element; @property CFIndex value;
@end
@implementation TestValue
@end
@interface TestGC : NSObject
@property NSString *productCategory, *vendorName; @property id extendedGamepad;
@end
@implementation TestGC
static NSMutableArray *g_gc; static BOOL g_supports = YES;
+ (NSArray *)controllers { return g_gc; }
+ (BOOL)supportsHIDDevice:(IOHIDDeviceRef)d { (void)d; return g_supports; }
@end

static CFTypeRef test_property(IOHIDDeviceRef device, CFStringRef key) {
    TestDev *d = (__bridge id)device;
    if (CFEqual(key, CFSTR(kIOHIDProductKey))) return (__bridge CFTypeRef)(d.name ?: @"Pro Controller");
    if (CFEqual(key, CFSTR(kIOHIDVendorIDKey))) return (__bridge CFTypeRef)@(d.vid);
    if (CFEqual(key, CFSTR(kIOHIDProductIDKey))) return (__bridge CFTypeRef)@(d.pid);
    if (CFEqual(key, CFSTR(kIOHIDLocationIDKey))) return (__bridge CFTypeRef)@(d.loc);
    if (CFEqual(key, CFSTR(kIOHIDTransportKey))) return (__bridge CFTypeRef)d.transport;
    return NULL;
}
static void test_report_cb(IOHIDDeviceRef device, uint8_t *buffer, CFIndex len, IOHIDReportCallback callback, void *ctx) {
    TestDev *d = (__bridge id)device; assert(len >= 49);
    d.buffer = buffer; d.callback = callback; d.context = ctx;
}
static void test_value_cb(IOHIDDeviceRef device, IOHIDValueCallback callback, void *ctx) { TestDev *d = (__bridge id)device; d.valueCallback = callback; d.valueContext = ctx; }
static CFArrayRef test_elements(IOHIDDeviceRef device, CFDictionaryRef match, IOOptionBits o) { (void)match; (void)o; return CFBridgingRetain(((__bridge TestDev *)device).elements ?: @[]); }
static IOHIDElementRef test_val_element(IOHIDValueRef v) { return (__bridge IOHIDElementRef)((__bridge TestValue *)v).element; }
static CFIndex test_val_int(IOHIDValueRef v) { return ((__bridge TestValue *)v).value; }
static CFIndex test_el_min(IOHIDElementRef e) { (void)e; return 0; }
static CFIndex test_el_max(IOHIDElementRef e) { (void)e; return 1; }
static uint32_t test_el_page(IOHIDElementRef e) { return ((__bridge TestElem *)e).page; }
static uint32_t test_el_usage(IOHIDElementRef e) { return ((__bridge TestElem *)e).usage; }
static io_service_t test_service(IOHIDDeviceRef device) { return (io_service_t)((__bridge TestDev *)device).entry; }
static kern_return_t test_entry_id(io_registry_entry_t e, uint64_t *id) { *id = e; return KERN_SUCCESS; }
static IOReturn test_set_report(IOHIDDeviceRef d, IOHIDReportType t, CFIndex id, const uint8_t *r, CFIndex n) { (void)d; (void)t; (void)id; (void)r; (void)n; return kIOReturnSuccess; }

static uint64_t tick = 1000000000;
uint64_t now_ns(void) { return tick; }
#define LOG(...) (printf(__VA_ARGS__), putchar('\n'))
#define IOHIDDeviceGetProperty test_property
#define IOHIDDeviceRegisterInputReportCallback test_report_cb
#define IOHIDDeviceRegisterInputValueCallback test_value_cb
#define IOHIDDeviceCopyMatchingElements test_elements
#define IOHIDValueGetElement test_val_element
#define IOHIDValueGetIntegerValue test_val_int
#define IOHIDElementGetLogicalMin test_el_min
#define IOHIDElementGetLogicalMax test_el_max
#define IOHIDElementGetUsagePage test_el_page
#define IOHIDElementGetUsage test_el_usage
#define IOHIDDeviceGetService test_service
#define IORegistryEntryGetRegistryEntryID test_entry_id
#define IOHIDDeviceSetReport test_set_report
#define GCController TestGC
#include "../pad_hid_mac.h"

static int attached, changes, reads; static uint64_t buttons;
static void hidpad_attach(hid_pad *d) { (void)d; attached++; }
static void hidpad_detach(hid_pad *d) { (void)d; attached--; }
static void hidpad_read(hid_pad *d) { reads++; buttons = pad_hid_buttons(&d->st); }
static void hidpad_motion(hid_pad *d, const pro_motion_sample *s, int n) { (void)d; (void)s; (void)n; }
static void hidpad_models_changed(void) { changes++; hidpad_twins_eval(nil); hidpad_twins_release(); hidpad_twins_take(nil); hidpad_kp20_pair(nil); }   // front_mac.m's pads_changed, without its slots
static int moved;
static void hidpad_kp20_moved(void) { moved++; }

static IOHIDDeviceRef ref(TestDev *d) { return (__bridge IOHIDDeviceRef)d; }
static TestDev *pro(long loc, uint64_t entry, NSString *transport) { TestDev *d = [TestDev new]; d.vid = 0x057e; d.pid = 0x2009; d.loc = loc; d.entry = entry; d.transport = transport; return d; }
static void drain(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false); }   // the dispatch_async'd recounts
static void report(TestDev *d) {
    assert(d.callback && d.buffer); memset(d.buffer, 0, 49); d.buffer[0] = 0x30;
    d.callback(d.context, kIOReturnSuccess, ref(d), kIOHIDReportTypeInput, 0x30, d.buffer, 49);
    tick += 15000000; drain();
}
static int twins(void) { int n = 0; for (hid_pad *d = g_hidpads; d; d = d->next) n += d->twin; return n; }
static hid_pad *find(TestDev *t) { for (int pass = 0; pass < 2; pass++) for (hid_pad *d = pass ? g_hidpads : g_hidpads_gc; d; d = d->next) if (d->hid == ref(t)) return d; return NULL; }
static void push_value(TestDev *d, TestElem *element, CFIndex value) {
    assert(d.valueCallback);
    TestValue *v = [TestValue new]; v.element = element; v.value = value;
    int before = reads; d.valueCallback(d.valueContext, kIOReturnSuccess, ref(d), (__bridge IOHIDValueRef)v);
    assert(reads == before + 1);
}
// The Xbox 360 layout is chosen from the ID and the descriptor's axes, and discovery and the value callback map Z / Rz to the triggers alike. The devices are ones
// GameController does not support, so they are read as HID at once
static void hid_layouts(void) {
    TestElem *x = elem(1, 0x30), *y = elem(1, 0x31), *z = elem(1, 0x32), *rz = elem(1, 0x35), *rx = elem(1, 0x33), *ry = elem(1, 0x34);
    TestElem *face = elem(9, 3), *brake = elem(2, 0xC5), *accel = elem(2, 0xC4);
    TestDev *steam = [TestDev new]; steam.name = @"Remote controller"; steam.vid = 0x045e; steam.pid = 0x028e; steam.entry = 113; steam.elements = @[x, y, z, rz, rx, ry, face];
    TestDev *other = [TestDev new]; other.name = @"Xbox ID with dedicated triggers"; other.vid = 0x045e; other.pid = 0x028e; other.entry = 114; other.elements = @[x, y, rx, ry, brake, accel, face];
    g_supports = NO;
    for (TestDev *d in @[steam, other]) hidpad_found(NULL, kIOReturnSuccess, NULL, ref(d));
    g_supports = YES;
    assert(attached == 2 && find(steam)->st.layout == PAD_HID_X360 && find(other)->st.layout == PAD_HID_DEFAULT);
    assert(find(steam)->st.has[PH_BRAKE] && find(steam)->st.has[PH_ACCEL] && !find(steam)->st.has[PH_Z] && !find(steam)->st.has[PH_RZ]);

    int32_t s[4];
    push_value(steam, face, 1); assert(buttons == DM_BTN_Y);
    push_value(steam, face, 0); assert(buttons == 0);
    push_value(steam, rx, 1);
    push_value(steam, z, 1); assert(buttons == DM_BTN_ZL);
    push_value(steam, rz, 1); assert(buttons == (DM_BTN_ZL | DM_BTN_ZR));
    pad_hid_sticks(&find(steam)->st, s); assert(s[2] == DM_STICK_MAX && s[3] == 0);
    push_value(steam, z, 0); assert(buttons == DM_BTN_ZR);
    push_value(steam, rz, 0); assert(buttons == 0);

    push_value(other, face, 1); assert(buttons == 0);   // the default map has no usage 3
    push_value(other, brake, 1); assert(buttons == DM_BTN_ZL);
    push_value(other, accel, 1); assert(buttons == (DM_BTN_ZL | DM_BTN_ZR));
    push_value(other, brake, 0); push_value(other, accel, 0); assert(buttons == 0);
    for (TestDev *d in @[steam, other]) hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(d));
    assert(!attached && !g_hidpads && !g_hidpads_gc && !g_hidpads_waiting);
    puts("t_pad_hid_mac: Xbox 360 axis matching passed");
}

// A 0x30 report with these raw 12-bit sticks (left x, y, right x, y; 0x800 the middle)
static void report_sticks(TestDev *d, const int raw[4]) {
    assert(d.callback && d.buffer); memset(d.buffer, 0, 49); d.buffer[0] = 0x30;
    for (int k = 0; k < 2; k++) { uint8_t *b = d.buffer + 6 + 3 * k; int x = raw[2 * k], y = raw[2 * k + 1]; b[0] = x & 0xff; b[1] = (x >> 8 & 0x0f) | (y & 0x0f) << 4; b[2] = y >> 4; }
    d.callback(d.context, kIOReturnSuccess, ref(d), kIOHIDReportTypeInput, 0x30, d.buffer, 49);
    tick += 15000000; drain();
}
// Betop Kunpeng 20 in NS mode over USB (S2Arm 0d4e4c702's idea): GameController lists it as a Pro Controller with dead sticks; alone, its sticks come from its 0x30 for that
// controller, and a stick change reads the controller again. A Pro Controller is never paired (the negative control), nor a Kunpeng 20 beside one, nor one over Bluetooth
static void kp20(void) {
    TestGC *gc = [TestGC new]; gc.productCategory = @"Switch Pro Controller"; gc.vendorName = @"Pro Controller"; gc.extendedGamepad = @1;
    [g_gc addObject:gc];
    static const int rest[4] = {0x800, 0x800, 0x800, 0x800}, push[4] = {0xe00, 0x800, 0x800, 0x200};
    int32_t s[4] = {7, 7, 7, 7};
    // a Pro Controller alone: nothing paired, its GameController sticks stay
    TestDev *real = pro(0x01300000, 31, @"USB"); hidpad_found(NULL, kIOReturnSuccess, NULL, ref(real));
    assert(find(real) && !find(real)->kp20 && real.callback);
    report_sticks(real, rest); report_sticks(real, push);
    assert(!g_kp20_pad && !hidpad_kp20_sticks(gc, s) && s[0] == 7 && moved == 0);
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(real));
    // the Kunpeng 20 on its receiver: paired at its first report, its sticks for its controller only
    TestDev *kp = pro(0x01400000, 41, @"USB"); kp.name = @"BTP-KP20E NS DONGLE";
    g_twins_off = 1;   // listened to even with DM_PAD_IDENTICAL=0
    hidpad_found(NULL, kIOReturnSuccess, NULL, ref(kp));
    g_twins_off = 0;
    assert(find(kp) && find(kp)->kp20 && kp.callback && !g_kp20_pad);
    report_sticks(kp, rest);
    assert(g_kp20_pad == find(kp) && g_kp20_gc == gc && attached == 0 && twins() == 0 && !hidpad_gc_unread(gc));   // GameController keeps its buttons
    assert(hidpad_kp20_sticks(gc, s) && !s[0] && !s[1] && !s[2] && !s[3]);
    int before = moved; report_sticks(kp, push);
    assert(moved == before + 1 && hidpad_kp20_sticks(gc, s) && s[0] == DM_STICK_MAX && s[1] == 0 && s[2] == 0 && s[3] == -DM_STICK_MAX);
    report_sticks(kp, push); assert(moved == before + 1);   // unchanged: no read
    TestGC *other = [TestGC new]; other.productCategory = @"Xbox One"; other.extendedGamepad = @1;
    s[0] = 7; assert(!hidpad_kp20_sticks(other, s) && s[0] == 7);   // another controller keeps its own
    tick += PRO_SILENT_NS; assert(!hidpad_kp20_sticks(gc, s));         // silent: GameController's again
    report_sticks(kp, rest);
    // a Pro Controller beside it: two entries send 0x30, so no pair; its going pairs again
    TestDev *real2 = pro(0x01500000, 51, @"USB"); hidpad_found(NULL, kIOReturnSuccess, NULL, ref(real2));
    report_sticks(real2, rest);
    hidpad_models_changed();
    assert(!g_kp20_pad && !g_kp20_gc && !hidpad_kp20_sticks(gc, s));
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(real2)); report_sticks(kp, rest); hidpad_models_changed();
    assert(g_kp20_pad == find(kp));
    // GameController listing a second Pro Controller (one IOKit has no live entry for): which one is the Kunpeng 20 is not known, so no pair; with it gone, the pair again
    TestGC *gc2 = [TestGC new]; gc2.productCategory = @"Switch Pro Controller"; gc2.vendorName = @"Pro Controller"; gc2.extendedGamepad = @1;
    [g_gc addObject:gc2]; report_sticks(kp, rest); hidpad_models_changed();
    assert(!g_kp20_pad && !g_kp20_gc && !hidpad_kp20_sticks(gc, s) && !hidpad_kp20_sticks(gc2, s));
    [g_gc removeObject:gc2]; hidpad_models_changed();
    assert(g_kp20_pad == find(kp) && g_kp20_gc == gc);
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(kp));
    assert(!g_kp20_pad && !g_kp20_gc);
    // the same name over Bluetooth is not taken for one
    TestDev *bt = pro(0x69aabbdd, 61, @"Bluetooth"); bt.name = @"BTP-KP20E NS DONGLE";
    hidpad_found(NULL, kIOReturnSuccess, NULL, ref(bt)); assert(!find(bt)->kp20);
    report_sticks(bt, rest); assert(!g_kp20_pad);
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(bt));
    [g_gc removeObject:gc];
    assert(!g_hidpads && !g_hidpads_gc && attached == 0);
    puts("t_pad_hid_mac: Betop Kunpeng 20 sticks passed");
}

int main(void) { @autoreleasepool {
    g_gc = [NSMutableArray new];
    hid_layouts();
    kp20();
    TestGC *gc = [TestGC new]; gc.productCategory = @"Switch Pro Controller"; gc.vendorName = @"Pro Controller"; gc.extendedGamepad = @1;
    // issue #2237: one Pro Controller over Bluetooth, which GameController lists, and a second entry of its model at location 0 that sends nothing
    [g_gc addObject:gc];
    TestDev *bt = pro(0x69aabbcc, 11, @"Bluetooth"), *ghost = pro(0, 12, @"Bluetooth");
    hidpad_found(NULL, kIOReturnSuccess, NULL, ref(bt)); hidpad_found(NULL, kIOReturnSuccess, NULL, ref(ghost));
    assert(find(bt) && find(ghost) && bt.callback && ghost.callback);   // both listened to
    report(bt); report(bt);
    g_twins_due = 1; hidpad_models_changed(); g_twins_due = 0;           // past the twin wait
    assert(twins() == 0 && attached == 0 && !hidpad_gc_unread(gc));     // GameController keeps reading the one pad
    assert(find(ghost)->shown == 1);                                    // named once as not counted
    // a pad that stops streaming without being removed is not counted at the next change: the old entry of a reconnected pad
    TestDev *bt2 = pro(0x69aabbcc, 13, @"Bluetooth");
    hidpad_found(NULL, kIOReturnSuccess, NULL, ref(bt2));
    tick += PRO_SILENT_NS; report(bt2);
    g_twins_due = 1; hidpad_models_changed(); g_twins_due = 0;
    assert(twins() == 0 && !hidpad_gc_unread(gc));
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(bt)); hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(ghost)); hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(bt2));
    assert(!g_hidpads && !g_hidpads_gc);
    // issue #1218: two Pro Controllers over USB that GameController lists as one; both stream, so both are read here, and the second only once it sends
    TestDev *u1 = pro(0x01100000, 21, @"USB"), *u2 = pro(0x01200000, 22, @"USB");
    hidpad_found(NULL, kIOReturnSuccess, NULL, ref(u1)); hidpad_found(NULL, kIOReturnSuccess, NULL, ref(u2));
    report(u1);
    g_twins_due = 1; hidpad_models_changed(); g_twins_due = 0;
    assert(twins() == 0);                                               // u2 has sent nothing yet
    report(u2);
    g_twins_due = 1; hidpad_models_changed(); g_twins_due = 0;
    assert(twins() == 2 && attached == 2 && hidpad_gc_unread(gc) && g_hidpads->hid == ref(u2));   // by USB location: u1 taken first, so u2 is at the head
    report(u1); report(u2);
    // one falls silent (no removal): at the next change it is not counted, so both go back to GameController
    tick += PRO_SILENT_NS; report(u2);
    hidpad_models_changed();
    assert(twins() == 0 && attached == 0 && !hidpad_gc_unread(gc));
    report(u1); g_twins_due = 1; hidpad_models_changed(); g_twins_due = 0;   // it streams again: read here again
    assert(twins() == 2 && attached == 2);
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(u1));
    assert(twins() == 0 && attached == 0);                              // one left: back to GameController
    hidpad_removed(NULL, kIOReturnSuccess, NULL, ref(u2));
    assert(!g_hidpads && !g_hidpads_gc);
    printf("t_pad_hid_mac: passed (%d recounts)\n", changes);
} }
