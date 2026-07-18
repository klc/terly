import Darwin
import Foundation
import SSHConfigCore

/// A single file that belongs in the sync repo, alongside the path it lives
/// at inside that repo (stable across machines so import can map it back).
struct SyncFile: Equatable, Sendable, Hashable {
    let sourceURL: URL
    let relativePath: String
}

struct SyncSetWarning: Equatable, Sendable {
    let message: String
}

struct SyncSet: Equatable, Sendable {
    var files: [SyncFile]
    var warnings: [SyncSetWarning]
}

/// Enumerates exactly what WP10 is allowed to sync: `~/.ssh/config`, the
/// files it (transitively) `Include`s — bounded to `~/.ssh` and to a finite
/// recursion depth — and a fixed list of the app's own JSON stores.
/// Deliberately excludes private key contents, transfer history, workspace
/// layout, `known_hosts`, and the local Backups directory — none of those
/// are ever looked at here.
struct SyncSetResolver: Sendable {
    static let maxIncludeDepth = 8
    static let appDataFileNames = [
        "startup-flows.json",
        "quick-access.json",
        "auto-reconnect.json",
        "tunnels.json",
        "runbooks.json",
        "snippets.json",
    ]

    let sshDirectoryURL: URL
    let appSupportDirectoryURL: URL

    init(
        sshDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true),
        appSupportDirectoryURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terly", isDirectory: true)
    ) {
        self.sshDirectoryURL = sshDirectoryURL
        self.appSupportDirectoryURL = appSupportDirectoryURL
    }

    func resolve() -> SyncSet {
        var files: [SyncFile] = []
        var warnings: [SyncSetWarning] = []
        var visited = Set<String>()

        let configURL = sshDirectoryURL.appendingPathComponent("config", isDirectory: false)
        if FileManager.default.fileExists(atPath: configURL.path) {
            files.append(SyncFile(sourceURL: configURL, relativePath: "ssh/config"))
            visited.insert(standardizedPath(configURL))
            resolveIncludes(from: configURL, depth: 0, files: &files, warnings: &warnings, visited: &visited)
        }

        for name in Self.appDataFileNames {
            let url = appSupportDirectoryURL.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            files.append(SyncFile(sourceURL: url, relativePath: "app/\(name)"))
        }

        return SyncSet(files: files, warnings: warnings)
    }

    private func resolveIncludes(
        from fileURL: URL,
        depth: Int,
        files: inout [SyncFile],
        warnings: inout [SyncSetWarning],
        visited: inout Set<String>
    ) {
        guard depth < Self.maxIncludeDepth else {
            warnings.append(SyncSetWarning(
                message: "Include zinciri \(Self.maxIncludeDepth) seviyeden derin, gerisi atlandı: \(fileURL.path)"
            ))
            return
        }
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let document = SSHConfigDocument(source: source)

        for include in document.includes {
            for pattern in Self.splitIncludeValue(include.value) {
                for candidate in expand(pattern: pattern) {
                    guard isContained(candidate) else {
                        warnings.append(SyncSetWarning(
                            message: "Include ~/.ssh dışına çıkıyor, atlandı: \(candidate.path)"
                        ))
                        continue
                    }
                    let standardized = standardizedPath(candidate)
                    guard !visited.contains(standardized) else { continue }
                    visited.insert(standardized)

                    guard FileManager.default.fileExists(atPath: candidate.path), !isDirectory(candidate) else { continue }

                    guard !Self.isSensitiveFilename(candidate) else {
                        warnings.append(SyncSetWarning(
                            message: "Include özel anahtar/known_hosts benzeri bir dosyaya işaret ediyor, atlandı: \(candidate.path)"
                        ))
                        continue
                    }

                    let relative = relativeSSHPath(for: candidate)
                    files.append(SyncFile(sourceURL: candidate, relativePath: "ssh/\(relative)"))
                    resolveIncludes(from: candidate, depth: depth + 1, files: &files, warnings: &warnings, visited: &visited)
                }
            }
        }
    }

    /// Belt-and-suspenders on top of the fixed app-store allowlist and the
    /// `~/.ssh` containment check: an `Include` glob (e.g. `Include *` or
    /// `Include id_*`) could otherwise pull private key material or
    /// `known_hosts` into the sync set purely by name-matching a file that
    /// happens to sit next to `config`. This makes that exclusion structural
    /// rather than just "nobody would write that Include line".
    private static let sensitiveFilenamePrefixes = ["id_"]
    private static let sensitiveFilenameSuffixes = ["_rsa", "_ed25519", "_ecdsa", "_dsa", ".pem", ".pub"]
    private static let sensitiveFilenameExactNames = ["known_hosts", "known_hosts.old", "authorized_keys"]

    private static func isSensitiveFilename(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if sensitiveFilenameExactNames.contains(name) { return true }
        if sensitiveFilenamePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if sensitiveFilenameSuffixes.contains(where: { name.hasSuffix($0) }) { return true }
        return false
    }

    /// Splits an `Include` directive's value into individual patterns,
    /// honoring double-quoted segments the way `ssh_config` does (so a
    /// quoted pattern containing whitespace isn't split apart).
    static func splitIncludeValue(_ value: String) -> [String] {
        var patterns: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    patterns.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { patterns.append(current) }
        return patterns
    }

    private func absolutePattern(for pattern: String) -> String {
        if pattern.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + "/" + pattern.dropFirst(2)
        }
        if pattern.hasPrefix("/") {
            return pattern
        }
        return sshDirectoryURL.path + "/" + pattern
    }

    /// Expands a glob pattern using libc `glob(3)` — the same matching
    /// OpenSSH's own `Include` directive relies on, so results line up with
    /// what `ssh` would actually read.
    private func expand(pattern: String) -> [URL] {
        let absolute = absolutePattern(for: pattern)
        var globResult = glob_t()
        defer { globfree(&globResult) }
        let returnCode = absolute.withCString { cString in
            Darwin.glob(cString, GLOB_TILDE | GLOB_NOSORT, nil, &globResult)
        }
        guard returnCode == 0, globResult.gl_matchc > 0, let pathList = globResult.gl_pathv else { return [] }

        var results: [URL] = []
        for index in 0 ..< Int(globResult.gl_matchc) {
            guard let cPath = pathList[index] else { continue }
            results.append(URL(fileURLWithPath: String(cString: cPath)))
        }
        return results
    }

    private func isContained(_ url: URL) -> Bool {
        let resolvedRoot = standardizedPath(sshDirectoryURL)
        let resolvedCandidate = standardizedPath(url)
        return resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }

    private func relativeSSHPath(for url: URL) -> String {
        let resolvedRoot = standardizedPath(sshDirectoryURL)
        let resolvedCandidate = standardizedPath(url)
        guard resolvedCandidate.hasPrefix(resolvedRoot + "/") else { return url.lastPathComponent }
        return String(resolvedCandidate.dropFirst(resolvedRoot.count + 1))
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func standardizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
