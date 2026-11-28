// Freed small blocks of Unreal's heap keep their contents for a while, as FMallocBinned3's do: SHIN MEGAMI TENSEI V: Vengeance's battle tasks copy a map value
// out of the map's elements after the Add that reallocated them (hle_uemalloc.c release)
#include "../hle_uemalloc.c"
#include <assert.h>

module_t *g_mod;
int g_nmod;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
int gate_obs_present(int id) { (void)id; return 0; }
void gate_obs_set(int id, void (*callback)(uint64_t *, int)) { (void)id; (void)callback; }

typedef struct { int32_t key, pad; void *data; int32_t num, max; int32_t hash_next, hash_index; } elem_t;   // a TMap<int32, TArray> element, 32 bytes

int main(void) {
    g_zone = malloc_create_zone(0, 0);
    assert(g_zone);
    zone_ready();   // DM_UE_HEAP_FAST (the Makefile runs both)
    // The game's pattern: four elements fill the map, a reference to the last one's value is taken, Add grows the elements (a realloc that moves them) and the value is
    // then copied through the old reference
    for (int round = 0; round < 64; round++) {
        elem_t *e = m_Malloc(NULL, 4 * sizeof(elem_t), 0);
        for (int k = 0; k < 4; k++) e[k] = (elem_t){ .key = k, .data = (void *)(uintptr_t)(0x1000 + k), .num = k + 1, .max = 4, .hash_next = -1, .hash_index = k };
        elem_t *found = &e[3];
        elem_t *grown = m_Realloc(NULL, e, 24 * sizeof(elem_t), 0);
        assert(grown != e);   // moved: the reference is to the old block
        assert(found->key == 3 && found->data == (void *)0x1003 && found->num == 4);
        assert(grown[3].num == 4);
        m_Free(NULL, grown);
    }
    // A freed small block stays readable until LATE_N later frees have pushed it out (with DM_UE_HEAP_FAST, LATE_T later frees of the same thread)
    uint8_t *kept = m_Malloc(NULL, 200, 0);
    memset(kept, 0xa5, 200);
    m_Free(NULL, kept);
    for (int i = 0; i < (g_fast ? LATE_T : LATE_N) - 2; i++) m_Free(NULL, m_Malloc(NULL, 64, 0));
    for (int i = 0; i < 200; i++) assert(kept[i] == 0xa5);
    // A block that still holds the new size stays where it is; a large one goes to the zone at once
    uint8_t *same = m_Malloc(NULL, 100, 0);
    assert(m_Realloc(NULL, same, 90, 0) == same);
    m_Free(NULL, same);
    int64_t before = used_now();
    uint8_t *large = m_Malloc(NULL, 1 << 20, 0);
    m_Free(NULL, large);
    assert(used_now() == before);
    late_flush();
    assert(used_now() == 0);
    malloc_destroy_zone(g_zone);
    puts("Unreal heap: freed small blocks keep their contents passed");
    return 0;
}
