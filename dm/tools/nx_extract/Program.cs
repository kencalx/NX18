// NSP extraction (a native executable, dm/tools/nx_extract_bin/nx_extract, built by dm/tools/native_tools.sh): nx_extract <prod.keys> <base NSP> <update NSP or -> <output dir> [base RomFS dir to compare against] [--manifest] [--romfs-image]
// --romfs-image streams the merged RomFS directly to <output dir>/RomFS.img (the packing script's default); only ExeFS is expanded. Without it, legacy folder extraction remains available.
// With a base RomFS dir in legacy mode, files whose content matches it become APFS clones (no new space).
// --manifest: the RomFS is not written, only a list <output dir>/romfs_manifest.tsv (path, size, first 32 bytes), for surveying a new game (a large game's RomFS is well over 10 GB),
//   and its NRO modules under <output dir>/romfs_nro/ (small: their imports decide the graphics API and the modules, Portal 2's 21 NROs are 60 MB).
// A damaged NSP (a file whose data fails the NCA's hash check, e.g. a copy cut short or a broken download) stops the extraction with exit code 3 after listing every damaged file;
//   --allow-damaged writes those files as read instead and only lists them (Super Mario Galaxy's base NSP with 147 MB zeroed: its two prologue WebM movies). A RomFS image marks them in its index, and the host names them in its log.
// A sparse base program (Minecraft Dungeons II: its Program NCA leaves out data that its update carries) can be read only with its update: without one, exit code 4.
// Add-on content: nx_extract <prod.keys> --aoc <DLC NSP> <output dir> writes the RomFS of the DLC's data NCA to <output dir> (the packing script puts it at aoc/<index>/, the host mounts it through DM_AOC_DIR).
// Contents of packages: nx_extract <prod.keys> --contents <NSP, NSZ, XCI or XCZ>... prints, for each package in order, "package <index> <file name>", then one "content <type> <title ID> <version>"
//   line per content meta it holds (a merged package lists several: base game + update + DLC in one NSP, a cartridge dump with its update). The NSP script takes every package's title ID
//   and version from these lines, not from its file name. Only the meta NCAs are read (an NSZ keeps them uncompressed). A package that cannot be read, or holds no content meta, gets a
//   "[RED] <file name>: <why>" line in their place and the others are still listed: exit code 5. Keys that cannot open the meta NCAs stop it first (exit code 6, as for --keys).
// A multi-program application (Super Mario 3D All-Stars: a launcher and one program per game, title IDs base+0 to base+3) is read one program at a time:
//   --program=<16 hex digits> picks the program with that title ID (default: the lowest one, the application's own); --list prints every NCA (content type, title ID) and stops.
// Keys of a package: nx_extract <prod.keys> --keys <NSP, NSZ, XCI or XCZ>... checks that the keys open every NCA (an NCZ by its header, which nsz keeps as it was) without extracting anything.
//   Keys older than a game (a prod.keys dumped from a console on older firmware) lack the newer master key and every key derived from it; the newest key missing is named with the firmware
//   it came with, exit code 6. Extraction, --aoc and --contents run the same check before reading the NCAs it covers (LibHac would stop on the first such NCA with an unhandled MissingKeyException).
// Title keys come from the common tickets (.tik) inside the NSPs, so only prod.keys is needed; key values are never printed.
// The base game may also be a cartridge dump (.xci, Monster Hunter Rise): its secure partition holds the NCAs, which carry their keys in the key area (no ticket).
//   When the cartridge also carries an update (1G+1U), only the base game's NCAs (those its Application content meta lists) are read; the update comes from the update NSP.
// Decrypted NCAs (an NX made by nxconvert pack: scripts/pack_nx.py stages a snapshot's NCA files into a folder): --plain in place of <prod.keys>, a folder in place of each package:
//   nx_extract --plain <folder> <folder|-> <out dir> [--app <title ID>] [--program=<title ID>] [--romfs-image|--manifest] [--html] [--allow-damaged] [--list] [--max-bytes <n>]
//   nx_extract --plain --aoc <folder> <out image> [<DLC title ID>] [--romfs-image] [--max-bytes <n>]
//   nx_extract --plain --contents <folder>...
//   No key is read or needed (an empty key set, no tickets). The folder holds only files named <32 lowercase hex>.nca or <32 lowercase hex>.cnmt.nca (the content ID), at most 4,096.
//   An update's folder holds its base game's NCAs too (nxconvert's rule): it is given as both the base game and the update, and each content meta's filter picks its own, the patch
//   Program NCA laid over the base one (BKTR) as for a merged NSP. Each NCA is read through an in-memory header, checked before LibHac sees it: the DNCA marker (read as NCA3), the
//   distribution and content type, the size field against the file, the section table, each FS header's SHA-256 (before any edit), FS header version 2, SHA-256 or IVFC hash trees,
//   encryption type none on every section, the hash, relocation and compression tables inside their section, the PFS0 header bounded; a section the decrypter flattened from sparse
//   storage (DSPF at FS header 0x1D0) has its sparse info cleared (and is still sparse for exit code 4), one with sparse info and no DSPF is refused. The file is never changed.
//   Bounds: 2,000,000 entries per filesystem and paths of 768 characters (a loop in the tables ends there), --max-bytes (what the files declare, before anything is written), host file
//   names (one component, no control characters, 255 bytes, unique ignoring case; files are created new, so none overwrites another: give a new output folder), code modules and NROs of 1 GiB, a NACP of
//   exactly 0x4000 bytes and an icon of 4 MiB at most. Exit code 7: refused by these checks ("[RED] <file>: <why>"); 8: LibHac could not read them ("[RED] the NCA files cannot be read:
//   <exception>", no stack trace). Run it with DOTNET_GCHeapHardLimit (hexadecimal, no 0x: scripts/pack_nx.py gives 100000000, 4 GiB) to bound its memory too.
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Spl;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.FsSystem.RomFs;
using LibHac.Tools.Ncm;
using Path = System.IO.Path;

static class P {
    [DllImport("libc", SetLastError = true)] static extern int clonefile(string src, string dst, uint flags);

    static int Main(string[] a) {
        if (a.Length == 1 && a[0] == "--source-sha") {   // first 16 digits of the sha256 of the embedded Program.cs + csproj (the NSP script's nx_extract_source_sha)
            var asm = typeof(P).Assembly; var ms = new MemoryStream();
            foreach (var n in new[] { "src0", "src1" }) asm.GetManifestResourceStream(n).CopyTo(ms);
            Console.WriteLine(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(ms.ToArray()))[..16].ToLowerInvariant());
            return 0;
        }
        g_plain = a.Length > 0 && a[0] == "--plain";
        try { return Run(a); }
        catch (KeysMissing e) { Console.WriteLine($"[RED] {e.Message}"); return 6; }
        catch (Refused e) { Console.WriteLine($"[RED] {Esc(e.Message)}"); return 7; }
        // The tables a filesystem opens from fail the hash check (Mario & Luigi: Brothership's update: its Program NCA does not match its content ID): no file can be listed, so no file can be
        // named or written as read. Exit code 3, as for damaged files, not an unhandled exception's stack trace
        catch (HorizonResultException e) when (HashError(e)) {
            Console.WriteLine(g_plain ? "[RED] the NCA files are damaged: a filesystem's own tables fail the NCA's hash check, so --allow-damaged cannot read them either"
                                      : "[RED] the NSP is damaged: a filesystem's own tables fail the NCA's hash check, so --allow-damaged cannot read it either: an incomplete copy or a broken download, which a SHA-256 of each NCA shows (its file name is the hash's first 16 bytes); copy or download it again");
            return 3;
        }
        // Decrypted NCAs come from an archive anyone can make: whatever LibHac cannot read is one line and exit code 8, never a stack trace
        catch (OutOfMemoryException) when (g_plain) { Console.WriteLine("[RED] the NCA files cannot be read: they need more memory than nx_extract allows itself"); return 8; }
        catch (Exception e) when (g_plain) { Console.WriteLine($"[RED] the NCA files cannot be read: {e.GetType().Name}: {Esc(First(e.Message))}"); return 8; }
    }

    // ---- --plain: decrypted NCAs (DNCA) from a folder, no keys ----
    sealed class Refused : Exception { public Refused(string m) : base(m) { } }   // plain input refused by this tool's own checks: exit code 7
    static bool g_plain; static long g_budget = long.MaxValue;   // --max-bytes: what this run may still write
    static readonly HashSet<Nca> g_flattened = new HashSet<Nca>();   // NCAs with a section the decrypter flattened from sparse storage (DSPF)
    const int EntryCap = 2_000_000, PathCap = 0x300, NcaFilesMax = 4096, TreeEntriesMax = 16_777_216; const long ModuleMax = 1L << 30, IconMax = 4 << 20;
    static Exception Fail(string m) => g_plain ? new Refused(m) : new Exception(m);
    static string First(string m) { m = (m ?? "").Split('\n')[0]; return m.Length > 300 ? m[..300] : m; }
    static string Esc(string s) {   // control characters (C0, DEL, C1) and bidirectional overrides escaped: text from an archive must not drive a terminal
        var b = new System.Text.StringBuilder();
        foreach (char c in s ?? "") {
            if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) b.Append($"\\x{(int)c:x2}");
            else if ((c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)) b.Append($"\\u{(int)c:x4}");
            else b.Append(c);
        }
        return b.ToString();
    }
    static void Spend(long bytes) {   // --max-bytes: what the files to write declare, checked before writing them (entries sharing one range would expand a small input without bound)
        if (bytes > g_budget) throw new Refused($"the files declare {bytes:N0} bytes, more than the {g_budget:N0} this extraction may write (files that share their data?)");
        g_budget -= bytes;
    }
    static bool Inside(long off, long size, long bound) => off >= 0 && size >= 0 && off <= bound && size <= bound - off;
    static bool NcaName(string n) {   // <32 lowercase hex>.nca or <32 lowercase hex>.cnmt.nca
        if (n.Length != 36 && n.Length != 41) return false;
        for (int i = 0; i < 32; i++) if (!((n[i] >= '0' && n[i] <= '9') || (n[i] >= 'a' && n[i] <= 'f'))) return false;
        return n[32..] == ".nca" || n[32..] == ".cnmt.nca";
    }

    // A folder of decrypted NCAs, opened as OpenNsp opens a package; every file through PlainNca
    static List<Nca> OpenPlain(KeySet ks, string dir, ContentMetaType? only, ulong? id) {
        if (!Directory.Exists(dir)) throw new Refused(File.Exists(dir) ? $"{Path.GetFileName(dir)}: --plain reads a folder of decrypted NCA files, not a file" : $"no such folder: {dir}");
        FileSystemInfo[] all = new DirectoryInfo(dir).GetFileSystemInfos();
        if (all.Length > NcaFilesMax) throw new Refused($"{Path.GetFileName(dir)}: {all.Length:N0} files, more than the {NcaFilesMax:N0} an NCA snapshot may hold");
        Array.Sort(all, (x, y) => string.CompareOrdinal(x.Name, y.Name));
        var ncas = new List<Nca>(); var ids = new List<string>();
        foreach (FileSystemInfo e in all) {
            if (e.LinkTarget != null) throw new Refused($"{Esc(e.Name)}: a symbolic link, not a decrypted NCA file");
            if (e is DirectoryInfo) throw new Refused($"{Esc(e.Name)}: a folder, where only decrypted NCA files belong");
            if (!NcaName(e.Name)) throw new Refused($"{Esc(e.Name)}: not a decrypted NCA's file name (<32 hex>.nca or <32 hex>.cnmt.nca)");
            var (st, flat) = PlainNca(e.FullName, e.Name);
            var n = new Nca(ks, st);
            if (flat) g_flattened.Add(n);
            ncas.Add(n); ids.Add(e.Name[..32]);
        }
        return Filter(ks, ncas, ids, dir, only, id);
    }

    // The NCA file as LibHac reads it: its header checked, then served from memory with the marker read as NCA3 (LibHac takes a header as plaintext only with NCA at 0x200) and a
    // flattened sparse section's sparse info cleared; the rest straight from the file, which is never changed. Returns the storage and whether a section was flattened
    static (IStorage, bool) PlainNca(string path, string name) {
        var file = new LocalStorage(path, FileAccess.Read);
        file.GetSize(out long size).ThrowIfFailure();
        Refused Bad(string why) => new Refused($"{name}: {why}");
        if (size < 0xC00) throw Bad($"{size:N0} bytes, shorter than an NCA header (3,072 bytes)");
        byte[] h = new byte[0xC00]; file.Read(0, h).ThrowIfFailure();
        ReadOnlySpan<byte> magic = h.AsSpan(0x200, 4);
        if (!magic.SequenceEqual("DNCA"u8))
            throw Bad(magic.SequenceEqual("NCA3"u8) || magic.SequenceEqual("NCA2"u8) || magic.SequenceEqual("NCA0"u8) ? "a plaintext NCA without the DNCA marker of a decrypted NCA" : "not a decrypted NCA (still encrypted, or not an NCA)");
        if (h[0x204] > 1) throw Bad($"distribution type {h[0x204]} is not one an NCA has");
        if (h[0x205] > 5) throw Bad($"content type {h[0x205]} is not one an NCA has");
        long declared = BinaryPrimitives.ReadInt64LittleEndian(h.AsSpan(0x208));
        if (declared != size) throw Bad($"its header says {declared:N0} bytes, the file has {size:N0}");
        var start = new long[4]; var end = new long[4]; var used = new bool[4];
        for (int i = 0; i < 4; i++) {
            uint s = BinaryPrimitives.ReadUInt32LittleEndian(h.AsSpan(0x240 + 16 * i)), e = BinaryPrimitives.ReadUInt32LittleEndian(h.AsSpan(0x244 + 16 * i));
            if (s == 0 && e == 0) continue;
            if (s < 6 || e <= s || s > 0x7FFFFFFF || e > 0x7FFFFFFF || e * 0x200L > size) throw Bad($"section {i} lies outside the file");
            start[i] = s * 0x200L; end[i] = e * 0x200L; used[i] = true;
        }
        if (Array.IndexOf(used, true) < 0) throw Bad("no section");
        for (int i = 0; i < 4; i++) for (int j = i + 1; j < 4; j++)
            if (used[i] && used[j] && start[i] < end[j] && start[j] < end[i]) throw Bad($"sections {i} and {j} overlap");
        for (int i = 0; i < 4; i++)   // before any edit below: a damaged FS header must never pass because its hash was recomputed
            if (used[i] && !System.Security.Cryptography.SHA256.HashData(h.AsSpan(0x400 + 0x200 * i, 0x200)).AsSpan().SequenceEqual(h.AsSpan(0x280 + 32 * i, 32))) throw Bad($"FS header {i} fails its hash");
        bool flattened = false;
        for (int i = 0; i < 4; i++) {
            if (!used[i]) continue;
            byte[] fs = new byte[0x200]; Array.Copy(h, 0x400 + 0x200 * i, fs, 0, 0x200);
            long I64(int o) => BinaryPrimitives.ReadInt64LittleEndian(fs.AsSpan(o));
            int I32(int o) => BinaryPrimitives.ReadInt32LittleEndian(fs.AsSpan(o));
            bool Is(int o, ReadOnlySpan<byte> m) => fs.AsSpan(o, 4).SequenceEqual(m);
            int ver = BinaryPrimitives.ReadUInt16LittleEndian(fs); byte fsType = fs[2], hashType = fs[3], enc = fs[4];
            if (ver != 2) throw Bad($"FS header {i}: version {ver} is not supported");
            if (fsType > 1) throw Bad($"FS header {i}: fs type {fsType} is not supported");
            if (hashType != 2 && hashType != 3) throw Bad($"FS header {i}: hash type {hashType} is not supported (a decrypted NCA has SHA-256 or IVFC hash trees)");
            if (enc != 1) throw Bad($"section {i} is still encrypted (encryption type {enc}): a decrypted NCA has none");
            long sec = end[i] - start[i], bound = sec;
            void Tree(int at, long off, long tsize, long within, string what, Func<int, long> need) {   // a bucket-tree table: its BKTR header, entry count, and range
                int version = I32(at + 4), count = I32(at + 8);
                if (!Is(at, "BKTR"u8) || version != 1 || count < 0 || count > TreeEntriesMax || !Inside(off, tsize, within) || need(count) > tsize)
                    throw Bad($"section {i}: its {what} table is out of range");
            }
            if (I64(0x108) != 0) {   // a patch section (LibHac: a relocation table): its IVFC levels lie in the patched storage, whose size the table's first node gives
                if (fsType != 0 || hashType != 3) throw Bad($"section {i}: a relocation table on a section that is not an IVFC RomFS");
                Tree(0x110, I64(0x100), I64(0x108), sec, "relocation", c => IndirectStorage.QueryNodeStorageSize(c) + IndirectStorage.QueryEntryStorageSize(c));
                byte[] node = new byte[16]; file.Read(start[i] + I64(0x100), node).ThrowIfFailure();
                bound = BinaryPrimitives.ReadInt64LittleEndian(node.AsSpan(8));
                if (bound <= 0) throw Bad($"section {i}: its relocation table is out of range");
            }
            if (Is(0x130, "BKTR"u8)) Tree(0x130, I64(0x120), I64(0x128), sec, "AesCtrEx", c => 0);   // unused without encryption (a decrypter may also have zeroed it): only bounded
            long dataOff, dataSize;
            if (hashType == 2) {
                int block = I32(8 + 0x20), layers = I32(8 + 0x24);
                if (layers != 2 || block < 0x200 || block > 16 << 20 || (block & (block - 1)) != 0) throw Bad($"section {i}: its SHA-256 hash tree is not one of 2 layers with a block of 512 bytes to 16 MiB");
                dataOff = I64(8 + 0x38); dataSize = I64(8 + 0x40);
                if (!Inside(I64(8 + 0x28), I64(8 + 0x30), bound) || !Inside(dataOff, dataSize, bound)) throw Bad($"section {i}: its hash tree lies outside it");
            } else {
                int levels = I32(8 + 0x0C);
                if (!Is(8, "IVFC"u8) || levels < 2 || levels > 7 || I32(8 + 0x08) != 0x20) throw Bad($"section {i}: its IVFC header is not one of 2 to 7 levels");
                dataOff = dataSize = 0;
                for (int l = 0; l < levels - 1; l++) {
                    dataOff = I64(8 + 0x10 + 0x18 * l); dataSize = I64(8 + 0x18 + 0x18 * l); int log2 = I32(8 + 0x20 + 0x18 * l);
                    if (log2 < 9 || log2 > 24 || !Inside(dataOff, dataSize, bound)) throw Bad($"section {i}: its hash tree lies outside it");
                }
            }
            if (I64(0x178) != 0 && I64(0x180) != 0)   // compressed: the table lies in the data level, where LibHac's CompressedStorage reads it
                Tree(0x188, I64(0x178), I64(0x180), dataSize, "compression", c => CompressedStorage.QueryNodeStorageSize(c) + CompressedStorage.QueryEntryStorageSize(c));
            bool dspf = Is(0x1D0, "DSPF"u8);
            if (dspf) {   // flattened: the holes hold zeros; LibHac would read the sparse table through AES-CTR (a key), so the layer is taken away and the header hash made again
                Array.Clear(fs, 0x148, 0x30);
                fs.CopyTo(h, 0x400 + 0x200 * i);
                System.Security.Cryptography.SHA256.HashData(fs).CopyTo(h, 0x280 + 32 * i);
                flattened = true;
            } else if (BinaryPrimitives.ReadUInt16LittleEndian(fs.AsSpan(0x170)) != 0) throw Bad($"section {i} keeps a sparse layer that was not flattened (no DSPF marker): the decrypter did not finish it");
            if (fsType == 1 && !dspf) {   // the PFS0's file table, read whole by LibHac: bounded here
                byte[] p = new byte[16];
                if (dataSize < 16) throw Bad($"section {i}: its file table is too large or cut short");
                file.Read(start[i] + dataOff, p).ThrowIfFailure();
                uint count = BinaryPrimitives.ReadUInt32LittleEndian(p.AsSpan(4)), strings = BinaryPrimitives.ReadUInt32LittleEndian(p.AsSpan(8));
                if (!p.AsSpan(0, 4).SequenceEqual("PFS0"u8) || count > 1024 || strings > 0x10000 || 16 + 24L * count + strings > dataSize) throw Bad($"section {i}: its file table is too large or cut short");
            }
        }
        "NCA3"u8.CopyTo(h.AsSpan(0x200));
        return (new LibHac.Tools.FsSystem.ConcatenationStorage(new IStorage[] { new MemoryStorage(h), new SubStorage(file, 0xC00, size - 0xC00) }, true), flattened);
    }

    // Every entry of a filesystem, counted as it is listed: in plain mode at most EntryCap, each path once and at most PathCap characters (a RomFS whose tables loop ends here)
    static IEnumerable<DirectoryEntryEx> Entries(IFileSystem fs) {
        long n = 0; var seen = g_plain ? new HashSet<string>(StringComparer.Ordinal) : null;
        foreach (DirectoryEntryEx e in fs.EnumerateEntries("*", SearchOptions.RecurseSubdirectories)) {
            if (g_plain) {
                if (++n > EntryCap) throw new Refused($"the filesystem lists more than {EntryCap:N0} entries (a loop in its tables?)");
                if (e.FullPath.Length > PathCap) throw new Refused($"the filesystem has a path longer than {PathCap} characters (a loop in its folders?)");
                if (!seen.Add(e.FullPath)) throw new Refused($"the filesystem lists {Esc(e.FullPath)} twice (a loop in its tables?)");
            }
            yield return e;
        }
    }

    // Names written as host files (ExeFS modules, NROs, html pages): one component each; in plain mode also no control characters, at most 255 bytes, and no two in one folder that differ
    // only in letter case (files are created new there, so names a volume takes for one fail instead of overwriting)
    sealed class HostNames {
        readonly HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        public void Add(DirectoryEntryEx e) {
            string n = e.Name ?? "";
            if (n.Length == 0 || n == "." || n == ".." || n.Contains('/') || n.Contains('\0')) throw Fail($"invalid name {Esc(e.FullPath)} for a host file");
            if (!g_plain) return;
            foreach (char c in n) if (c < 0x20 || c == 0x7F || c == '\\') throw new Refused($"the name {Esc(e.FullPath)} holds a control character or a backslash, which no host file name here takes");
            if (System.Text.Encoding.UTF8.GetByteCount(n) > 255) throw new Refused($"the name {Esc(e.FullPath[..Math.Min(60, e.FullPath.Length)])}… is longer than a host file name (255 bytes)");
            string parent = e.FullPath.Length > n.Length ? e.FullPath[..(e.FullPath.Length - n.Length)] : "/";
            if (!seen.Add(parent.ToLowerInvariant() + n.Normalize(System.Text.NormalizationForm.FormD).ToLowerInvariant()))
                throw new Refused($"the names in {Esc(parent)} include two that differ only in letter case, as {Esc(e.FullPath)}: one file on a case-insensitive volume");
        }
    }
    static FileStream Create(string path) => new FileStream(path, g_plain ? FileMode.CreateNew : FileMode.Create, FileAccess.Write);

    static int Run(string[] a) {
        bool manifest = Array.IndexOf(a, "--manifest") >= 0; a = Array.FindAll(a, s => s != "--manifest");
        bool image = Array.IndexOf(a, "--romfs-image") >= 0; a = Array.FindAll(a, s => s != "--romfs-image");
        g_allow = Array.IndexOf(a, "--allow-damaged") >= 0; a = Array.FindAll(a, s => s != "--allow-damaged");
        string prog = Array.Find(a, s => s.StartsWith("--program=")); a = Array.FindAll(a, s => !s.StartsWith("--program="));
        ulong? progId = prog == null ? null : Convert.ToUInt64(prog.Substring(10), 16);
        bool list = Array.IndexOf(a, "--list") >= 0; a = Array.FindAll(a, s => s != "--list");
        bool html = Array.IndexOf(a, "--html") >= 0; a = Array.FindAll(a, s => s != "--html");   // the program's offline HTML pages instead of its files: the data of its HtmlDocument (Manual) NCAs, html<n>/ in the output dir, the update's first
        // --app <title ID>: the application to read from a package that holds several (Super Mario Galaxy + Super Mario Galaxy 2 on one cartridge dump); build_ipa_from_nsp.py
        // always names the one it packs. Without it every Application content meta's NCAs are kept and the lowest Program NCA is the game
        ulong? app = null; int ai = Array.IndexOf(a, "--app");
        if (ai >= 0 && ai + 1 < a.Length) { app = Convert.ToUInt64(a[ai + 1], 16); var rest = new List<string>(a); rest.RemoveRange(ai, 2); a = rest.ToArray(); }
        // --max-bytes <n>: the most this run may write (plain mode; scripts/pack_nx.py passes the volume's free space less 1 GiB)
        int mi = Array.IndexOf(a, "--max-bytes"); bool usage = false;
        if (mi >= 0) {
            if (mi + 1 >= a.Length || !long.TryParse(a[mi + 1], out g_budget) || g_budget < 0 || !g_plain) usage = true;
            else { var rest = new List<string>(a); rest.RemoveRange(mi, 2); a = rest.ToArray(); }
        }
        // --plain in place of prod.keys: decrypted NCAs from folders, with an empty key set (no prod.keys is read, no ticket imported)
        KeySet Keys0(string path) => g_plain ? new KeySet() : ExternalKeyReader.ReadKeyFile(path);
        if (!usage && a.Length >= 3 && a[1] == "--contents") return Contents(Keys0(a[0]), a[2..]);
        if (!usage && a.Length >= 3 && a[1] == "--keys" && !g_plain) return Keys(Keys0(a[0]), a[2..]);
        if (usage || a.Length < 4 || a[1] == "--keys") {
            Console.Error.WriteLine("usage: nx_extract <prod.keys> <base.nsp> <update.nsp|-> <out dir> [base RomFS dir] [--app <title ID>] [--program=<title ID>] [--list] [--html] [--romfs-image|--manifest] [--allow-damaged]\n       nx_extract <prod.keys> --aoc <dlc.nsp> <out dir or image> [<DLC title ID>] [--romfs-image]\n       nx_extract <prod.keys> --contents <nsp|nsz|xci|xcz>...\n       nx_extract <prod.keys> --keys <nsp|nsz|xci|xcz>...\n" +
                                    "       nx_extract --plain <folder> <folder|-> <out dir> [--app <title ID>] [--program=<title ID>] [--list] [--html] [--romfs-image|--manifest] [--allow-damaged] [--max-bytes <n>]\n       nx_extract --plain --aoc <folder> <out image> [<DLC title ID>] [--romfs-image] [--max-bytes <n>]\n       nx_extract --plain --contents <folder>...");
            return 2;
        }
        KeySet ks = Keys0(a[0]);
        if (a[1] == "--aoc") return Aoc(ks, a[2], a[3], image, a.Length > 4 ? Convert.ToUInt64(a[4], 16) : null);
        // each by its own content meta: a merged package (base game + update + DLC in one NSP, a cartridge dump with its update) is given as both the base game and the update,
        // and the base game's Program NCA and the update's have the same title ID, so without the filter the update would be layered on itself or on the wrong base
        var basePkg = OpenNsp(ks, a[1], ContentMetaType.Application, app); var updPkg = a[2] == "-" ? null : OpenNsp(ks, a[2], ContentMetaType.Patch, app | 0x800);
        if (list) {
            foreach (var (what, pkg) in new[] { ("base", basePkg), ("update", updPkg) })
                if (pkg != null) foreach (Nca n in pkg) Console.WriteLine($"{what} {n.Header.ContentType} {n.Header.TitleId:x16}");
            return 0;
        }
        Fit(new[] { MissingKey(ks, basePkg, a[1]), updPkg == null ? null : MissingKey(ks, updPkg, a[2]) });
        Nca baseProg = Pick(basePkg, NcaContentType.Program, progId) ?? throw Fail(progId == null ? "no Program NCA in the base NSP" : $"no Program NCA {progId:x16} in the base " + (g_plain ? "game's content meta" : "NSP"));
        if (html) {   // an update's NCA is read alone, or over a base game's NCA when its header marks the data section a patch (a relocation table); which base NCA it patches the
                      // header does not say: the one it reads with passes the hash check
            int k = 0; ulong tid = baseProg.Header.TitleId; var bases = basePkg.FindAll(n => n.Header.ContentType == NcaContentType.Manual && n.Header.TitleId == tid);
            bool Try(Func<IFileSystem> open, string dst) {   // a read over the wrong base does not throw: each file fails the hash check, which Copy lists and goes on; such a read is undone
                int damaged = g_damaged.Count;
                try { Copy(open, dst, null); if (g_damaged.Count == damaged) return true; }
                catch (Exception e) when (e is not KeysMissing and not Refused) { }
                g_damaged.RemoveRange(damaged, g_damaged.Count - damaged);
                if (Directory.Exists(dst)) Directory.Delete(dst, true);
                return false;
            }
            foreach (Nca u in updPkg ?? new List<Nca>()) {
                if (u.Header.ContentType != NcaContentType.Manual || u.Header.TitleId != tid) continue;
                string dst = Path.Combine(a[3], $"html{k}");
                bool patch = u.Header.GetFsHeader(Nca.GetSectionIndexFromType(NcaSectionType.Data, u.Header.ContentType)).IsPatchSection();
                if (!patch) { Copy(() => u.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid), dst, null); k++; }   // a full NCA: its damage is the NSP's
                else if (bases.Exists(b => Try(() => b.OpenFileSystemWithPatch(u, NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid), dst))) { Console.WriteLine($"{dst}: a patch of the base game's NCA"); k++; }
                else Console.WriteLine($"[RED] an HtmlDocument NCA of the update patches none of the base game's: read over each, it fails the hash check");
            }
            foreach (Nca b in bases) {
                // Horizon mounts a sparse NCA only through its patch; read alone, the left-out ranges fail the hash check while its tables open (exit code 3, "the NSP is damaged").
                // Minecraft Dungeons II's base has one (16 KB, the HtmlDocument its update patches), beside its sparse Program NCA
                if (Sparse(b)) { Console.WriteLine($"a sparse HtmlDocument NCA of the base game ({b.Header.NcaSize} bytes): read only through the update's patch, not alone"); continue; }
                Copy(() => b.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid), Path.Combine(a[3], $"html{k++}"), null);
            }
            Console.WriteLine($"{k} HtmlDocument NCAs");
            return Damaged();
        }
        Nca updProg = updPkg == null ? null : Pick(updPkg, NcaContentType.Program, baseProg.Header.TitleId) ?? throw Fail("no Program NCA of the base game's program in the update " + (g_plain ? $"(program {baseProg.Header.TitleId:x16}): the update changes no code of it" : "NSP"));
        Nca ctrl = Pick(updPkg ?? basePkg, NcaContentType.Control, baseProg.Header.TitleId);
        Console.WriteLine($"title {baseProg.Header.TitleId:x16}" + (updProg != null ? $", update {updProg.Header.TitleId:x16}" : ""));
        string outDir = a[3], cmpDir = a.Length > 4 ? a[4] : null;
        if (ctrl != null) {   // control data (NACP): display version and game name; a raw copy goes to <output dir>/control.nacp for naming the app
            byte[] nacp = Nacp(ctrl);
            Directory.CreateDirectory(outDir);
            if (nacp != null) {
                Console.WriteLine($"display version {System.Text.Encoding.ASCII.GetString(nacp, 0x3060, 0x10).TrimEnd('\0')}");
                Console.WriteLine($"name {TitleName(nacp)}");
                Spend(nacp.Length); File.WriteAllBytes(Path.Combine(outDir, "control.nacp"), nacp);
            }
            var (icon, lang) = Icon(ctrl);   // the game icon for the app icon, saved as <output dir>/icon.jpg (build_ipa.sh picks it up)
            if (icon != null) { Spend(icon.Length); File.WriteAllBytes(Path.Combine(outDir, "icon.jpg"), icon); Console.WriteLine($"icon {lang} ({icon.Length} bytes)"); }
            else Console.WriteLine("no icon in the control data");
        }
        if (updProg == null && Sparse(baseProg)) {   // Horizon mounts a sparse NCA only through its patch; alone, the left-out data fails the hash check
            Console.WriteLine("[RED] the base game's program is sparse: it can be read only with its update NSP");
            return 4;
        }
        // Code section: the update's ExeFS is complete; opening it layered over the base gives the same result
        CopyModules(() => updProg != null ? baseProg.OpenFileSystemWithPatch(updProg, NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid) : baseProg.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid), Path.Combine(outDir, "ExeFS"));
        string[] mods = Directory.GetFiles(Path.Combine(outDir, "ExeFS")); Array.Sort(mods, StringComparer.Ordinal);
        foreach (string p in mods) {   // build ID of every NSO module (main, sdk, subsdk*, rtld...)
            if (new FileInfo(p).Length < 0x50) continue;
            byte[] h = new byte[0x50]; using (var f = File.OpenRead(p)) f.ReadExactly(h);
            if (h[0] == 'N' && h[1] == 'S' && h[2] == 'O' && h[3] == '0') Console.WriteLine($"{Path.GetFileName(p)} build id {Convert.ToHexString(h, 0x40, 16).ToLowerInvariant()}");
        }
        // A program can embed all assets in its code modules (ANIMAL WELL 1.0.10).
        // Preserve the extraction layout without asking LibHac to open an absent section.
        if (!baseProg.SectionExists(1) && (updProg == null || !updProg.SectionExists(1))) {
            if (image && !manifest) WriteImage(null, Path.Combine(outDir, "RomFS.img"));
            else if (!manifest) Directory.CreateDirectory(Path.Combine(outDir, "RomFS"));
            if (manifest) File.WriteAllText(Path.Combine(outDir, "romfs_manifest.tsv"), "# path\tbytes\tfirst 32 bytes (hex)\n");
            Console.WriteLine("program has no data section: empty RomFS");
            return Damaged();
        }
        IFileSystem Romfs(IntegrityCheckLevel level) => new RomFsFileSystem(updProg != null ? baseProg.OpenStorageWithPatch(updProg, NcaSectionType.Data, level) : baseProg.OpenStorage(NcaSectionType.Data, level));
        Func<IFileSystem> romfs = () => Romfs(IntegrityCheckLevel.ErrorOnInvalid);
        // the same RomFS without hash checks, for reading damaged files as they are (--allow-damaged)
        g_lenient = () => Romfs(IntegrityCheckLevel.IgnoreOnInvalid);
        if (manifest) Manifest(romfs, Path.Combine(outDir, "romfs_manifest.tsv"));
        else if (image) WriteImage(romfs, Path.Combine(outDir, "RomFS.img"));
        else Copy(romfs, Path.Combine(outDir, "RomFS"), cmpDir);
        return Damaged();
    }

    // Every content meta of each package (the header says what is printed): the NSP script's scan of an NSP folder, one run for all its packages. Only headers and the meta NCAs are read
    static int Contents(KeySet ks, string[] paths) {
        var pkgs = new List<List<Nca>>(); var why = new List<string>();
        foreach (string p in paths) {
            try { pkgs.Add(OpenNsp(ks, p)); why.Add(null); }
            catch (Exception e) when (e is not KeysMissing) { pkgs.Add(null); why.Add(e.Message); }
        }
        var found = new List<(int Rev, string Key, string File)?>();
        for (int i = 0; i < paths.Length; i++) if (pkgs[i] != null) found.Add(MissingKey(ks, pkgs[i].FindAll(m => m.Header.ContentType == NcaContentType.Meta), paths[i]));
        Fit(found);
        int bad = 0;
        for (int i = 0; i < paths.Length; i++) {
            string name = Path.GetFileName(paths[i]);
            Console.WriteLine($"package {i} {name}");
            var lines = new List<string>();
            if (pkgs[i] != null)
                try { foreach (Cnmt c in Metas(pkgs[i])) lines.Add($"content {c.Type} {c.TitleId:x16} {c.TitleVersion.Version}"); }
                catch (Exception e) when (e is not KeysMissing) { why[i] = e.Message; lines.Clear(); }
            if (lines.Count == 0) { Console.WriteLine($"[RED] {name}: {(g_plain ? Esc(why[i]) : why[i]) ?? "no content meta"}"); bad++; }
            foreach (string l in lines) Console.WriteLine(l);
        }
        return bad > 0 ? 5 : 0;
    }

    static int Keys(KeySet ks, string[] paths) {
        var found = new List<(int Rev, string Key, string File)?>();
        foreach (string p in paths) found.Add(MissingKey(ks, OpenNsp(ks, p, ncz: true), p));
        Fit(found);
        Console.WriteLine($"the keys open all {paths.Length} packages");
        return 0;
    }

    // The firmware that brought each master key revision (index = revision; Atmosphère's and hactool's tables), to say which keys a game needs
    static readonly string[] Firmware = { "1.0.0", "3.0.0", "3.0.1", "4.0.0", "5.0.0", "6.0.0", "6.2.0", "7.0.0", "8.1.0", "9.0.0", "9.1.0",
                                          "12.1.0", "13.0.0", "14.0.0", "15.0.0", "16.0.0", "17.0.0", "18.0.0", "19.0.0", "20.0.0", "21.0.0" };
    static readonly string[] KeyAreas = { "application", "ocean", "system" };
    sealed class KeysMissing : Exception { public KeysMissing(string m) : base(m) { } }

    // What the keys lack to open a package's NCAs: the newest key one of them needs (its master key revision and name), or (-1, why) for a rights-ID NCA with no common ticket;
    // null when every NCA opens. The test is LibHac's own (CanOpenSection), the one extraction meets
    static (int Rev, string Key, string File)? MissingKey(KeySet ks, List<Nca> ncas, string path) {
        (int Rev, string Key, string File)? worst = null;
        foreach (Nca n in ncas) {
            bool opens = true;
            for (int i = 0; i < 4; i++) if (n.SectionExists(i) && !n.CanOpenSection(i)) opens = false;
            if (opens) continue;
            int rev = Math.Max(n.Header.KeyGeneration - 1, 0);   // the master key revision, as LibHac takes it from the header's key generation (0 and 1 are both revision 0)
            if (n.Header.HasRightsId && !ks.ExternalKeySet.Contains(new RightsId(n.Header.RightsId))) {
                worst ??= (-1, $"no title key for rights ID {Convert.ToHexString(n.Header.RightsId).ToLowerInvariant()}: the package has no common ticket for it", Path.GetFileName(path));
                continue;
            }
            int area = n.Header.KeyAreaKeyIndex;
            string key = n.Header.HasRightsId ? $"titlekek_{rev:x2}" : $"key_area_key_{(area < KeyAreas.Length ? KeyAreas[area] : area.ToString())}_{rev:x2}";
            if (worst == null || rev > worst.Value.Rev) worst = (rev, key, Path.GetFileName(path));
        }
        return worst;
    }

    // Stops (KeysMissing, exit code 6) on the newest key any of the packages needs, naming the firmware it came with
    static void Fit(IEnumerable<(int Rev, string Key, string File)?> found) {
        (int Rev, string Key, string File)? worst = null; int n = 0;
        foreach (var f in found) if (f != null) { n++; if (worst == null || f.Value.Rev > worst.Value.Rev) worst = f; }
        if (worst == null) return;
        var (rev, key, file) = worst.Value;
        string more = n > 1 ? $" (and {n - 1} more files)" : "";
        if (rev < 0) throw new KeysMissing($"{file}{more}: {key}");
        string fw = rev < Firmware.Length ? $"firmware {Firmware[rev]}" : $"a firmware after {Firmware[^1]}";
        throw new KeysMissing($"{file}{more}: prod.keys has no {key} (master key {rev:x2}, which came with {fw}): the keys are older than the game; " +
                              $"dump prod.keys again from a console on {fw}{(rev < Firmware.Length ? " or later" : "")}");
    }

    static bool Sparse(Nca n) {   // a section on sparse storage, or one the decrypter flattened from it (plain mode: its sparse info is cleared before LibHac reads it)
        if (g_flattened.Contains(n)) return true;
        for (int i = 0; i < 4; i++) if (n.Header.IsSectionEnabled(i) && n.Header.GetFsHeader(i).ExistsSparseLayer()) return true;
        return false;
    }

    // Files whose data failed the hash check: listed at the end; exit code 3 unless --allow-damaged
    static readonly List<string> g_damaged = new List<string>(); static bool g_allow; static Func<IFileSystem> g_lenient; static IFileSystem g_lenientFs;
    static bool HashError(HorizonResultException e) => e.ResultValue.Module == 2 && e.ResultValue.Description >= 4600 && e.ResultValue.Description < 4700;   // fs: integrity verification failures (2002-46xx)
    // Lists a file that failed the hash check and returns a new checked filesystem to read on with. LibHac's CachedStorage takes a block off its list before reading into it and
    // does not put it back when the read fails, so after a few failures its 4 blocks are gone and the next read throws "The LinkedList is empty", which is no hash error.
    static IFileSystem Failed(string path, Func<IFileSystem> open) { g_damaged.Add(path); return open(); }
    static int Damaged() {
        if (g_damaged.Count == 0) return 0;
        foreach (string p in g_damaged) Console.WriteLine($"[RED] hash check failed: {p}");
        if (g_allow) { Console.WriteLine($"[RED] the NSP is damaged: {g_damaged.Count} files written as read (--allow-damaged)"); return 0; }
        Console.WriteLine($"[RED] the NSP is damaged: " +
                          $"{g_damaged.Count} files fail the NCA's hash check (an incomplete copy or a broken download); copy or download it again, or pass --allow-damaged to write them as read");
        return 3;
    }

    // DLC NSP: one data NCA (content type PublicData / Data) + a meta NCA + the ticket; only the data NCA's RomFS is written
    // id: the DLC's title ID, for a merged package that holds several add-on contents (and the base game)
    static int Aoc(KeySet ks, string nsp, string outDir, bool image, ulong? id = null) {
        var pkg = OpenNsp(ks, nsp);   // every NCA: Pick takes the DLC's own data NCA by its title ID
        Fit(new[] { MissingKey(ks, pkg, nsp) });
        Nca data = Pick(pkg, NcaContentType.PublicData, id) ?? Pick(pkg, NcaContentType.Data, id) ?? throw Fail(id == null ? "no data NCA in the DLC NSP" : $"no data NCA of add-on content {id:x16} in {(g_plain ? "the folder" : Path.GetFileName(nsp))}");
        Console.WriteLine($"add-on content {data.Header.TitleId:x16}");
        Directory.CreateDirectory(image ? Path.GetDirectoryName(outDir) : outDir);
        Func<IFileSystem> fs = () => new RomFsFileSystem(data.OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid));
        g_lenient = () => new RomFsFileSystem(data.OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.IgnoreOnInvalid));
        if (image) WriteImage(fs, outDir); else Copy(fs, outDir, null);
        return Damaged();
    }

    // The content metas (*.cnmt in the Meta NCAs) of a package's NCAs
    static IEnumerable<Cnmt> Metas(List<Nca> ncas) {
        foreach (Nca n in ncas) {
            if (n.Header.ContentType != NcaContentType.Meta) continue;
            IFileSystem mfs = n.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
            foreach (DirectoryEntryEx e in mfs.EnumerateEntries("*.cnmt", SearchOptions.Default)) {
                using var f = new UniqueRef<IFile>();
                mfs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                yield return new Cnmt(f.Release().AsStream());
            }
        }
    }

    internal static IStorage PackageStorage(IStorage source) {
        source.GetSize(out long size).ThrowIfFailure();
        if (size < 16) throw new InvalidDataException("truncated PFS0 header");
        byte[] first = new byte[16]; source.Read(0, first).ThrowIfFailure();
        if (!first.AsSpan(0, 4).SequenceEqual("PFS0"u8)) return source;
        uint count = BinaryPrimitives.ReadUInt32LittleEndian(first.AsSpan(4));
        uint strings = BinaryPrimitives.ReadUInt32LittleEndian(first.AsSpan(8));
        long headerSize = 16 + 24L * count + strings;
        if (headerSize > size || headerSize >= int.MaxValue) throw new InvalidDataException("invalid PFS0 file-name table size");
        byte[] header = new byte[(int)headerSize + 1];
        source.Read(0, header.AsSpan(0, (int)headerSize)).ThrowIfFailure();
        for (int i = 0; i < count; i++) {
            uint offset = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(16 + 24 * i + 16));
            if (offset >= strings) throw new InvalidDataException("PFS0 file-name offset outside the string table");
        }
        if (strings == 0 || header[(int)headerSize - 1] == 0) return source;
        // Older NSZ writers omitted the last NUL. Insert it in a virtual header, leaving the source and NCA bytes untouched.
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8), strings + 1);
        Console.WriteLine("PFS0: reading a missing final file-name terminator through an in-memory header");
        return new LibHac.Tools.FsSystem.ConcatenationStorage(new IStorage[] {
            new MemoryStorage(header), new SubStorage(source, headerSize, size - headerSize)
        }, false);
    }

    // Open an NSP (PFS0) or the secure partition of an XCI, import the common tickets, list all NCAs. With a content meta type, only the NCAs that the package's content metas of
    // that type list (when it has one), and with a title ID only that title's: a cartridge dump with its update on it (1G+1U) or a merged NSP holds the update's NCAs beside the
    // base game's, its Program NCA under the same title ID; a cartridge with two games holds two Application content metas. ncz: an NSZ's or XCZ's compressed NCAs too, by their
    // first 0x4000 bytes (the NCA header and section headers, which nsz keeps as they were): enough for the key check, not for reading
    static List<Nca> OpenNsp(KeySet ks, string path, ContentMetaType? only = null, ulong? id = null, bool ncz = false) {
        if (g_plain) return OpenPlain(ks, path, only, id);
        IFileSystem pfs; var st0 = new LocalStorage(path, FileAccess.Read);
        byte[] magic = new byte[4]; st0.Read(0x100, magic).ThrowIfFailure();
        if (System.Text.Encoding.ASCII.GetString(magic) == "HEAD") {   // XCI: the card header's magic at 0x100
            var xci = new Xci(ks, st0);
            if (!xci.HasPartition(XciPartitionType.Secure)) throw new Exception($"no secure partition in {path}");
            pfs = xci.OpenPartition(XciPartitionType.Secure);
        } else {
            var p = new PartitionFileSystem(); p.Initialize(PackageStorage(st0)).ThrowIfFailure(); pfs = p;
        }
        var ncas = new List<Nca>(); var ids = new List<string>();   // ids: content IDs (the file names' hex)
        foreach (DirectoryEntryEx e in pfs.EnumerateEntries("*", SearchOptions.Default)) {
            using var f = new UniqueRef<IFile>();
            pfs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            IStorage st = f.Release().AsStorage();
            if (e.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase)) {
                byte[] t = new byte[0x2c0]; st.Read(0, t).ThrowIfFailure();
                if (t[0x281] != 0) { Console.Error.WriteLine($"[RED] {e.Name} is not a common ticket; supply the title key separately"); continue; }
                ks.ExternalKeySet.Add(new RightsId(t.AsSpan(0x2a0, 0x10)), new AccessKey(t.AsSpan(0x180, 0x10))).ThrowIfFailure();
            } else if (e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase)) { ncas.Add(new Nca(ks, st)); ids.Add(e.Name[..e.Name.IndexOf('.')].ToLowerInvariant()); }
            else if (ncz && e.Name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase)) { ncas.Add(new Nca(ks, st.Slice(0, 0x4000))); ids.Add(e.Name[..e.Name.IndexOf('.')].ToLowerInvariant()); }
        }
        return Filter(ks, ncas, ids, path, only, id);
    }

    // The NCAs (ids: their content IDs) that the package's content metas of type only list, and with a title ID only that title's (see OpenNsp). In plain mode the file names are content
    // IDs by construction, so a Program NCA the content meta lists and the folder lacks is a broken snapshot, not renamed files
    static List<Nca> Filter(KeySet ks, List<Nca> ncas, List<string> ids, string path, ContentMetaType? only, ulong? id) {
        if (only == null) return ncas;
        Fit(new[] { MissingKey(ks, ncas.FindAll(n => n.Header.ContentType == NcaContentType.Meta), path) });   // the content metas are read first, with the same keys
        var listed = new HashSet<string>(); var titles = new List<ulong>(); var programs = new List<string>();   // titles: every content meta of that type, to name them when none is the one asked for
        foreach (Cnmt cnmt in Metas(ncas)) {
            if (cnmt.Type != only) continue;
            titles.Add(cnmt.TitleId);
            if (id == null || cnmt.TitleId == id)
                foreach (CnmtContentEntry c in cnmt.ContentEntries) {
                    string cid = Convert.ToHexString(c.NcaId).ToLowerInvariant();
                    listed.Add(cid);
                    if (c.Type == LibHac.Ncm.ContentType.Program) programs.Add(cid);
                }
        }
        if (id != null && titles.Count > 0 && !titles.Contains(id.Value))
            throw Fail($"{(g_plain ? "the folder" : Path.GetFileName(path))} has no {only} content meta of title {id:x16}; it has {string.Join(", ", titles.ConvertAll(t => t.ToString("x16")))}");
        if (g_plain) {
            if (titles.Count == 0) throw new Refused($"the folder holds no {only} content meta" + (id != null ? $" of title {id:x16}" : ""));
            if (programs.Count == 0)
                throw new Refused(only == ContentMetaType.Patch ? "the update changes no code (its content meta lists no Program NCA): not supported for NCA snapshots yet; pack the base game version"
                                                               : $"its {only} content meta lists no Program NCA");
            foreach (string p in programs) if (!ids.Contains(p)) throw new Refused($"the {only} content meta lists Program NCA {p}, which the folder lacks");
        }
        if (listed.Count == 0) return ncas;
        var kept = new List<Nca>(); int other = 0;   // the meta NCAs list the others, not themselves
        for (int i = 0; i < ncas.Count; i++) if (listed.Contains(ids[i])) kept.Add(ncas[i]); else if (ncas[i].Header.ContentType != NcaContentType.Meta) other++;
        if (!kept.Exists(n => n.Header.ContentType == NcaContentType.Program)) {   // file names that are not content IDs (renamed NCAs): nothing matches, so read every NCA as before
            Console.WriteLine($"[RED] no NCA of {Path.GetFileName(path)} matches its {only} content meta by name (renamed NCA files?); reading all {ncas.Count}");
            return ncas;
        }
        if (other > 0) Console.WriteLine($"leaving out {other} NCAs of {Path.GetFileName(path)} that its {only} content meta does not list (another title in the package: an update on the cartridge, or a merged NSP)");
        return kept;
    }
    // A multi-program application has a Program and a Control NCA per program index (ROMANCE OF THE THREE KINGDOMS 8 REMAKE: its update 1.1.3 adds a whole second program,
    // title ID …0001, beside the game's patch, …0000): with no title ID the lowest one (program index 0, the game), else the NCA of that title ID
    static Nca Pick(List<Nca> l, NcaContentType t, ulong? id = null) {
        Nca r = null;
        foreach (Nca n in l) if (n.Header.ContentType == t && (id == null ? r == null || n.Header.TitleId < r.Header.TitleId : n.Header.TitleId == id)) r = n;
        return r;
    }

    // Icon: the control data holds one 256x256 JPEG per language (/icon_<language>.dat). Use the English one (American, then British); if neither exists, take the first in NACP language order
    static readonly string[] IconLangs = { "AmericanEnglish", "BritishEnglish", "Japanese", "French", "German", "LatinAmericanSpanish", "Spanish", "Italian",
                                           "Dutch", "CanadianFrench", "Portuguese", "Russian", "Korean", "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese" };
    static (byte[], string) Icon(Nca ctrl) {
        IFileSystem fs = ctrl.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        foreach (string lang in IconLangs) {
            using var f = new UniqueRef<IFile>();
            if (fs.OpenFile(ref f.Ref, $"/icon_{lang}.dat".ToU8Span(), OpenMode.Read).IsFailure()) continue;
            f.Get.GetSize(out long n).ThrowIfFailure();
            if (n > IconMax) { Console.WriteLine($"icon {lang} too large ({n:N0} bytes, a game icon is a 256x256 JPEG): not read"); continue; }
            byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure();
            return (v, lang);
        }
        return (null, null);
    }
    static byte[] Nacp(Nca ctrl) {   // the whole control.nacp (0x4000 bytes); null for one of another size (not read, not written)
        IFileSystem fs = ctrl.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        using var f = new UniqueRef<IFile>();
        fs.OpenFile(ref f.Ref, "/control.nacp".ToU8Span(), OpenMode.Read).ThrowIfFailure();
        f.Get.GetSize(out long n).ThrowIfFailure();
        if (n != 0x4000) { Console.WriteLine($"[RED] the control data's control.nacp is {n:N0} bytes, not 16,384: not written"); return null; }
        byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure();
        return v;
    }
    // Game name: the NACP starts with 16 language entries of 0x300 bytes each (name 0x200 + publisher 0x100); take the first non-empty one (0 = American English); DisplayVersion is at 0x3060
    //   NACPs from newer SDKs (such as Mario 1.2.1) compress these 0x3000 bytes: a u16 size + raw deflate, inflating to 32 languages × 0x300. LibHac 0.19 does not know this, so it is decoded here
    static string TitleName(byte[] nacp) {
        byte[] t = nacp; int n = nacp[0] | nacp[1] << 8;
        if (n > 0 && n <= 0x2ffe) try {
            using var z = new System.IO.Compression.DeflateStream(new MemoryStream(nacp, 2, n), System.IO.Compression.CompressionMode.Decompress);
            var m = new MemoryStream(); z.CopyTo(m);
            if (m.Length == 0x6000) t = m.ToArray();   // a wrong length means an uncompressed name that happened to inflate
        } catch (InvalidDataException) { }   // not compressed
        for (int i = 0; i < (t == nacp ? 16 : 32); i++) {
            int z = Array.IndexOf(t, (byte)0, i * 0x300, 0x200), len = (z < 0 ? i * 0x300 + 0x200 : z) - i * 0x300;
            if (len > 0) return System.Text.Encoding.UTF8.GetString(t, i * 0x300, len);
        }
        return "";
    }

    sealed class ImageEntry {
        public string Path; public byte[] Name; public bool Directory, Damaged; public long Size; public ulong A, B;
        public List<ImageEntry> Children = new List<ImageEntry>();
    }
    // Stream the merged, integrity-checked filesystem directly into DMROMFS1. No RomFS directories or per-resource host files are created.
    static void WriteImage(Func<IFileSystem> open, string dst) {
        IFileSystem fs = open?.Invoke();
        var root = new ImageEntry { Path = "/", Name = Array.Empty<byte>(), Directory = true };
        var byPath = new Dictionary<string, ImageEntry>(StringComparer.Ordinal) { ["/"] = root };
        long total = 0;
        if (fs != null) foreach (DirectoryEntryEx e in Entries(fs)) {
            string path = e.FullPath.TrimEnd('/'); if (path.Length == 0) continue;
            if (g_plain && (e.Name.Length == 0 || e.Name == "." || e.Name == ".." || e.Name.Contains('/') || e.Name.Contains('\0'))) throw new Refused($"the RomFS has an invalid name: {Esc(path)}");
            byte[] name = System.Text.Encoding.UTF8.GetBytes(path.Substring(path.LastIndexOf('/') + 1));
            if (name.Length == 0 || name.Length > 0x300) throw new IOException($"invalid RomFS name length: {path}");
            bool dir = e.Type == DirectoryEntryType.Directory;
            if (!dir) total = Sum(total, e.Size, path);
            byPath.Add(path, new ImageEntry { Path = path, Name = name, Directory = dir, Size = e.Size });
        }
        Spend(total);
        foreach (var e in byPath.Values) {
            if (e == root) continue;
            string parent = e.Path.Substring(0, e.Path.LastIndexOf('/')); if (parent.Length == 0) parent = "/";
            byPath[parent].Children.Add(e);
        }
        var entries = new List<ImageEntry> { root };
        for (int i = 0; i < entries.Count; i++) if (entries[i].Directory) {
            var e = entries[i]; e.Children.Sort((a, b) => a.Name.AsSpan().SequenceCompareTo(b.Name));
            e.A = (ulong)entries.Count; e.B = (ulong)e.Children.Count; entries.AddRange(e.Children);
        }
        Directory.CreateDirectory(Path.GetDirectoryName(dst));
        string part = dst + ".part"; long files = 0, bytes = 0; int damaged = g_damaged.Count;
        try {
            using (var output = File.Create(part)) using (var writer = new BinaryWriter(output)) {
                writer.Write(new byte[32]); byte[] buffer = new byte[4 << 20];
                foreach (var e in entries) {
                    if (e.Directory) continue;
                    e.A = (ulong)output.Position; e.B = (ulong)e.Size; files++; bytes += e.Size;
                    using var f = new UniqueRef<IFile>();
                    fs.OpenFile(ref f.Ref, e.Path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                    try { WriteStream(f.Get, output, e.Size, buffer); }
                    catch (HorizonResultException x) when (HashError(x)) {
                        fs = Failed(e.Path, open);
                        if (!g_allow) continue;
                        e.Damaged = true;
                        g_lenientFs ??= g_lenient();
                        using var lf = new UniqueRef<IFile>();
                        g_lenientFs.OpenFile(ref lf.Ref, e.Path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                        output.Position = (long)e.A; output.SetLength(output.Position);
                        WriteStream(lf.Get, output, e.Size, buffer);
                    }
                }
                if (g_damaged.Count == damaged || g_allow) {
                    long index = output.Position; using var names = new MemoryStream();
                    foreach (var e in entries) {
                        writer.Write(e.A); writer.Write(e.B); writer.Write(checked((uint)names.Position));
                        writer.Write(checked((ushort)e.Name.Length)); writer.Write((byte)(e.Directory ? 0 : 1)); writer.Write((byte)(e.Damaged ? 1 : 0));
                        names.Write(e.Name);
                    }
                    names.Position = 0; names.CopyTo(output); long size = output.Position - index;
                    output.Position = 0; writer.Write(System.Text.Encoding.ASCII.GetBytes("DMROMFS1"));
                    writer.Write((ulong)index); writer.Write((ulong)size); writer.Write((ulong)entries.Count);
                }
            }
            if (g_damaged.Count != damaged && !g_allow) { File.Delete(part); return; }
            File.Move(part, dst, true);
            Console.WriteLine($"{dst}: {files} files {bytes / 1048576.0:F1} MB, image with {entries.Count} entries");
        } catch { File.Delete(part); throw; }
    }
    static void WriteStream(IFile file, Stream output, long size, byte[] buffer) {
        for (long offset = 0; offset < size;) {
            file.Read(out long got, offset, buffer.AsSpan(0, (int)Math.Min(buffer.Length, size - offset)), ReadOption.None).ThrowIfFailure();
            if (got <= 0) throw new IOException($"cannot read @{offset}");
            output.Write(buffer, 0, (int)got); offset += got;
        }
    }

    static long Sum(long total, long size, string path) {   // a running total of declared sizes that cannot overflow
        if (size < 0 || size > long.MaxValue - total) throw Fail($"{Esc(path)} declares {size:N0} bytes, more than any file holds");
        return total + size;
    }

    // Copy out file by file; files identical to the same path in the compare dir become APFS clones instead. CopyModules: code modules (plain mode: each at most 1 GiB)
    static void Copy(Func<IFileSystem> open, string dst, string cmpDir) => CopyFiles(open, dst, cmpDir, false);
    static void CopyModules(Func<IFileSystem> open, string dst) => CopyFiles(open, dst, null, true);
    static void CopyFiles(Func<IFileSystem> open, string dst, string cmpDir, bool modules) {
        IFileSystem fs = open();
        long n = 0, cloned = 0, bytes = 0, written = 0; byte[] buf = new byte[4 << 20], cb = new byte[4 << 20];
        var all = new List<DirectoryEntryEx>(Entries(fs)); var names = new HostNames(); long total = 0;
        foreach (DirectoryEntryEx e in all) {   // every name and size checked, and the total spent, before anything is written
            names.Add(e);
            if (e.Type == DirectoryEntryType.Directory) continue;
            if (g_plain && modules && e.Size > ModuleMax) throw new Refused($"the code module {Esc(e.FullPath)} is {e.Size:N0} bytes, larger than any ({ModuleMax:N0} at most)");
            total = Sum(total, e.Size, e.FullPath);
        }
        Spend(total);
        foreach (DirectoryEntryEx e in all) {
            string rel = e.FullPath.TrimStart('/'), op = Path.Combine(dst, rel);
            if (e.Type == DirectoryEntryType.Directory) { Directory.CreateDirectory(op); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(op)); n++; bytes += e.Size;
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            string cp = cmpDir == null ? null : Path.Combine(cmpDir, rel);
            try {
                if (cp != null && File.Exists(cp) && new FileInfo(cp).Length == e.Size && Same(f.Get, cp, e.Size, buf, cb)) {
                    if (File.Exists(op)) File.Delete(op);
                    if (clonefile(cp, op, 0) != 0) throw new IOException($"clonefile {cp} → {op} failed: errno {Marshal.GetLastWin32Error()}");
                    cloned++; continue;
                }
                Write(f.Get, op, e.Size, buf);
            }
            catch (HorizonResultException x) when (HashError(x)) {
                fs = Failed(e.FullPath, open);
                if (!g_allow || g_lenient == null) { File.Delete(op); continue; }
                g_lenientFs ??= g_lenient();
                using var lf = new UniqueRef<IFile>();
                g_lenientFs.OpenFile(ref lf.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                Write(lf.Get, op, e.Size, buf);
            }
            written += e.Size;
        }
        Console.WriteLine($"{dst}: {n} files {bytes / 1048576.0:F1} MB, {cloned} identical to the compare dir (cloned), {written / 1048576.0:F1} MB newly written");
    }
    static void Write(IFile f, string op, long size, byte[] buf) {
        using var o = Create(op);
        for (long off = 0; off < size;) {
            f.Read(out long got, off, buf.AsSpan(0, (int)Math.Min(buf.Length, size - off)), ReadOption.None).ThrowIfFailure();
            if (got <= 0) throw new IOException($"cannot read @{off}");
            o.Write(buf, 0, (int)got); off += got;
        }
    }
    // List the RomFS only (path, size, first 32 bytes) without writing game files, except the NRO modules (code the game loads with nn::ro, read like the ExeFS)
    static void Manifest(Func<IFileSystem> open, string path) {
        IFileSystem fs = open();
        long n = 0, bytes = 0, total = 0; byte[] h = new byte[32];
        var all = new List<DirectoryEntryEx>(Entries(fs)); var names = new HostNames();
        foreach (DirectoryEntryEx e in all) {   // plain mode: a control character would forge rows of the manifest; the NROs written whole are named, sized and spent first
            if (g_plain) foreach (char c in e.FullPath) if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) throw new Refused($"the RomFS name {Esc(e.FullPath)} holds a control character, which the manifest cannot list");
            if (e.Type == DirectoryEntryType.Directory || !e.FullPath.EndsWith(".nro", StringComparison.OrdinalIgnoreCase)) continue;
            names.Add(e);
            if (g_plain && e.Size > ModuleMax) throw new Refused($"the NRO module {Esc(e.FullPath)} is {e.Size:N0} bytes, larger than any ({ModuleMax:N0} at most)");
            total = Sum(total, e.Size, e.FullPath);
        }
        Spend(total);
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        using var o = new StreamWriter(path);
        o.WriteLine("# path\tbytes\tfirst 32 bytes (hex)");
        foreach (DirectoryEntryEx e in all) {
            if (e.Type == DirectoryEntryType.Directory) continue;
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            long got = 0; int want = (int)Math.Min(h.Length, e.Size);
            try { if (want > 0) f.Get.Read(out got, 0, h.AsSpan(0, want), ReadOption.None).ThrowIfFailure(); }
            catch (HorizonResultException x) when (HashError(x)) { fs = Failed(e.FullPath, open); got = 0; }   // the survey goes on; the file is listed as damaged
            o.WriteLine($"{e.FullPath}\t{e.Size}\t{Convert.ToHexString(h, 0, (int)got).ToLowerInvariant()}");
            n++; bytes += e.Size;
            if (got == want && e.FullPath.EndsWith(".nro", StringComparison.OrdinalIgnoreCase)) {
                string op = Path.Combine(Path.GetDirectoryName(path), "romfs_nro", e.FullPath.TrimStart('/'));
                Directory.CreateDirectory(Path.GetDirectoryName(op));
                try { Write(f.Get, op, e.Size, new byte[4 << 20]); } catch (HorizonResultException x) when (HashError(x)) { fs = Failed(e.FullPath, open); File.Delete(op); }
            }
        }
        Console.WriteLine($"{path}: RomFS {n} files {bytes / 1048576.0:F1} MB (manifest only)");
    }
    static bool Same(IFile f, string path, long size, byte[] buf, byte[] cb) {
        using var c = File.OpenRead(path);
        for (long off = 0; off < size;) {
            int want = (int)Math.Min(buf.Length, size - off);
            f.Read(out long got, off, buf.AsSpan(0, want), ReadOption.None).ThrowIfFailure();
            c.ReadExactly(cb, 0, (int)got);
            if (!buf.AsSpan(0, (int)got).SequenceEqual(cb.AsSpan(0, (int)got))) return false;
            off += got;
        }
        return true;
    }
}
