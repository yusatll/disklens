import Darwin

/// One entry returned by `getattrlistbulk`.
struct BulkEntry {
    enum ObjectType {
        case regular, directory, symlink, other
    }

    var name: String
    var type: ObjectType
    var fileID: UInt64
    var devID: Int32
    var linkCount: UInt32
    var allocatedSize: UInt64
    var logicalSize: UInt64
    /// Directory is a mount point or an autofs trigger.
    var isMountPoint: Bool
    var isDataless: Bool
    var error: Int32
    /// APFS clone family ID and how many files share its blocks (0 if unknown).
    var cloneID: UInt64 = 0
    var cloneRefCount: UInt32 = 0
}

/// Reads whole directories with `getattrlistbulk(2)`: one syscall returns
/// name, type, IDs and sizes for many entries at once, which is much faster
/// than `readdir` + `lstat` per entry.
///
/// Not thread-safe; each worker thread owns one reader (and its buffer).
final class BulkDirectoryReader {
    // sys/attr.h constants (defined here because large values import awkwardly).
    private static let ATTR_CMN_NAME: UInt32 = 0x0000_0001
    private static let ATTR_CMN_DEVID: UInt32 = 0x0000_0002
    private static let ATTR_CMN_OBJTYPE: UInt32 = 0x0000_0008
    private static let ATTR_CMN_FLAGS: UInt32 = 0x0004_0000
    private static let ATTR_CMN_FILEID: UInt32 = 0x0200_0000
    private static let ATTR_CMN_ERROR: UInt32 = 0x2000_0000
    private static let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
    private static let ATTR_DIR_MOUNTSTATUS: UInt32 = 0x0000_0004
    private static let DIR_MNTSTATUS_MNTPOINT: UInt32 = 0x0000_0001
    private static let DIR_MNTSTATUS_TRIGGER: UInt32 = 0x0000_0002
    private static let ATTR_FILE_LINKCOUNT: UInt32 = 0x0000_0001
    private static let ATTR_FILE_TOTALSIZE: UInt32 = 0x0000_0002
    private static let ATTR_FILE_ALLOCSIZE: UInt32 = 0x0000_0004
    private static let SF_DATALESS: UInt32 = 0x4000_0000
    private static let ATTR_CMNEXT_CLONEID: UInt32 = 0x0000_0100
    private static let ATTR_CMNEXT_CLONE_REFCNT: UInt32 = 0x0000_1000
    private static let FSOPT_ATTR_CMN_EXTENDED: UInt64 = 0x0000_0020

    private static let VREG: UInt32 = 1
    private static let VDIR: UInt32 = 2
    private static let VLNK: UInt32 = 5

    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    /// Ask for APFS clone info. Turned off automatically for file systems that reject it.
    var requestCloneInfo = true

    init(capacity: Int = 256 * 1024) {
        self.capacity = capacity
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    /// Calls `body` for every entry in `path`. Returns 0 on success or an errno.
    func read(path: String, _ body: (BulkEntry) -> Void) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return errno }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.ATTR_CMN_RETURNED_ATTRS | Self.ATTR_CMN_NAME | Self.ATTR_CMN_DEVID
            | Self.ATTR_CMN_OBJTYPE | Self.ATTR_CMN_FLAGS | Self.ATTR_CMN_FILEID | Self.ATTR_CMN_ERROR
        request.dirattr = Self.ATTR_DIR_MOUNTSTATUS
        request.fileattr = Self.ATTR_FILE_LINKCOUNT | Self.ATTR_FILE_TOTALSIZE | Self.ATTR_FILE_ALLOCSIZE
        var options: UInt64 = 0
        if requestCloneInfo {
            request.forkattr = Self.ATTR_CMNEXT_CLONEID | Self.ATTR_CMNEXT_CLONE_REFCNT
            options = Self.FSOPT_ATTR_CMN_EXTENDED
        }

        var first = true
        while true {
            var count = getattrlistbulk(fd, &request, buffer, capacity, options)
            if count < 0 && first && errno == EINVAL && options != 0 {
                // File system without extended common attributes (HFS+, FAT, SMB …).
                requestCloneInfo = false
                request.forkattr = 0
                options = 0
                count = getattrlistbulk(fd, &request, buffer, capacity, options)
            }
            first = false
            if count < 0 { return errno }
            if count == 0 { return 0 }

            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                if let entry = Self.parse(entryStart) {
                    body(entry)
                }
                entryStart += length
            }
        }
    }

    /// Parses one packed entry. Attributes appear in bitmap order, and only
    /// those flagged in the returned attribute set are present.
    private static func parse(_ start: UnsafeRawPointer) -> BulkEntry? {
        var p = start + MemoryLayout<UInt32>.size // skip length

        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        var entry = BulkEntry(name: "", type: .other, fileID: 0, devID: 0, linkCount: 1,
                              allocatedSize: 0, logicalSize: 0, isMountPoint: false,
                              isDataless: false, error: 0)

        let common = returned.commonattr
        if common & ATTR_CMN_NAME != 0 {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            let namePtr = (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            entry.name = String(cString: namePtr)
            p += MemoryLayout<attrreference_t>.size
        }
        if common & ATTR_CMN_DEVID != 0 {
            entry.devID = p.loadUnaligned(as: Int32.self)
            p += MemoryLayout<Int32>.size
        }
        if common & ATTR_CMN_OBJTYPE != 0 {
            switch p.loadUnaligned(as: UInt32.self) {
            case VREG: entry.type = .regular
            case VDIR: entry.type = .directory
            case VLNK: entry.type = .symlink
            default: entry.type = .other
            }
            p += MemoryLayout<UInt32>.size
        }
        if common & ATTR_CMN_FLAGS != 0 {
            let flags = p.loadUnaligned(as: UInt32.self)
            entry.isDataless = flags & SF_DATALESS != 0
            p += MemoryLayout<UInt32>.size
        }
        if common & ATTR_CMN_FILEID != 0 {
            entry.fileID = p.loadUnaligned(as: UInt64.self)
            p += MemoryLayout<UInt64>.size
        }
        if common & ATTR_CMN_ERROR != 0 {
            entry.error = Int32(bitPattern: p.loadUnaligned(as: UInt32.self))
            p += MemoryLayout<UInt32>.size
        }

        if returned.dirattr & ATTR_DIR_MOUNTSTATUS != 0 {
            let status = p.loadUnaligned(as: UInt32.self)
            entry.isMountPoint = status & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
            p += MemoryLayout<UInt32>.size
        }

        let file = returned.fileattr
        if file & ATTR_FILE_LINKCOUNT != 0 {
            entry.linkCount = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
        }
        if file & ATTR_FILE_TOTALSIZE != 0 {
            entry.logicalSize = UInt64(max(0, p.loadUnaligned(as: Int64.self)))
            p += MemoryLayout<Int64>.size
        }
        if file & ATTR_FILE_ALLOCSIZE != 0 {
            entry.allocatedSize = UInt64(max(0, p.loadUnaligned(as: Int64.self)))
            p += MemoryLayout<Int64>.size
        }

        let extended = returned.forkattr
        if extended & ATTR_CMNEXT_CLONEID != 0 {
            entry.cloneID = p.loadUnaligned(as: UInt64.self)
            p += MemoryLayout<UInt64>.size
        }
        if extended & ATTR_CMNEXT_CLONE_REFCNT != 0 {
            entry.cloneRefCount = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
        }

        if entry.name.isEmpty || entry.name == "." || entry.name == ".." { return nil }
        return entry
    }
}
