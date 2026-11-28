# Xenoblade Chronicles X: Definitive Edition – Nintendo Switch 2 Edition: changes to the game's own module, by function (no build of it has fixed-offset cuts).
# Nintendo SDK changes belong to dm/tools/sdk_patches.py.
#
# Monolith's allocator reserves 60 GB of address space with nn::os::AllocateAddressRegion in nninitStartup (upstream measured the request returning to main+0xae54c4 on
# the Mac), then a first arena of 4 GB + 128 KB inside it whose first 128 KB it maps and clears for bookkeeping. An iPhone's alias region cannot hold 60 GB: the SDK
# refuses it, the game does not check, and the clear is a memset of 0x20000 bytes to null (sdk+0x6d6448 from main+0xae38d0, both iPhone runs of NX 18 904d2c01a, and
# upstream's Mac run with the iPhone's alias region, README.md "Address space").
#
# The rule below is upstream's for the Switch 1 program 0100453019AA8000 (NXNative b32d0bf3b, by seedds: dm/games/0100453019AA8000/patches.py), its two complete
# function fingerprints unchanged. It applies only where this build's functions are the same code with the same callees as that game's 1.0.0 and 1.0.1 (the matcher
# checks the whole bodies, their direct callees and every original word); otherwise the rewrite log has a red "function patch ... skipped" line and the survey below
# lists this build's candidate functions with their offsets, sizes and fingerprints, which is what enrolling it needs. Not yet seen to match: the Switch 2 program was
# built with SDK 20, the Switch 1 one with SDK 19.
#
# One value differs from upstream's: the outer region is 12 GB, not 4 GB. On the Mac this program's reservation had opened pages up to 8.01 GB within its first
# 15 seconds of nnMain beside the 4 GB first arena (about 4 GB past it), and the Switch 1 program's reached 3.65 GB at its first field with the 512 MB arena; 4 GB
# would leave this one almost none. The profile's 16 GB alias region holds it (game.tsv), the split Fire Emblem Fortune's Weave plays in on the iPhone 18 Pro Max.
# The first arena's five cuts are upstream's (512 MB + 128 KB, with the bump, subtraction and stored capacity kept consistent).
MATCH_CUTS = {'main': [
    {'name': 'Monolith malloc region and first arena', 'functions': [
        {'size': 696, 'fingerprints': ['b00403a9284d46d15659fc765ce9c0d0474170eb6b9fe2369a4fb69f5458bba2'], 'cuts': [
            (0x10, 'e98340b2', 'e9ff9fd2', 'first arena bump size, low part: mov x9,#0xffff'),
            (0x20, '4900a0f2', '4900a4f2', 'first arena bump size: 512 MB + 128 KB + 64 KB - 1'),
            (0xa4, 'ea7b5fb2', 'ea8361b2', 'first arena subtraction, sign extension'),
            (0xac, 'caffbff2', 'caffbbf2', 'first arena subtraction: -(512 MB + 128 KB)'),
            (0xbc, '2800c0f2', '4800a4f2', 'first arena stored capacity: 512 MB + 128 KB'),
        ]},
        {'size': 16, 'fingerprints': ['df6920c64d84efc7c01f51f9b17e9bd252f9058ed5903bfe6fd5a7ff1a7f4ca3'], 'cuts': [
            (0, 'e001c0d2', '6000c0d2', 'malloc address region: 60 GB to 12 GB'),
        ]},
    ]},
]}

# Read only (patch_nso.py MATCH_SURVEY): when the rule above misses this build, the rewrite log lists the functions holding these instructions, any register
MATCH_SURVEY = {'main': [
    {'name': 'Monolith malloc region size (60 GB)', 'all': [(0xd2c001e0, 0xffffffe0, 'mov xN,#0xf00000000')], 'most': 8},
    {'name': 'Monolith first arena (4 GB + 128 KB)',
     'all': [(0xf2a00040, 0xffffffe0, 'movk xN,#0x2,lsl#16'), (0xf2c00020, 0xffffffe0, 'movk xN,#0x1,lsl#32')],
     'show': [(0xb24083e0, 0xffffffe0, 'mov xN,#0x1ffffffff'), (0xb25f7be0, 0xffffffe0, 'mov xN,#0xfffffffe00000000'), (0xf2bfffc0, 0xffffffe0, 'movk xN,#0xfffe,lsl#16'),
              (0xd2a00040, 0xffffffe0, 'mov xN,#0x20000')], 'most': 8},
]}

BINDING = [
    {'what': 'malloc region 60 GB → 12 GB and its first arena', 'now': 'game', 'goal': 'game', 'purpose': 'address space',
     'why': "Monolith's allocator calls nn::os directly, so the SDK's StandardAllocator gate cannot size it; its sizes span two functions matched atomically. The rule is the "
            "Switch 1 program's (upstream b32d0bf3b) with a 12 GB outer region for this program's larger reach; it applies only if this build's functions are that code"},
]
