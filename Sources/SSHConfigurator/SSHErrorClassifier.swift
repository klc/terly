import Foundation

enum SSHFailureKind: String, CaseIterable, Equatable, Sendable {
    case dnsResolution
    case connectionTimeout
    case connectionRefused
    case hostKeyMismatch
    case hostKeyUnknown
    case agentUnavailable
    case authenticationCancelled
    case permissionDenied
    case proxyJump
    case processLaunch
    case cancelled
    case remoteNotFound
    case remoteAlreadyExists
    case remoteDirectoryNotEmpty
    case remoteOperationPermissionDenied
    case unknown
}

/// Identifies which sftp batch verb produced the output being classified.
///
/// The SFTP protocol (v3, as implemented by OpenSSH's `sftp-server`) only defines a
/// handful of status codes, and most POSIX errno values that don't have a dedicated
/// code (e.g. `ENOTEMPTY` from a non-empty `rmdir`, or an existing destination from a
/// non-overwriting `rename`) collapse to the single generic `SSH2_FX_FAILURE`, which
/// the `sftp` CLI renders as the bare word "Failure" — indistinguishable by text alone
/// from any other unmapped error. Passing the verb that was attempted lets the
/// classifier turn that ambiguous "Failure" into an operation-appropriate, honest
/// explanation instead of a meaningless one.
enum SFTPOperationKind: Sendable {
    case createDirectory
    case rename
    case remove
    case removeDirectory
}

struct SSHClassifiedError: Equatable, Sendable {
    let kind: SSHFailureKind
    let title: String
    let explanation: String
    let suggestion: String

    var userFacingDescription: String {
        "\(title): \(explanation) \(suggestion)"
    }
}

struct SSHErrorClassifier: Sendable {
    func classify(
        output: String,
        processError: SSHProcessClientError? = nil,
        sftpCommand: SFTPOperationKind? = nil
    ) -> SSHClassifiedError {
        if let processError {
            switch processError {
            case .cancelled:
                return error(
                    .cancelled,
                    "İşlem iptal edildi",
                    "Bağlantı kontrolü kullanıcı tarafından durduruldu.",
                    "Hazır olduğunda yeniden deneyebilirsin."
                )
            case .timedOut:
                return error(
                    .connectionTimeout,
                    "Bağlantı zaman aşımına uğradı",
                    "Hedef, ağ adımı için ayrılan sürede yanıt vermedi.",
                    "Ağ erişimini, portu ve varsa ProxyJump zincirini kontrol et."
                )
            case let .launchFailed(message):
                return error(
                    .processLaunch,
                    "SSH aracı başlatılamadı",
                    message,
                    "OpenSSH araçlarının sistemde erişilebilir olduğunu kontrol et."
                )
            }
        }

        let normalized = output.lowercased()
        if normalized.contains("terly_askpass_cancelled") {
            return error(
                .authenticationCancelled,
                "Kimlik doğrulama iptal edildi",
                "Parola veya sunucu kimliği onay istemi kullanıcı tarafından kapatıldı.",
                "Hazır olduğunda yeniden dene ve istenen parolayı gir ya da onayı ver."
            )
        }
        if let sftpCommand {
            // Beyond "No such file", the SFTP v3 protocol only has generic status
            // codes: OpenSSH's sftp-server maps most unmapped POSIX errno values
            // (e.g. ENOTEMPTY, or an existing rename destination) to the same bare
            // "Failure" text as any other unexpected error. The verb that was
            // attempted is the only way left to give the user an honest, specific
            // explanation instead of just echoing "Failure".
            if normalized.contains("permission denied") {
                return error(
                    .remoteOperationPermissionDenied,
                    "Bu işlem için yetki yok",
                    "Sunucu bu dosya veya klasör üzerinde işlemi reddetti.",
                    "Uzak dosya/klasör izinlerini ve sahipliğini kontrol et."
                )
            }
            if normalized.contains("failure") {
                switch sftpCommand {
                case .removeDirectory:
                    return error(
                        .remoteDirectoryNotEmpty,
                        "Klasör silinemedi",
                        "Klasör boş değil.",
                        "Bu uygulama klasörleri özyinelemeli (recursive) silmez; önce içeriğini boşalt."
                    )
                case .rename:
                    return error(
                        .remoteAlreadyExists,
                        "Yeniden adlandırılamadı",
                        "Hedef ad zaten kullanılıyor olabilir.",
                        "Farklı bir ad seç ya da önce var olan öğeyi kaldır."
                    )
                case .createDirectory:
                    return error(
                        .remoteAlreadyExists,
                        "Klasör oluşturulamadı",
                        "Bu adla bir dosya veya klasör zaten var olabilir.",
                        "Farklı bir ad seç ya da var olan öğeyi kontrol et."
                    )
                case .remove:
                    return error(
                        .unknown,
                        "Dosya silinemedi",
                        "Sunucu isteği reddetti.",
                        "Öğenin bir dosya olduğundan ve yazma iznin olduğundan emin ol."
                    )
                }
            }
        }
        if containsAny(normalized, [
            "remote host identification has changed",
            "offending ",
        ]) {
            return error(
                .hostKeyMismatch,
                "Sunucu kimliği değişmiş",
                "Kaydedilmiş host key ile sunucunun sunduğu anahtar uyuşmuyor.",
                "Olası saldırı veya yeniden kurulum durumunu doğrulamadan known_hosts kaydını değiştirme."
            )
        }
        if containsAny(normalized, [
            "host key verification failed",
            "no ed25519 host key is known",
            "no ecdsa host key is known",
            "no rsa host key is known",
        ]) {
            return error(
                .hostKeyUnknown,
                "Sunucu kimliği henüz güvenilir değil",
                "Bu host için doğrulanmış bir known_hosts kaydı bulunamadı.",
                "Fingerprint'i bağımsız bir kanaldan doğrulayıp normal terminal bağlantısında açıkça onayla."
            )
        }
        if containsAny(normalized, [
            "could not resolve hostname",
            "name or service not known",
            "nodename nor servname provided",
            "temporary failure in name resolution",
        ]) {
            return error(
                .dnsResolution,
                "DNS çözümlemesi başarısız",
                "Hedef hostname bir IP adresine çözümlenemedi.",
                "HostName yazımını, DNS/VPN bağlantısını ve ProxyJump ayarını kontrol et."
            )
        }
        if containsAny(normalized, [
            "stdio forwarding failed",
            "jumphost loop",
            "connection closed by unknown port 65535",
            "channel 0: open failed: connect failed",
        ]) {
            return error(
                .proxyJump,
                "ProxyJump zinciri başarısız",
                "Ara host veya ara hosttan hedefe yönlendirme kurulamadı.",
                "ProxyJump alias'larını ve zincirdeki her hostun erişimini ayrı ayrı kontrol et."
            )
        }
        if containsAny(normalized, [
            "operation timed out",
            "connection timed out",
            "connect timeout",
        ]) {
            return error(
                .connectionTimeout,
                "Bağlantı zaman aşımına uğradı",
                "Hedef port süresi içinde yanıt vermedi.",
                "Firewall, VPN, port ve ProxyJump erişimini kontrol et."
            )
        }
        if normalized.contains("connection refused") {
            return error(
                .connectionRefused,
                "Bağlantı reddedildi",
                "Hedefe ulaşıldı ancak belirtilen port bağlantıyı kabul etmedi.",
                "SSH servisinin çalıştığını ve Port ayarını kontrol et."
            )
        }
        if containsAny(normalized, [
            "the agent has no identities",
            "agent contains no identities",
            "could not open a connection to your authentication agent",
            "agent refused operation",
            "no such identity",
        ]) {
            return error(
                .agentUnavailable,
                "SSH agent anahtarı kullanılamıyor",
                "Agent çalışmıyor, boş veya gerekli anahtarı imzalama için sunamıyor.",
                "ssh-add ile agent durumunu kontrol et; özel anahtarı uygulamaya verme."
            )
        }
        // "No such file" is one of the handful of status codes the SFTP protocol (v3)
        // actually defines, so OpenSSH's sftp-server reports it verbatim for a missing
        // remote path — checked here (after the more specific "no such identity" agent
        // check above) so a missing local IdentityFile keeps classifying as an agent
        // problem rather than being reinterpreted as a missing remote sftp path.
        if normalized.contains("no such file") {
            return error(
                .remoteNotFound,
                "Dosya veya klasör bulunamadı",
                "Uzak yol artık mevcut değil — silinmiş veya taşınmış olabilir.",
                "Klasör listesini yenileyip yolu yeniden kontrol et."
            )
        }
        if normalized.contains("permission denied") {
            return error(
                .permissionDenied,
                "Kimlik doğrulama reddedildi",
                "Sunucu sunulan kullanıcı veya anahtarı kabul etmedi.",
                "User, IdentityFile ve SSH agent anahtarlarını kontrol et."
            )
        }
        return error(
            .unknown,
            "SSH işlemi başarısız",
            output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenSSH ayrıntılı bir hata mesajı vermedi."
                : output.trimmingCharacters(in: .whitespacesAndNewlines),
            "Tanılama raporundaki kontrolleri incele."
        )
    }

    private func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: text.contains)
    }

    private func error(
        _ kind: SSHFailureKind,
        _ title: String,
        _ explanation: String,
        _ suggestion: String
    ) -> SSHClassifiedError {
        SSHClassifiedError(
            kind: kind,
            title: title,
            explanation: explanation,
            suggestion: suggestion
        )
    }
}
