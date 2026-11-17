import Foundation

/// Work done with administrator (root) privileges.
///
/// The app writes a JSON request into a private temporary directory and runs
/// its own executable as root (`--privileged <request.json>`) through the
/// standard macOS administrator authentication dialog. The root process
/// performs the request and writes the response next to it; the app reads it
/// back. Results of privileged scans travel as a `TreeArchive`.
public enum Privileged {
    public struct Request: Codable, Sendable {
        public enum Command: String, Codable, Sendable {
            case scan
            case delete
            case deleteSnapshots
        }

        public var command: Command
        public var paths: [String] = []
        public var useAllocatedSize: Bool = true
        /// For `.delete`: remove what can be removed and report protected
        /// leftovers instead of failing (System Data cleanup).
        public var bestEffort: Bool = false
        /// For `.deleteSnapshots`: each entry is one shell command (argv).
        public var commands: [[String]] = []
        /// Owner the response files are handed to (the requesting user).
        public var ownerUID: UInt32 = getuid()
        public var ownerGID: UInt32 = getgid()

        public init(command: Command) { self.command = command }
    }

    public struct Response: Codable, Sendable {
        public var failures: [String: String] = [:]
        public var archiveFile: String?
        /// Paths root couldn't read either because macOS privacy protection
        /// (TCC/SIP) blocks them. Not an error: only Full Disk Access helps.
        public var protectedPaths: [String] = []
    }

    // MARK: Root side

    /// Entry point of the root process. Returns the process exit code.
    public static func runHelper(requestPath: String) -> Int32 {
        let directory = (requestPath as NSString).deletingLastPathComponent
        guard let data = FileManager.default.contents(atPath: requestPath),
              let request = try? JSONDecoder().decode(Request.self, from: data)
        else { return 2 }

        var response = Response()
        switch request.command {
        case .scan:
            var options = ScanOptions()
            options.useAllocatedSize = request.useAllocatedSize
            options.excludedPaths = ScanOptions.defaultExcludedPaths
            let scanner = DiskScanner(options: options)
            var entries: [(path: String, root: FileNode, restrictedCount: Int)] = []
            for path in request.paths {
                do {
                    let result = try scanner.scanBlocking(path: path)
                    entries.append((path, result.root, result.restrictedDirectoryCount))
                } catch ScanError.cannotOpen(_, let code) where code == EPERM {
                    response.protectedPaths.append(path)
                } catch ScanError.cannotOpen(_, let code) where code == ENOENT {
                    // Gone since the scan; nothing to report.
                } catch {
                    response.failures[path] = error.localizedDescription
                }
            }
            let archivePath = (directory as NSString).appendingPathComponent("result.dlta")
            do {
                try TreeArchive.encode(entries).write(to: URL(fileURLWithPath: archivePath))
                chown(archivePath, request.ownerUID, request.ownerGID)
                response.archiveFile = archivePath
            } catch {
                response.failures["archive"] = error.localizedDescription
            }

        case .delete:
            if request.bestEffort {
                var outcome = SystemDataCleaner.Outcome()
                for path in request.paths {
                    SystemDataCleaner.removeAsMuchAsPossible(path, fm: FileManager.default, outcome: &outcome)
                }
                response.failures = outcome.failures
                response.protectedPaths = outcome.protectedPaths
            } else {
                for path in request.paths {
                    do {
                        try FileManager.default.removeItem(atPath: path)
                    } catch {
                        response.failures[path] = error.localizedDescription
                    }
                }
            }

        case .deleteSnapshots:
            for argv in request.commands where !argv.isEmpty {
                let output = run(argv)
                if output.status != 0 {
                    response.failures[argv.joined(separator: " ")] = output.text.isEmpty ? "exit \(output.status)" : output.text
                }
            }
        }

        let responsePath = (directory as NSString).appendingPathComponent("response.json")
        if let encoded = try? JSONEncoder().encode(response) {
            FileManager.default.createFile(atPath: responsePath, contents: encoded)
            chown(responsePath, request.ownerUID, request.ownerGID)
        }
        return 0
    }

    /// Runs an allowed snapshot command as the current user (Time Machine
    /// snapshots can usually be deleted without root). True on success.
    public static func runWithoutPrivileges(_ argv: [String]) -> Bool {
        !argv.isEmpty && run(argv).status == 0
    }

    private static func run(_ argv: [String]) -> (status: Int32, text: String) {
        // Only the two snapshot tools are allowed, so a tampered request can't run arbitrary commands.
        guard ["/usr/bin/tmutil", "/usr/sbin/diskutil"].contains(argv[0]) else { return (126, "command not allowed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, error.localizedDescription)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: App side

    public enum ClientError: Error, LocalizedError {
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Administrator authorization was cancelled.")
            case let .failed(message): return message
            }
        }
    }

    /// Runs `request` as root and returns the response and the decoded archive (for scans).
    /// Shows the system's administrator password dialog.
    public static func perform(_ request: Request, executablePath: String, prompt: String) async throws -> (Response, [TreeArchive.Entry]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)

        let script = """
        do shell script (quoted form of \(appleScriptString(executablePath))) & " --privileged " & \
        (quoted form of \(appleScriptString(requestURL.path))) with prompt \(appleScriptString(prompt)) \
        with administrator privileges
        """

        let (status, output) = try await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = Pipe()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value

        if status != 0 {
            if output.contains("-128") { throw ClientError.cancelled }
            throw ClientError.failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let responseURL = directory.appendingPathComponent("response.json")
        guard let responseData = try? Data(contentsOf: responseURL),
              let response = try? JSONDecoder().decode(Response.self, from: responseData)
        else { throw ClientError.failed(String(localized: "The privileged helper did not produce a result.")) }

        var entries: [TreeArchive.Entry] = []
        if let archive = response.archiveFile {
            entries = try TreeArchive.decode(Data(contentsOf: URL(fileURLWithPath: archive)))
        }
        return (response, entries)
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
