import Foundation

/// When EchoNyla may quit to install an update that has already downloaded.
public enum UpdateInstallPolicy {
    /// How often the waiting installer asks again while EchoNyla is busy.
    public static let retryInterval: TimeInterval = 15

    /// A file is being filed, searched for or waiting for a choice. Quitting now would drop that
    /// work, so the update waits until the file is dealt with. Quitting EchoNyla still
    /// installs the update straight away.
    public static func canInstallNow(isBusy: Bool) -> Bool {
        !isBusy
    }
}
