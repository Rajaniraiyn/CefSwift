import Foundation

/// The load commands of a Mach-O file that bundling depends on: each
/// architecture's deployment target, the libraries it loads, its run-path
/// search list and its install name. Read from the file's bytes, so the
/// plugin and the tests need no `otool`.
struct MachOFile: Equatable, Sendable {
    struct Slice: Equatable, Sendable {
        var architecture: String
        /// `LC_BUILD_VERSION` (or `LC_VERSION_MIN_MACOSX`) minimum OS.
        var minimumSystemVersion: String?
        /// `LC_ID_DYLIB`, for a library.
        var installName: String?
        /// `LC_LOAD_DYLIB` and its weak, re-export, lazy and upward forms.
        var loadedLibraries: [String] = []
        /// `LC_RPATH`, in search order.
        var runPaths: [String] = []
    }

    var slices: [Slice]

    var architectures: [String] { slices.map(\.architecture) }

    init(slices: [Slice]) { self.slices = slices }

    /// Reads `url`; nil when it is not a Mach-O file.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        let reader = Reader(data: data)
        switch reader.uint32(0, bigEndian: true) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // Universal: big-endian fat_arch (or fat_arch_64) entries.
            let is64 = reader.uint32(0, bigEndian: true) == 0xCAFE_BABF
            guard let count = reader.uint32(4, bigEndian: true), count > 0, count < 32 else { return nil }
            var slices: [Slice] = []
            for index in 0..<Int(count) {
                let entry = 8 + index * (is64 ? 32 : 20)
                let offset = is64
                    ? reader.uint64(entry + 8, bigEndian: true).map(Int.init)
                    : reader.uint32(entry + 8, bigEndian: true).map(Int.init)
                guard let offset, let slice = Self.slice(reader, at: offset) else { return nil }
                slices.append(slice)
            }
            self.slices = slices
        default:
            guard let slice = Self.slice(reader, at: 0) else { return nil }
            slices = [slice]
        }
    }

    private static func slice(_ reader: Reader, at base: Int) -> Slice? {
        let magic = reader.uint32(base)
        guard magic == 0xFEED_FACF || magic == 0xFEED_FACE,
              let cpuType = reader.uint32(base + 4), let cpuSubtype = reader.uint32(base + 8),
              let commandCount = reader.uint32(base + 16) else { return nil }
        var slice = Slice(architecture: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype))
        var offset = base + (magic == 0xFEED_FACF ? 32 : 28)
        for _ in 0..<commandCount {
            guard let command = reader.uint32(offset), let size = reader.uint32(offset + 4), size >= 8 else {
                return nil
            }
            func string(at field: Int) -> String? {
                reader.uint32(offset + field).flatMap { reader.cString(offset + Int($0), limit: offset + Int(size)) }
            }
            switch command {
            case 0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023:
                // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
                // LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB
                if let name = string(at: 8) { slice.loadedLibraries.append(name) }
            case 0xD:  // LC_ID_DYLIB
                slice.installName = string(at: 8)
            case 0x8000_001C:  // LC_RPATH
                if let path = string(at: 8) { slice.runPaths.append(path) }
            case 0x32:  // LC_BUILD_VERSION: cmd, cmdsize, platform, minos
                slice.minimumSystemVersion = reader.uint32(offset + 12).map(formatVersion)
            case 0x24:  // LC_VERSION_MIN_MACOSX: cmd, cmdsize, version
                slice.minimumSystemVersion = reader.uint32(offset + 8).map(formatVersion)
            default:
                break
            }
            offset += Int(size)
        }
        return slice
    }

    static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        switch cpuType {
        case 0x0100_000C: return cpuSubtype & 0xFF == 2 ? "arm64e" : "arm64"
        case 0x0100_0007: return "x86_64"
        case 0x7: return "i386"
        default: return "cputype \(cpuType)"
        }
    }

    /// `xxxx.yy.zz` nibbles as "major.minor[.patch]".
    static func formatVersion(_ version: UInt32) -> String {
        let major = version >> 16, minor = (version >> 8) & 0xFF, patch = version & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Whether a library path names part of macOS, which every Mac has
    /// (most of it only in the dyld shared cache).
    static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/")
    }

    private struct Reader {
        let data: Data

        func uint32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let value = data[data.startIndex + offset ..< data.startIndex + offset + 4]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
        }

        func uint64(_ offset: Int, bigEndian: Bool = false) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            let value = data[data.startIndex + offset ..< data.startIndex + offset + 8]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            return bigEndian ? UInt64(bigEndian: value) : UInt64(littleEndian: value)
        }

        func cString(_ offset: Int, limit: Int) -> String? {
            let end = min(limit, data.count)
            guard offset >= 0, offset < end else { return nil }
            let bytes = data[data.startIndex + offset ..< data.startIndex + end]
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
