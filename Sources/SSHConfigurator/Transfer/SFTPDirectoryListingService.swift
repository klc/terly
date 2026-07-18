import Foundation

protocol RemoteDirectoryListing: Sendable {
    func listDirectory(alias: String, path: String) async throws -> RemoteDirectorySnapshot
}

final class SFTPDirectoryListingService: RemoteDirectoryListing, @unchecked Sendable {
    private let sftpURL: URL
    private let environment: [String: String]
    private let processClient: any SSHProcessExecuting
    private let timeout: TimeInterval
    private let errorClassifier = SSHErrorClassifier()
    private let parser = SFTPDirectoryListingParser()

    init(
        sftpURL: URL = URL(fileURLWithPath: "/usr/bin/sftp"),
        environment: [String: String] = SSHProcessEnvironment.interactiveAuth(),
        processClient: any SSHProcessExecuting = SSHProcessClient(),
        timeout: TimeInterval = 20
    ) {
        self.sftpURL = sftpURL
        self.environment = environment
        self.processClient = processClient
        self.timeout = timeout
    }

    func listDirectory(alias: String, path: String) async throws -> RemoteDirectorySnapshot {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias) else {
            throw RemoteFileBrowserError.invalidAlias
        }

        let normalizedPath = try Self.validatedPath(path)

        let commandPath: String
        if normalizedPath == "~" {
            commandPath = "."
        } else if normalizedPath.hasPrefix("~/") {
            commandPath = String(normalizedPath.dropFirst(2))
        } else {
            commandPath = normalizedPath
        }

        let batch = "@cd \(try quoted(commandPath))\n@pwd\n@ls -lan .\n"
        let output = try await execute(alias: normalizedAlias, batch: batch)
        return try parser.parse(output: output, requestedPath: normalizedPath)
    }

    private func execute(
        alias: String,
        batch: String,
        sftpCommand: SFTPOperationKind? = nil
    ) async throws -> String {
        let result: SSHProcessResult
        do {
            result = try await processClient.execute(SSHProcessRequest(
                executableURL: sftpURL,
                arguments: ["-q", "-b", "-", "--", alias],
                environment: environment,
                standardInput: Data(batch.utf8),
                timeout: timeout
            ))
        } catch let error as SSHProcessClientError {
            throw RemoteFileBrowserError.processFailed(errorClassifier.classify(
                output: "",
                processError: error,
                sftpCommand: sftpCommand
            ).userFacingDescription)
        }
        guard result.terminationStatus == 0 else {
            throw RemoteFileBrowserError.processFailed(
                errorClassifier.classify(
                    output: result.combinedOutput,
                    sftpCommand: sftpCommand
                ).userFacingDescription
            )
        }
        return result.standardOutput
    }

    /// Creates a directory at `path` on the remote host using sftp `mkdir`.
    /// - Throws: `RemoteFileBrowserError` if the alias or path is invalid, or the command fails.
    func createDirectory(alias: String, path: String) async throws {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias) else {
            throw RemoteFileBrowserError.invalidAlias
        }

        let normalizedPath = try Self.validatedPath(path)

        // sftp batch: plain mkdir — OpenSSH sftp does not support -p.
        // If the directory already exists the error is reported back to the caller.
        let batch = "mkdir \(try quoted(normalizedPath))\n"
        _ = try await execute(alias: normalizedAlias, batch: batch, sftpCommand: .createDirectory)
    }

    /// Renames (moves) `sourcePath` to `destinationPath` on the remote host using sftp
    /// `rename`. This is the non-overwriting SFTP v3 `rename` (not the `posix-rename@openssh.com`
    /// extension), so it fails if `destinationPath` already exists rather than replacing it.
    /// - Throws: `RemoteFileBrowserError` if the alias or either path is invalid, or the command fails.
    func rename(alias: String, from sourcePath: String, to destinationPath: String) async throws {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias) else {
            throw RemoteFileBrowserError.invalidAlias
        }

        let normalizedSource = try Self.validatedPath(sourcePath)
        let normalizedDestination = try Self.validatedPath(destinationPath)

        let batch = "rename \(try quoted(normalizedSource)) \(try quoted(normalizedDestination))\n"
        _ = try await execute(alias: normalizedAlias, batch: batch, sftpCommand: .rename)
    }

    /// Deletes a remote file, symbolic link, or empty directory.
    ///
    /// Directories are removed with sftp `rmdir`, which only ever removes an **empty**
    /// directory — there is no recursive delete in this app by design (deliberately out
    /// of scope: too easy to trigger by accident on a remote host). If the directory is
    /// not empty, the resulting error is classified and surfaced to the caller as
    /// "Klasör boş değil" rather than a raw sftp failure code.
    ///
    /// Files and symbolic links are removed with sftp `rm` (which unlinks the link
    /// itself, not its target).
    /// - Throws: `RemoteFileBrowserError` if the alias or path is invalid, or the command fails.
    func delete(alias: String, path: String, kind: RemoteFileKind) async throws {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias) else {
            throw RemoteFileBrowserError.invalidAlias
        }

        let normalizedPath = try Self.validatedPath(path)
        let command = kind == .directory ? "rmdir" : "rm"
        let sftpCommand: SFTPOperationKind = kind == .directory ? .removeDirectory : .remove

        let batch = "\(command) \(try quoted(normalizedPath))\n"
        _ = try await execute(alias: normalizedAlias, batch: batch, sftpCommand: sftpCommand)
    }

    /// Trims a remote path and rejects the same set of characters that would break the
    /// single-line sftp batch protocol or a POSIX path outright.
    private static func validatedPath(_ path: String) throws -> String {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty,
              !normalizedPath.contains("\n"),
              !normalizedPath.contains("\r"),
              !normalizedPath.contains("\0") else {
            throw RemoteFileBrowserError.invalidPath
        }
        return normalizedPath
    }

    /// Quotes `path` for embedding in an sftp batch command, mapping the quoter's
    /// (redundant, but defense-in-depth) newline guard onto `RemoteFileBrowserError`.
    private func quoted(_ path: String) throws -> String {
        do {
            return try SFTPBatchPathQuoting.quote(path)
        } catch is SFTPBatchPathQuoting.EmbeddedNewlineError {
            throw RemoteFileBrowserError.invalidPath
        }
    }
}


struct SFTPDirectoryListingParser {
    func parse(output: String, requestedPath: String) throws -> RemoteDirectorySnapshot {
        let lines = output.components(separatedBy: .newlines)
        let pathPrefix = "Remote working directory: "
        let canonicalPath = lines
            .first { $0.hasPrefix(pathPrefix) }
            .map { String($0.dropFirst(pathPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? requestedPath

        let entries = lines.compactMap { line -> RemoteFileEntry? in
            let fields = line.split(
                maxSplits: 8,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            ).map(String.init)
            guard fields.count == 9, fields[0].count >= 10 else { return nil }

            let kind: RemoteFileKind
            switch fields[0].first {
            case "d":
                kind = .directory
            case "-":
                kind = .file
            case "l":
                kind = .symbolicLink
            default:
                return nil
            }

            var name = fields[8]
            if kind == .symbolicLink, let arrowRange = name.range(of: " -> ") {
                name = String(name[..<arrowRange.lowerBound])
            }
            if name.hasPrefix("./") {
                name.removeFirst(2)
            }
            guard name != ".", name != ".." else { return nil }

            return RemoteFileEntry(
                name: name,
                path: RemotePath.appending(name, to: canonicalPath),
                kind: kind,
                size: Int64(fields[4]),
                modificationDescription: "\(fields[5]) \(fields[6]) \(fields[7])"
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory { return true }
            if lhs.kind != .directory, rhs.kind == .directory { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        guard canonicalPath.hasPrefix("/") else {
            throw RemoteFileBrowserError.unreadableListing
        }
        return RemoteDirectorySnapshot(path: canonicalPath, entries: entries)
    }
}
