#import "DuoLiveObjects.h"
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <objc/runtime.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <dlfcn.h>

uint64_t duo_phys_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

static uint64_t duo_vm_tag_sum(unsigned tag, bool resident) {
    uint64_t total = 0;
    vm_address_t address = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        if (info.user_tag == tag) total += resident ? (uint64_t)info.pages_resident * vm_page_size : (uint64_t)size;
        address += size;
    }
    return total;
}

uint64_t duo_vm_tag_resident(unsigned tag) { return duo_vm_tag_sum(tag, true); }
uint64_t duo_vm_tag_virtual(unsigned tag) { return duo_vm_tag_sum(tag, false); }

// The isa's class bits: arm64 simulators use the arm64e layout (objc4 isa.h ISA_MASK); a Swift object's metadata pointer passes through unchanged
#if TARGET_OS_SIMULATOR && __arm64__
#define DUO_ISA_MASK 0x007ffffffffffff8ULL
#elif __arm64__
#define DUO_ISA_MASK 0x0000000ffffffff8ULL
#else
#define DUO_ISA_MASK 0x00007ffffffffff8ULL
#endif

typedef struct { uintptr_t cls; size_t least; unsigned count; } DuoCount;

static kern_return_t duo_reader(task_t task, vm_address_t address, vm_size_t size, void **local) {
    (void)task; (void)size;
    *local = (void *)address;   // this process: the memory is already here
    return KERN_SUCCESS;
}

static void duo_recorder(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned n) {
    (void)task; (void)type;
    DuoCount *c = context;
    for (unsigned i = 0; i < n; i++) {
        if (ranges[i].size < c->least) continue;
        uintptr_t first = *(const uintptr_t *)ranges[i].address;
        if ((first & DUO_ISA_MASK) == c->cls) c->count++;
    }
}

unsigned duo_live_instances(Class cls) {
    vm_address_t *zones = NULL;
    unsigned n = 0;
    if (malloc_get_all_zones(mach_task_self(), duo_reader, &zones, &n) != KERN_SUCCESS || !zones) return UINT_MAX;
    size_t least = class_getInstanceSize(cls);
    DuoCount c = { (uintptr_t)(__bridge void *)cls, least < sizeof(uintptr_t) ? sizeof(uintptr_t) : least, 0 };
    for (unsigned i = 0; i < n; i++) {
        malloc_zone_t *z = (malloc_zone_t *)zones[i];
        if (!z || !z->introspect || !z->introspect->enumerator) continue;
        if (z->introspect->force_lock) z->introspect->force_lock(z);
        z->introspect->enumerator(mach_task_self(), &c, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)z, duo_reader, duo_recorder);
        if (z->introspect->force_unlock) z->introspect->force_unlock(z);
    }
    return c.count;
}

bool duo_vm_tag_largest(unsigned tag, uintptr_t *lo, uintptr_t *hi) {
    vm_address_t address = 0, best = 0;
    vm_size_t bestSize = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        if (info.user_tag == tag && size > bestSize) { best = address; bestSize = size; }
        address += size;
    }
    if (!bestSize) return false;
    *lo = best; *hi = best + bestSize;
    return true;
}

#define DUO_REFS_MAX 16
typedef struct { uintptr_t lo, hi; uintptr_t at[DUO_REFS_MAX]; size_t size[DUO_REFS_MAX]; size_t offset[DUO_REFS_MAX]; uintptr_t value[DUO_REFS_MAX]; unsigned count; } DuoRefs;

static void duo_ref_recorder(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned n) {
    (void)task; (void)type;
    DuoRefs *r = context;
    for (unsigned i = 0; i < n && r->count < DUO_REFS_MAX; i++) {
        if (ranges[i].address <= r->lo && r->lo < ranges[i].address + ranges[i].size) continue;   // the block itself
        const uintptr_t *w = (const uintptr_t *)ranges[i].address;
        for (size_t j = 0; j < ranges[i].size / sizeof(uintptr_t); j++) {
            uintptr_t v = w[j] & 0x0000ffffffffffffULL;
            if (v >= r->lo && v < r->hi) { r->at[r->count] = ranges[i].address; r->size[r->count] = ranges[i].size; r->offset[r->count] = j * sizeof(uintptr_t); r->value[r->count] = v; r->count++; break; }
        }
    }
}

static void duo_heap_referrers(DuoRefs *r) {
    vm_address_t *zones = NULL;
    unsigned n = 0;
    if (malloc_get_all_zones(mach_task_self(), duo_reader, &zones, &n) != KERN_SUCCESS || !zones) return;
    for (unsigned i = 0; i < n; i++) {
        malloc_zone_t *z = (malloc_zone_t *)zones[i];
        if (!z || !z->introspect || !z->introspect->enumerator) continue;
        if (z->introspect->force_lock) z->introspect->force_lock(z);
        z->introspect->enumerator(mach_task_self(), r, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)z, duo_reader, duo_ref_recorder);
        if (z->introspect->force_unlock) z->introspect->force_unlock(z);
    }
}

static NSString *duo_describe(uintptr_t p, size_t size, Class *classes, unsigned nclasses) {
    uintptr_t isa = *(const uintptr_t *)p & DUO_ISA_MASK;
    for (unsigned i = 0; i < nclasses; i++) {
        if ((uintptr_t)(__bridge void *)classes[i] != isa) continue;
        NSString *name = @(class_getName(classes[i]));
        if ([name isEqualToString:@"__NSCFType"]) {
            CFStringRef t = CFCopyTypeIDDescription(CFGetTypeID((CFTypeRef)p));
            name = [NSString stringWithFormat:@"CF %@", (__bridge_transfer NSString *)t];
        }
        return [NSString stringWithFormat:@"%@ 0x%lx (%zu bytes)", name, (unsigned long)p, size];
    }
    return [NSString stringWithFormat:@"malloc block 0x%lx (%zu bytes, not an object)", (unsigned long)p, size];
}

// The loaded images' writable data that holds a pointer into [lo, hi)
static void duo_global_referrers(uintptr_t lo, uintptr_t hi, NSMutableArray<NSString *> *out) {
    const char *segs[] = { "__DATA", "__DATA_DIRTY", "__AUTH", "__DATA_CONST", "__AUTH_CONST" };
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        for (size_t s = 0; s < sizeof segs / sizeof *segs; s++) {
            unsigned long size = 0;
            const uintptr_t *w = (const uintptr_t *)getsegmentdata(h, segs[s], &size);
            for (unsigned long j = 0; w && j < size / sizeof(uintptr_t); j++) {
                uintptr_t v = w[j] & 0x0000ffffffffffffULL;
                if (v < lo || v >= hi) continue;
                Dl_info info = {0};
                dladdr(&w[j], &info);
                [out addObject:[NSString stringWithFormat:@"global %s in %s %s+0x%lx", info.dli_sname ?: "?", strrchr(_dyld_get_image_name(i), '/') ?: _dyld_get_image_name(i), segs[s], j * sizeof(uintptr_t)]];
            }
        }
    }
}

// Readable VM regions outside malloc that frameworks keep their own objects in (Core Animation's, Core Graphics', ImageIO's, untagged) and that hold a pointer into [lo, hi)
static void duo_region_referrers(uintptr_t lo, uintptr_t hi, NSMutableArray<NSString *> *out) {
    vm_address_t address = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        unsigned tag = info.user_tag;
        BOOL wanted = tag == 0 || tag == VM_MEMORY_LAYERKIT || tag == VM_MEMORY_COREGRAPHICS || (tag >= VM_MEMORY_COREGRAPHICS_DATA && tag <= VM_MEMORY_COREGRAPHICS_XALLOC)
            || tag == VM_MEMORY_IMAGEIO || tag == VM_MEMORY_FOUNDATION || tag == VM_MEMORY_CGIMAGE;
        if (wanted && (info.protection & VM_PROT_READ) && info.pages_resident > 0 && size <= 256u << 20 && !(address <= lo && lo < address + size)) {
            const uintptr_t *w = (const uintptr_t *)address;
            for (size_t j = 0; j < size / sizeof(uintptr_t); j++) {
                uintptr_t v = w[j] & 0x0000ffffffffffffULL;
                if (v >= lo && v < hi) { [out addObject:[NSString stringWithFormat:@"VM region tag %u 0x%lx-0x%lx at +0x%zx: 0x%lx", tag, (unsigned long)address, (unsigned long)(address + size), j * sizeof(uintptr_t), (unsigned long)v]]; break; }
            }
        }
        address += size;
    }
}

static void duo_tree(uintptr_t lo, uintptr_t hi, int depth, int level, Class *classes, unsigned nclasses, NSMutableString *out, NSMutableSet<NSNumber *> *seen) {
    DuoRefs r = { .lo = lo, .hi = hi };
    duo_heap_referrers(&r);
    NSMutableArray<NSString *> *globals = [NSMutableArray array];
    if (level == 1) duo_global_referrers(lo, hi, globals);   // a global points at an object, not into the middle of a block: only the first level
    if (level == 1) duo_region_referrers(lo, hi, globals);
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(level * 2) withString:@" " startingAtIndex:0];
    for (NSString *g in globals) [out appendFormat:@"%@<- %@\n", pad, g];
    if (r.count == 0 && globals.count == 0) [out appendFormat:@"%@<- (no heap block or global points here: a stack, a register, or memory leaks cannot read)\n", pad];
    for (unsigned i = 0; i < r.count; i++) {
        [out appendFormat:@"%@<- %@, at +0x%zx: 0x%lx\n", pad, duo_describe(r.at[i], r.size[i], classes, nclasses), r.offset[i], (unsigned long)r.value[i]];
        NSNumber *key = @(r.at[i]);
        if (level + 1 < depth && ![seen containsObject:key]) {
            [seen addObject:key];
            duo_tree(r.at[i], r.at[i] + r.size[i], depth, level + 1, classes, nclasses, out, seen);
        }
    }
}

NSString *duo_referrer_tree(uintptr_t lo, uintptr_t hi, int depth) {
    unsigned nclasses = 0;
    Class *classes = objc_copyClassList(&nclasses);
    NSMutableString *out = [NSMutableString stringWithFormat:@"0x%lx-0x%lx (%.1f MB)\n", (unsigned long)lo, (unsigned long)hi, (double)(hi - lo) / 1048576];
    duo_tree(lo, hi, depth, 1, classes, nclasses, out, [NSMutableSet set]);
    free(classes);
    return out;
}
