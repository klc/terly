import Foundation

private final class CoreBundleToken {}

extension Bundle {
    /// SSHConfigCore framework bundle'ı — kullanıcıya görünen stringler
    /// String(localized:bundle: .core) ile bu bundle'dan çözülür.
    static let core = Bundle(for: CoreBundleToken.self)
}
