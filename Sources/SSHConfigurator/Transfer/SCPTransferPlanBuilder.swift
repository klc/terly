import Foundation

struct SCPTransferPlanBuilder {
    let scpURL: URL
    let baseEnvironment: [String: String]
    let currentDirectoryURL: URL?
    let fileManager: FileManager

    init(
        scpURL: URL = URL(fileURLWithPath: "/usr/bin/scp"),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL? = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.scpURL = scpURL
        self.baseEnvironment = baseEnvironment
        self.currentDirectoryURL = currentDirectoryURL
        self.fileManager = fileManager
    }

    func makePlan(for request: SCPTransferRequest) throws -> SCPTransferPlan {
        let alias = try normalizedAlias(request.alias)
        let remotePath = try normalizedRemotePath(request.remotePath)
        let localURL = request.localURL.standardizedFileURL

        switch request.direction {
        case .upload:
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
                throw SCPTransferError.missingLocalFile
            }
            if isDirectory.boolValue && !request.isDirectory {
                throw SCPTransferError.localFileIsDirectory
            }
        case .download:
            let destinationDirectory = request.isDirectory
                ? localURL
                : localURL.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SCPTransferError.missingDestinationDirectory
            }
        }

        let environment = SSHProcessEnvironment.interactiveAuth(base: baseEnvironment)

        let remoteSpecifier = "\(alias):\(remotePath)"
        let source: String
        let target: String
        switch request.direction {
        case .upload:
            source = localURL.path
            target = remoteSpecifier
        case .download:
            source = remoteSpecifier
            target = localURL.path
        }

        var arguments: [String] = []
        if request.isDirectory { arguments.append("-r") }
        arguments += ["--", source, target]

        return SCPTransferPlan(
            request: request,
            process: TerminalProcessConfiguration(
                executableURL: scpURL,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL
            )
        )
    }

    private func normalizedAlias(_ alias: String) throws -> String {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias) else {
            throw SCPTransferError.noConcreteAlias
        }
        return normalizedAlias
    }

    private func normalizedRemotePath(_ path: String) throws -> String {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty,
              !normalizedPath.contains("\n"),
              !normalizedPath.contains("\r"),
              !normalizedPath.contains("\0") else {
            throw SCPTransferError.invalidRemotePath
        }
        return normalizedPath
    }
}
