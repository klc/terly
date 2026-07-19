import Foundation
import SSHConfigCore

enum SSHDiagnosticStatus: String, Equatable, Sendable {
    case passed
    case warning
    case failed
    case information
}

struct SSHDiagnosticCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: SSHDiagnosticStatus
    let summary: String
    let detail: String?
}

struct SSHResolvedSetting: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let value: String
    let source: String
}

struct SSHDiagnosticsExecutionPolicy: Equatable, Sendable {
    let requiresExplicitConfigEvaluationApproval: Bool
    let riskDescription: String?

    init(document: SSHConfigDocument) {
        let hasMatchExec = document.containsMatchExec
        let hasIncludes = !document.includes.isEmpty
        requiresExplicitConfigEvaluationApproval = hasMatchExec || hasIncludes

        switch (hasMatchExec, hasIncludes) {
        case (true, true):
            riskDescription = String(localized: "The main config contains Match exec, and files in the Include chain can also run local commands.")
        case (true, false):
            riskDescription = String(localized: "The main config contains Match exec; ssh -G can run this local command.")
        case (false, true):
            riskDescription = String(localized: "Files in the Include chain may contain Match exec; ssh -G can run these local commands.")
        case (false, false):
            riskDescription = nil
        }
    }
}

struct SSHDiagnosticReport: Equatable, Sendable {
    let alias: String
    let createdAt: Date
    let checks: [SSHDiagnosticCheck]
    let resolvedSettings: [SSHResolvedSetting]

    var hasFailures: Bool { checks.contains { $0.status == .failed } }

    /// True when the report shows both "no usable identity in the agent"
    /// (the `agent` check comes back as a warning — see `agentCheck()`,
    /// which always classifies a non-zero `ssh-add -l` as `.warning`) and a
    /// permission-denied authentication failure elsewhere in the run (the
    /// `connection` check, or any other step, classified by
    /// `SSHErrorClassifier` as `.permissionDenied` — whose fixed title is
    /// "Authentication rejected"). That combination is exactly the
    /// "no key available, server won't accept password/whatever else was
    /// tried" situation the WP3 key setup wizard exists to fix, so the
    /// diagnostics view surfaces a shortcut to it.
    var suggestsKeySetup: Bool {
        let agentHasNoUsableIdentity = checks.first { $0.id == "agent" }?.status == .warning
        let hasPermissionDenied = checks.contains {
            $0.status == .failed && $0.summary == String(localized: "Authentication rejected")
        }
        return agentHasNoUsableIdentity && hasPermissionDenied
    }

    var redactedText: String {
        SSHDiagnosticReportRedactor().render(self)
    }
}

protocol SSHConnectionDiagnosing: Sendable {
    func diagnose(
        alias: String,
        document: SSHConfigDocument
    ) async -> SSHDiagnosticReport
}

final class SSHConnectionDiagnostics: SSHConnectionDiagnosing, @unchecked Sendable {
    private let processClient: any SSHProcessExecuting
    private let environment: [String: String]
    private let fileManager: FileManager
    private let classifier = SSHErrorClassifier()
    private let sshURL: URL
    private let sshAddURL: URL
    private let sshKeygenURL: URL
    private let dnsLookupURL: URL
    private let netcatURL: URL
    private let stepTimeout: TimeInterval

    init(
        processClient: any SSHProcessExecuting = SSHProcessClient(),
        environment: [String: String] = SSHProcessEnvironment.tool(),
        fileManager: FileManager = .default,
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        sshAddURL: URL = URL(fileURLWithPath: "/usr/bin/ssh-add"),
        sshKeygenURL: URL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
        dnsLookupURL: URL = URL(fileURLWithPath: "/usr/bin/dscacheutil"),
        netcatURL: URL = URL(fileURLWithPath: "/usr/bin/nc"),
        stepTimeout: TimeInterval = 6
    ) {
        self.processClient = processClient
        self.environment = environment
        self.fileManager = fileManager
        self.sshURL = sshURL
        self.sshAddURL = sshAddURL
        self.sshKeygenURL = sshKeygenURL
        self.dnsLookupURL = dnsLookupURL
        self.netcatURL = netcatURL
        self.stepTimeout = stepTimeout
    }

    func diagnose(alias: String, document: SSHConfigDocument) async -> SSHDiagnosticReport {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias) else {
            return SSHDiagnosticReport(
                alias: normalizedAlias,
                createdAt: Date(),
                checks: [SSHDiagnosticCheck(
                    id: "alias",
                    title: String(localized: "Connection alias"),
                    status: .failed,
                    summary: String(localized: "A specific Host alias is required."),
                    detail: nil
                )],
                resolvedSettings: []
            )
        }

        var checks: [SSHDiagnosticCheck] = []
        if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: []) {
            return cancelled
        }
        let effectiveResult: SSHProcessResult
        do {
            effectiveResult = try await processClient.execute(request(
                sshURL,
                ["-G", "-v", "--", normalizedAlias],
                timeout: stepTimeout
            ))
        } catch let error as SSHProcessClientError {
            checks.append(check(for: error, id: "effective-config", title: String(localized: "Resolved SSH settings")))
            return report(alias: normalizedAlias, checks: checks, settings: [])
        } catch {
            checks.append(SSHDiagnosticCheck(
                id: "effective-config",
                title: String(localized: "Resolved SSH settings"),
                status: .failed,
                summary: error.localizedDescription,
                detail: nil
            ))
            return report(alias: normalizedAlias, checks: checks, settings: [])
        }

        if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: []) {
            return cancelled
        }

        guard effectiveResult.terminationStatus == 0 else {
            let failure = classifier.classify(output: effectiveResult.combinedOutput)
            checks.append(SSHDiagnosticCheck(
                id: "effective-config",
                title: String(localized: "Resolved SSH settings"),
                status: .failed,
                summary: failure.title,
                detail: "\(failure.explanation) \(failure.suggestion)"
            ))
            return report(alias: normalizedAlias, checks: checks, settings: [])
        }

        let parsedConfig = SSHResolvedConfig(output: effectiveResult.standardOutput)
        let settings = parsedConfig.settings.enumerated().map { index, setting in
            SSHResolvedSetting(
                id: "\(index)-\(setting.key)",
                key: setting.key,
                value: setting.value,
                source: SSHConfigSourceResolver.source(
                    for: setting.key,
                    alias: normalizedAlias,
                    document: document,
                    verboseOutput: effectiveResult.standardError
                )
            )
        }
        checks.append(SSHDiagnosticCheck(
            id: "effective-config",
            title: String(localized: "Resolved SSH settings"),
            status: .passed,
            // TODO(plural)
            summary: String(localized: "OpenSSH produced \(settings.count) active settings."),
            detail: SSHConfigSourceResolver.configurationTrace(from: effectiveResult.standardError)
        ))

        let hostname = parsedConfig.firstValue(for: "hostname") ?? normalizedAlias
        let port = Int(parsedConfig.firstValue(for: "port") ?? "22") ?? 22
        checks.append(await dnsCheck(hostname: hostname))
        if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: settings) {
            return cancelled
        }
        checks.append(proxyJumpCheck(config: parsedConfig))
        checks.append(await portCheck(hostname: hostname, port: port, config: parsedConfig))
        if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: settings) {
            return cancelled
        }
        checks.append(contentsOf: identityChecks(
            config: parsedConfig,
            alias: normalizedAlias,
            hostname: hostname,
            port: port
        ))
        checks.append(await agentCheck())
        if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: settings) {
            return cancelled
        }
        checks.append(contentsOf: await knownHostsChecks(
            config: parsedConfig,
            alias: normalizedAlias,
            hostname: hostname,
            port: port
        ))
        if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: settings) {
            return cancelled
        }
        if parsedConfig.usesProxyCommand {
            checks.append(SSHDiagnosticCheck(
                id: "connection",
                title: String(localized: "End-to-end SSH connection"),
                status: .warning,
                summary: String(localized: "Automatic connection check skipped because of ProxyCommand."),
                detail: String(localized: "ProxyCommand can run a local process. Support for running with explicit user approval may be added in the future.")
            ))
        } else {
            checks.append(await connectionCheck(alias: normalizedAlias))
            if let cancelled = cancellationReport(alias: normalizedAlias, checks: checks, settings: settings) {
                return cancelled
            }
        }

        return report(alias: normalizedAlias, checks: checks, settings: settings)
    }

    private func dnsCheck(hostname: String) async -> SSHDiagnosticCheck {
        if Self.isIPAddress(hostname) {
            return SSHDiagnosticCheck(
                id: "dns",
                title: String(localized: "DNS / target address"),
                status: .passed,
                summary: String(localized: "The target uses an IP address directly."),
                detail: hostname
            )
        }

        do {
            let result = try await processClient.execute(request(
                dnsLookupURL,
                ["-q", "host", "-a", "name", hostname],
                timeout: stepTimeout
            ))
            let addresses = result.standardOutput.components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let fields = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "ip_address" else {
                        return nil
                    }
                    return fields[1].trimmingCharacters(in: .whitespaces)
                }
            guard result.terminationStatus == 0, !addresses.isEmpty else {
                let failure = classifier.classify(output: result.combinedOutput.isEmpty
                    ? "Could not resolve hostname \(hostname)"
                    : result.combinedOutput)
                return diagnosticFailure(failure, id: "dns", title: String(localized: "DNS resolution"))
            }
            return SSHDiagnosticCheck(
                id: "dns",
                title: String(localized: "DNS resolution"),
                status: .passed,
                // TODO(plural)
                summary: String(localized: "Hostname resolved to \(addresses.count) addresses."),
                detail: addresses.joined(separator: ", ")
            )
        } catch let error as SSHProcessClientError {
            return check(for: error, id: "dns", title: String(localized: "DNS resolution"))
        } catch {
            return SSHDiagnosticCheck(
                id: "dns",
                title: String(localized: "DNS resolution"),
                status: .failed,
                summary: error.localizedDescription,
                detail: nil
            )
        }
    }

    private func proxyJumpCheck(config: SSHResolvedConfig) -> SSHDiagnosticCheck {
        let proxyJump = config.firstValue(for: "proxyjump")
        let proxyCommand = config.firstValue(for: "proxycommand")
        if let proxyJump, proxyJump.caseInsensitiveCompare("none") != .orderedSame {
            return SSHDiagnosticCheck(
                id: "proxy",
                title: String(localized: "ProxyJump chain"),
                status: .information,
                summary: String(localized: "The connection uses one or more jump hosts."),
                detail: proxyJump
            )
        }
        if let proxyCommand, proxyCommand.caseInsensitiveCompare("none") != .orderedSame {
            return SSHDiagnosticCheck(
                id: "proxy",
                title: "ProxyCommand",
                status: .information,
                summary: String(localized: "The connection uses a custom proxy command."),
                detail: String(localized: "The command is not included in the report for security reasons.")
            )
        }
        return SSHDiagnosticCheck(
            id: "proxy",
            title: String(localized: "Proxy chain"),
            status: .passed,
            summary: String(localized: "A direct connection is configured."),
            detail: nil
        )
    }

    private func portCheck(
        hostname: String,
        port: Int,
        config: SSHResolvedConfig
    ) async -> SSHDiagnosticCheck {
        if config.usesProxy {
            return SSHDiagnosticCheck(
                id: "port",
                title: String(localized: "Target port access"),
                status: .information,
                summary: String(localized: "Direct port check skipped because of ProxyJump/ProxyCommand."),
                detail: String(localized: "The target port is tested through the proxy chain during the end-to-end SSH check.")
            )
        }

        do {
            let result = try await processClient.execute(request(
                netcatURL,
                ["-z", "-G", String(Int(stepTimeout)), "-w", String(Int(stepTimeout)), hostname, String(port)],
                timeout: stepTimeout + 1
            ))
            if result.terminationStatus == 0 {
                return SSHDiagnosticCheck(
                    id: "port",
                    title: String(localized: "Target port access"),
                    status: .passed,
                    summary: String(localized: "TCP \(hostname):\(port) accepts connections."),
                    detail: nil
                )
            }
            let failure = classifier.classify(output: result.combinedOutput.isEmpty
                ? "Connection timed out"
                : result.combinedOutput)
            return diagnosticFailure(failure, id: "port", title: String(localized: "Target port access"))
        } catch let error as SSHProcessClientError {
            return check(for: error, id: "port", title: String(localized: "Target port access"))
        } catch {
            return SSHDiagnosticCheck(
                id: "port",
                title: String(localized: "Target port access"),
                status: .failed,
                summary: error.localizedDescription,
                detail: nil
            )
        }
    }

    private func identityChecks(
        config: SSHResolvedConfig,
        alias: String,
        hostname: String,
        port: Int
    ) -> [SSHDiagnosticCheck] {
        let paths = config.values(for: "identityfile")
            .filter { $0.caseInsensitiveCompare("none") != .orderedSame }
        guard !paths.isEmpty else {
            return [SSHDiagnosticCheck(
                id: "identity-files",
                title: "IdentityFile",
                status: .information,
                summary: String(localized: "No explicit IdentityFile; SSH agent and OpenSSH defaults will be used."),
                detail: nil
            )]
        }

        let context = pathExpansionContext(
            config: config,
            alias: alias,
            hostname: hostname,
            port: port
        )
        return paths.enumerated().map { index, rawPath in
            let expansion = SSHPathTokenExpander.expand(rawPath, context: context)
            guard let expandedPath = expansion.expandedPath else {
                return SSHDiagnosticCheck(
                    id: "identity-\(index)",
                    title: "IdentityFile: \(URL(fileURLWithPath: rawPath).lastPathComponent)",
                    status: .warning,
                    summary: String(localized: "The file path contains OpenSSH tokens that will be resolved at connection time."),
                    detail: String(localized: "Unresolved token: \(expansion.unresolvedTokens.joined(separator: ", ")). The file was not skipped, and the private key content was not read.")
                )
            }
            let url = URL(fileURLWithPath: expandedPath)
            let displayName = url.lastPathComponent.isEmpty ? "IdentityFile" : url.lastPathComponent
            guard fileManager.fileExists(atPath: expandedPath) else {
                return SSHDiagnosticCheck(
                    id: "identity-\(index)",
                    title: "IdentityFile: \(displayName)",
                    status: .failed,
                    summary: String(localized: "File not found."),
                    detail: String(localized: "The private key content was not read.")
                )
            }

            let permissions = (try? fileManager.attributesOfItem(atPath: expandedPath)[.posixPermissions] as? NSNumber)?.intValue
            let isOverlyPermissive = permissions.map { ($0 & 0o077) != 0 } ?? false
            return SSHDiagnosticCheck(
                id: "identity-\(index)",
                title: "IdentityFile: \(displayName)",
                status: isOverlyPermissive ? .warning : .passed,
                summary: isOverlyPermissive
                    ? String(localized: "File permissions are too open for group or other users.")
                    : String(localized: "The file exists and its permissions are restricted."),
                detail: permissions.map { String(localized: "Permissions: \(String($0, radix: 8)). The private key content was not read.") }
            )
        }
    }

    private func agentCheck() async -> SSHDiagnosticCheck {
        do {
            let result = try await processClient.execute(request(sshAddURL, ["-l"], timeout: stepTimeout))
            if result.terminationStatus == 0 {
                let keyCount = result.standardOutput.split(separator: "\n").count
                return SSHDiagnosticCheck(
                    id: "agent",
                    title: "SSH agent",
                    status: .passed,
                    // TODO(plural)
                    summary: String(localized: "The agent is offering \(keyCount) key identities."),
                    detail: String(localized: "The key content was not read or transferred to the app.")
                )
            }
            let failure = classifier.classify(output: result.combinedOutput.isEmpty
                ? "The agent has no identities."
                : result.combinedOutput)
            return SSHDiagnosticCheck(
                id: "agent",
                title: "SSH agent",
                status: .warning,
                summary: failure.title,
                detail: "\(failure.explanation) \(failure.suggestion)"
            )
        } catch let error as SSHProcessClientError {
            return check(for: error, id: "agent", title: "SSH agent")
        } catch {
            return SSHDiagnosticCheck(
                id: "agent",
                title: "SSH agent",
                status: .warning,
                summary: error.localizedDescription,
                detail: nil
            )
        }
    }

    private func knownHostsChecks(
        config: SSHResolvedConfig,
        alias: String,
        hostname: String,
        port: Int
    ) async -> [SSHDiagnosticCheck] {
        let lookup = port == 22 ? hostname : "[\(hostname)]:\(port)"
        let configuredValues = config.values(for: "userknownhostsfile")
        let configuredPaths = configuredValues.flatMap(SSHConfigValueTokenizer.tokens)
        if !configuredValues.isEmpty,
           configuredPaths.allSatisfy({ $0.caseInsensitiveCompare("none") == .orderedSame }) {
            return [SSHDiagnosticCheck(
                id: "known-hosts",
                title: String(localized: "Server identity"),
                status: .warning,
                summary: String(localized: "UserKnownHostsFile is configured as none."),
                detail: String(localized: "Persistent user host-key recording is disabled for this connection.")
            )]
        }

        let usablePaths = configuredPaths.filter { $0.caseInsensitiveCompare("none") != .orderedSame }
        let context = pathExpansionContext(
            config: config,
            alias: alias,
            hostname: hostname,
            port: port
        )
        let sources: [(index: Int, path: String?)]
        if configuredValues.isEmpty {
            sources = [(0, nil)]
        } else {
            var checks: [SSHDiagnosticCheck] = []
            var resolvedSources: [(index: Int, path: String?)] = []
            for (index, rawPath) in usablePaths.enumerated() {
                let expansion = SSHPathTokenExpander.expand(rawPath, context: context)
                if let path = expansion.expandedPath {
                    resolvedSources.append((index, path))
                } else {
                    checks.append(SSHDiagnosticCheck(
                        id: "known-hosts-\(index)",
                        title: String(localized: "Server identity: \(URL(fileURLWithPath: rawPath).lastPathComponent)"),
                        status: .warning,
                        summary: String(localized: "The known_hosts path couldn't be resolved safely."),
                        detail: String(localized: "Unresolved token: \(expansion.unresolvedTokens.joined(separator: ", ")). A false 'no record' result was not produced.")
                    ))
                }
            }
            if resolvedSources.isEmpty { return checks }
            let resolvedChecks = await knownHostsChecks(
                lookup: lookup,
                sources: resolvedSources
            )
            return checks + resolvedChecks
        }

        return await knownHostsChecks(lookup: lookup, sources: sources)
    }

    private func knownHostsChecks(
        lookup: String,
        sources: [(index: Int, path: String?)]
    ) async -> [SSHDiagnosticCheck] {
        var checks: [SSHDiagnosticCheck] = []
        for source in sources {
            if Task.isCancelled { break }
            checks.append(await knownHostsCheck(
                lookup: lookup,
                sourcePath: source.path,
                id: sources.count == 1 ? "known-hosts" : "known-hosts-\(source.index)"
            ))
        }
        return checks
    }

    private func knownHostsCheck(
        lookup: String,
        sourcePath: String?,
        id: String
    ) async -> SSHDiagnosticCheck {
        do {
            var arguments = ["-F", lookup]
            if let sourcePath {
                arguments += ["-f", sourcePath]
            }
            let lookupResult = try await processClient.execute(request(
                sshKeygenURL,
                arguments,
                timeout: stepTimeout
            ))
            guard lookupResult.terminationStatus == 0, !lookupResult.standardOutput.isEmpty else {
                return SSHDiagnosticCheck(
                    id: id,
                    title: knownHostsTitle(path: sourcePath),
                    status: .warning,
                    summary: String(localized: "No known_hosts entry was found for this target."),
                    detail: String(localized: "The app doesn't add entries automatically. Verify the fingerprint and approve it in a regular terminal connection.")
                )
            }

            guard !Task.isCancelled else {
                return check(for: .cancelled, id: id, title: knownHostsTitle(path: sourcePath))
            }
            let fingerprintResult = try await processClient.execute(SSHProcessRequest(
                executableURL: sshKeygenURL,
                arguments: ["-lf", "-"],
                environment: environment,
                standardInput: Data(lookupResult.standardOutput.utf8),
                timeout: stepTimeout
            ))
            let fingerprints = fingerprintResult.standardOutput.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return SSHDiagnosticCheck(
                id: id,
                title: knownHostsTitle(path: sourcePath),
                status: fingerprints.isEmpty ? .warning : .passed,
                summary: fingerprints.isEmpty
                    ? String(localized: "A known_hosts entry exists, but a fingerprint could not be generated.")
                    : String(localized: "known_hosts entry and fingerprint found."),
                detail: fingerprints.joined(separator: "\n")
            )
        } catch let error as SSHProcessClientError {
            return check(for: error, id: id, title: knownHostsTitle(path: sourcePath))
        } catch {
            return SSHDiagnosticCheck(
                id: id,
                title: knownHostsTitle(path: sourcePath),
                status: .warning,
                summary: error.localizedDescription,
                detail: nil
            )
        }
    }

    private func knownHostsTitle(path: String?) -> String {
        guard let path else { return String(localized: "Server identity") }
        return String(localized: "Server identity: \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    private func connectionCheck(alias: String) async -> SSHDiagnosticCheck {
        do {
            let result = try await processClient.execute(request(
                sshURL,
                [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=\(Int(stepTimeout))",
                    "-o", "ConnectionAttempts=1",
                    "-o", "StrictHostKeyChecking=yes",
                    "-o", "NumberOfPasswordPrompts=0",
                    "-o", "PermitLocalCommand=no",
                    "-o", "RemoteCommand=none",
                    "-o", "ClearAllForwardings=yes",
                    "-o", "KnownHostsCommand=none",
                    "-T", "--", alias, "exit",
                ],
                timeout: stepTimeout + 2
            ))
            if result.terminationStatus == 0 {
                return SSHDiagnosticCheck(
                    id: "connection",
                    title: String(localized: "End-to-end SSH connection"),
                    status: .passed,
                    summary: String(localized: "Connection, host trust, and key verification succeeded."),
                    detail: nil
                )
            }
            return diagnosticFailure(
                classifier.classify(output: result.combinedOutput),
                id: "connection",
                title: String(localized: "End-to-end SSH connection")
            )
        } catch let error as SSHProcessClientError {
            return check(for: error, id: "connection", title: String(localized: "End-to-end SSH connection"))
        } catch {
            return SSHDiagnosticCheck(
                id: "connection",
                title: String(localized: "End-to-end SSH connection"),
                status: .failed,
                summary: error.localizedDescription,
                detail: nil
            )
        }
    }

    private func request(
        _ executableURL: URL,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> SSHProcessRequest {
        SSHProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    private func check(for error: SSHProcessClientError, id: String, title: String) -> SSHDiagnosticCheck {
        diagnosticFailure(classifier.classify(output: "", processError: error), id: id, title: title)
    }

    private func diagnosticFailure(
        _ failure: SSHClassifiedError,
        id: String,
        title: String
    ) -> SSHDiagnosticCheck {
        SSHDiagnosticCheck(
            id: id,
            title: title,
            status: failure.kind == .cancelled ? .warning : .failed,
            summary: failure.title,
            detail: "\(failure.explanation) \(failure.suggestion)"
        )
    }

    private func report(
        alias: String,
        checks: [SSHDiagnosticCheck],
        settings: [SSHResolvedSetting]
    ) -> SSHDiagnosticReport {
        SSHDiagnosticReport(
            alias: alias,
            createdAt: Date(),
            checks: checks,
            resolvedSettings: settings
        )
    }

    private func cancellationReport(
        alias: String,
        checks: [SSHDiagnosticCheck],
        settings: [SSHResolvedSetting]
    ) -> SSHDiagnosticReport? {
        guard Task.isCancelled else { return nil }
        var cancelledChecks = checks
        if cancelledChecks.last?.summary != String(localized: "Operation cancelled") {
            cancelledChecks.append(SSHDiagnosticCheck(
                id: "cancelled",
                title: String(localized: "Diagnostics"),
                status: .warning,
                summary: String(localized: "Operation cancelled"),
                detail: String(localized: "No new network or SSH subprocess was started after cancellation.")
            ))
        }
        return report(alias: alias, checks: cancelledChecks, settings: settings)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains) &&
            (value.contains(":") || value.split(separator: ".").count == 4)
    }

    private func pathExpansionContext(
        config: SSHResolvedConfig,
        alias: String,
        hostname: String,
        port: Int
    ) -> SSHPathExpansionContext {
        SSHPathExpansionContext(
            homeDirectory: fileManager.homeDirectoryForCurrentUser.path,
            hostname: hostname,
            port: String(port),
            remoteUser: config.firstValue(for: "user"),
            originalHost: alias
        )
    }
}

struct SSHPathExpansionContext: Equatable, Sendable {
    let homeDirectory: String
    let hostname: String
    let port: String
    let remoteUser: String?
    let originalHost: String
}

struct SSHPathExpansionResult: Equatable, Sendable {
    let expandedPath: String?
    let unresolvedTokens: [String]
}

enum SSHPathTokenExpander {
    static func expand(
        _ rawPath: String,
        context: SSHPathExpansionContext
    ) -> SSHPathExpansionResult {
        var path = rawPath
        if path == "~" {
            path = context.homeDirectory
        } else if path.hasPrefix("~/") {
            path = context.homeDirectory + path.dropFirst()
        } else if path.hasPrefix("~") {
            return SSHPathExpansionResult(expandedPath: nil, unresolvedTokens: [String(localized: "~user")])
        }

        var result = ""
        var unresolved: [String] = []
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            guard character == "%" else {
                result.append(character)
                index = path.index(after: index)
                continue
            }

            let tokenIndex = path.index(after: index)
            guard tokenIndex < path.endIndex else {
                unresolved.append("%")
                break
            }
            let token = path[tokenIndex]
            let replacement: String?
            switch token {
            case "%": replacement = "%"
            case "d": replacement = context.homeDirectory
            case "h": replacement = context.hostname
            case "p": replacement = context.port
            case "r": replacement = context.remoteUser
            case "n": replacement = context.originalHost
            default: replacement = nil
            }
            if let replacement {
                result += replacement
            } else {
                let unresolvedToken = "%\(token)"
                if !unresolved.contains(unresolvedToken) { unresolved.append(unresolvedToken) }
            }
            index = path.index(after: tokenIndex)
        }

        return SSHPathExpansionResult(
            expandedPath: unresolved.isEmpty ? result : nil,
            unresolvedTokens: unresolved
        )
    }
}

enum SSHConfigValueTokenizer {
    static func tokens(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in value {
            if isEscaping {
                current.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if isEscaping { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

struct SSHResolvedConfig: Equatable, Sendable {
    struct Setting: Equatable, Sendable {
        let key: String
        let value: String
    }

    let settings: [Setting]

    init(output: String) {
        settings = output.components(separatedBy: .newlines).compactMap { line in
            let components = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard components.count == 2 else { return nil }
            return Setting(key: components[0].lowercased(), value: String(components[1]))
        }
    }

    func firstValue(for key: String) -> String? {
        settings.first { $0.key == key.lowercased() }?.value
    }

    func values(for key: String) -> [String] {
        settings.filter { $0.key == key.lowercased() }.map(\.value)
    }

    var usesProxy: Bool {
        [firstValue(for: "proxyjump"), firstValue(for: "proxycommand")]
            .compactMap { $0 }
            .contains { $0.caseInsensitiveCompare("none") != .orderedSame }
    }

    var usesProxyCommand: Bool {
        guard let value = firstValue(for: "proxycommand") else { return false }
        return value.caseInsensitiveCompare("none") != .orderedSame
    }
}

private enum SSHConfigSourceResolver {
    static func source(
        for keyword: String,
        alias: String,
        document: SSHConfigDocument,
        verboseOutput: String
    ) -> String {
        let matchingLines = document.lines.filter { line in
            guard case let .directive(existingKeyword, _) = line.kind else { return false }
            return existingKeyword.caseInsensitiveCompare(keyword) == .orderedSame
        }

        for line in matchingLines.sorted(by: { $0.number < $1.number }) {
            if document.globalLineRange?.contains(line.number) == true {
                return String(localized: "Global config, line \(line.number)")
            }
            if let host = document.hostBlocks.first(where: {
                $0.lineRange.contains(line.number) && hostPatterns($0.patterns, match: alias)
            }) {
                return String(localized: "Host \(host.displayName), line \(line.number)")
            }
            if let match = document.matchBlocks.first(where: { $0.lineRange.contains(line.number) }) {
                return String(localized: "Possible \(match.displayName) source, line \(line.number)")
            }
        }
        if !document.includes.isEmpty || verboseOutput.localizedCaseInsensitiveContains("reading configuration data") {
            return String(localized: "OpenSSH default or Include chain")
        }
        return String(localized: "OpenSSH default")
    }

    static func configurationTrace(from output: String) -> String? {
        let entries = output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let range = line.range(of: "Reading configuration data ", options: .caseInsensitive) else {
                return nil
            }
            let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let uniqueEntries = entries.reduce(into: [String]()) { result, entry in
            if !result.contains(entry) { result.append(entry) }
        }
        return uniqueEntries.isEmpty ? nil : String(localized: "Config sources read: \(uniqueEntries.joined(separator: ", "))")
    }

    private static func hostPatterns(_ patterns: [String], match alias: String) -> Bool {
        let negativePatterns = patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        guard !negativePatterns.contains(where: { wildcard($0, matches: alias) }) else { return false }
        let positivePatterns = patterns.filter { !$0.hasPrefix("!") }
        return positivePatterns.contains(where: { wildcard($0, matches: alias) })
    }

    private static func wildcard(_ pattern: String, matches value: String) -> Bool {
        let expression = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(expression)$", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct SSHDiagnosticReportRedactor: Sendable {
    func render(_ report: SSHDiagnosticReport) -> String {
        var lines = [
            String(localized: "Terly Diagnostic Report"),
            String(localized: "Connection: \(report.alias)"),
            String(localized: "Date: \(report.createdAt.formatted(.iso8601))"),
            "",
            String(localized: "Checks"),
        ]
        for check in report.checks {
            lines.append("[\(check.status.rawValue.uppercased())] \(check.title): \(check.summary)")
            if let detail = check.detail, !detail.isEmpty {
                lines.append("  \(detail)")
            }
        }
        lines.append(contentsOf: ["", String(localized: "Resolved settings")])
        for setting in report.resolvedSettings {
            let value: String
            switch setting.key {
            case "user", "localcommand", "remotecommand", "proxycommand":
                value = String(localized: "<redacted>")
            case "identityfile", "userknownhostsfile", "globalknownhostsfile", "controlpath":
                value = String(localized: "<local-path>")
            default:
                value = setting.value
            }
            lines.append("\(setting.key) \(value) [\(setting.source)]")
        }
        return redactLocalPaths(in: lines.joined(separator: "\n"))
    }

    private func redactLocalPaths(in text: String) -> String {
        var redacted = text.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: String(localized: "<local-dir>")
        )
        let localUser = NSUserName()
        if !localUser.isEmpty {
            redacted = redacted.replacingOccurrences(of: localUser, with: String(localized: "<local-user>"))
        }
        return redacted
    }
}
