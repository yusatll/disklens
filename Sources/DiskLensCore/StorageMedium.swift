import DiskArbitration
import Foundation
import IOKit

/// What kind of device a path lives on, to pick the scan strategy:
/// SSDs handle many parallel requests well; spinning disks thrash when
/// several threads seek at once; network volumes are latency bound.
public enum StorageMedium: Sendable, Equatable {
    case solidState
    case rotational
    case network
    case unknown

    public var recommendedThreadCount: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch self {
        case .solidState, .unknown: return max(4, cores)
        case .rotational: return 1
        case .network: return 4
        }
    }

    public var supportsParallelScan: Bool { self != .rotational }

    public static func detect(path: String) -> StorageMedium {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return .unknown }
        if stats.f_flags & UInt32(MNT_LOCAL) == 0 { return .network }

        let device = withUnsafeBytes(of: stats.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard device.hasPrefix("/dev/"),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(device.dropFirst(5)))
        else { return .unknown }

        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return .unknown }
        defer { IOObjectRelease(media) }

        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(
            media, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault, options
        ), let characteristics = property as? [String: Any] else {
            return .unknown
        }
        switch characteristics["Medium Type"] as? String {
        case "Solid State": return .solidState
        case "Rotational": return .rotational
        default: return .unknown
        }
    }
}
