// What DuoGateMemoryTests.swift measures in its own process: the app's physical footprint (what iOS counts against its memory limit) and how many live instances of a class the
// heap holds (DuoLiveObjects.m)
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// task_info TASK_VM_INFO phys_footprint in bytes, 0 when it cannot be read
uint64_t duo_phys_footprint(void);
// The resident bytes of the VM regions tagged tag (VM_MEMORY_CGIMAGE: the decoded images Core Graphics maps, footprint's "CG Image")
uint64_t duo_vm_tag_resident(unsigned tag);
// The virtual size of the VM regions tagged tag: every page mapped, resident, compressed, swapped or not yet touched, so memory pressure that compresses a mapped region
// does not make it look given back (vmmap's VIRTUAL SIZE)
uint64_t duo_vm_tag_virtual(unsigned tag);
// The blocks in use in every malloc zone whose first word is cls (an Objective-C object's isa with its flag bits masked, a Swift object's metadata pointer); UINT_MAX when the
// zones cannot be listed. Each zone is locked while it is walked and nothing is allocated meanwhile
unsigned duo_live_instances(Class cls);
// The largest VM region tagged tag: its start and end in *lo / *hi; false when there is none
bool duo_vm_tag_largest(unsigned tag, uintptr_t *lo, uintptr_t *hi);
// Who points into [lo, hi): the malloc blocks in use and the loaded images' data segments that hold such a pointer, then who points into each of those blocks, depth levels up,
// one line per holder (its class, or its CF type, or its malloc size; an image's segment and offset). A diagnostic for a footprint that does not come back
NSString *duo_referrer_tree(uintptr_t lo, uintptr_t hi, int depth);
NS_ASSUME_NONNULL_END
