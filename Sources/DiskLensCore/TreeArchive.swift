import Foundation

/// Compact binary serialization of scanned subtrees, used to hand the result
/// of a privileged (root) scan back to the app.
///
/// Format (before zlib compression):
///   magic "DLTA" · version u8 · tree count u32 · per tree: path (string) + node
///   node = kind u8 · flags u8 · size u64 · name (string) · child count u32 · children…
///   string = byte length u32 · UTF-8 bytes
public enum TreeArchive {
    public struct Entry: Sendable {
        public let path: String
        public let kind: FileNode.Kind
        public let children: [FileNode]
        public let restrictedCount: Int
    }

    private static let magic: [UInt8] = Array("DLTA".utf8)
    private static let version: UInt8 = 1

    public static func encode(_ entries: [(path: String, root: FileNode, restrictedCount: Int)]) throws -> Data {
        var writer = Writer()
        writer.bytes(magic)
        writer.u8(version)
        writer.u32(UInt32(entries.count))
        for entry in entries {
            writer.string(entry.path)
            writer.u32(UInt32(clamping: entry.restrictedCount))
            writer.node(entry.root)
        }
        return try (writer.data as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(_ compressed: Data) throws -> [Entry] {
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        var reader = Reader(data: data)
        guard try reader.bytes(4) == magic, try reader.u8() == version else { throw ArchiveError.badFormat }
        let count = try reader.u32()
        var entries: [Entry] = []
        for _ in 0..<count {
            let path = try reader.string()
            let restricted = Int(try reader.u32())
            let root = try reader.node(parent: nil)
            entries.append(Entry(path: path, kind: root.kind, children: root.children, restrictedCount: restricted))
        }
        return entries
    }

    public enum ArchiveError: Error {
        case badFormat
        case truncated
    }

    private struct Writer {
        var data = Data()

        mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ s: String) {
            let utf8 = Array(s.utf8)
            u32(UInt32(utf8.count))
            bytes(utf8)
        }

        mutating func node(_ node: FileNode) {
            // Iterative pre-order walk: deep trees must not overflow the stack.
            var stack: [FileNode] = [node]
            while let current = stack.popLast() {
                u8(current.kind.rawValue)
                u8(current.flags.rawValue)
                u64(current.size)
                string(current.name)
                u32(UInt32(current.children.count))
                stack.append(contentsOf: current.children.reversed())
            }
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(data: Data) { self.data = data }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw ArchiveError.truncated }
            defer { offset += n }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + n])
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }

        mutating func u32() throws -> UInt32 {
            let b = try bytes(4)
            return b.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        mutating func u64() throws -> UInt64 {
            let b = try bytes(8)
            return b.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        }

        mutating func string() throws -> String {
            let length = Int(try u32())
            return String(decoding: try bytes(length), as: UTF8.self)
        }

        mutating func node(parent: FileNode?) throws -> FileNode {
            // Iterative mirror of Writer.node.
            func readOne(parent: FileNode?) throws -> (FileNode, Int) {
                guard let kind = FileNode.Kind(rawValue: try u8()) else { throw ArchiveError.badFormat }
                let flags = FileNode.Flags(rawValue: try u8())
                let size = try u64()
                let name = try string()
                let count = Int(try u32())
                let node = FileNode(name: name, kind: kind, size: size, flags: flags, parent: parent)
                return (node, count)
            }

            let (root, rootCount) = try readOne(parent: parent)
            var stack: [(node: FileNode, remaining: Int)] = [(root, rootCount)]
            var containers: [FileNode] = []
            if rootCount > 0 { containers.append(root) }
            while !stack.isEmpty {
                if stack[stack.count - 1].remaining == 0 {
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].remaining -= 1
                let parentNode = stack[stack.count - 1].node
                let (child, count) = try readOne(parent: parentNode)
                parentNode.children.append(child)
                if count > 0 {
                    stack.append((child, count))
                    containers.append(child)
                }
            }
            // Containers were pushed parents-first; finalize children-first.
            for container in containers.reversed() where container.isContainer {
                container.finalizeFromChildren()
            }
            return root
        }
    }
}
