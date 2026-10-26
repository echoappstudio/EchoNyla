import AppKit
import Observation
import EchoNylaCore
import Sparkle

/// EchoNyla's automatic updates, through Sparkle.
///
/// Sparkle checks every hour (set in Info.plist) and once right after launch. When automatic
/// installs are on, a downloaded update is installed and EchoNyla relaunched once no file
/// is waiting to be filed. EchoNyla lives in the menu bar, so an update found by a scheduled
/// check shows as a row in the panel instead of a window that may open behind other apps.
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyInstalls = false
    private(set) var lastCheckDate: Date?
    /// A background check found an update and EchoNyla is waiting for the user to look at it.
    private(set) var updateWaiting: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var installWaitTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInstall: (() -> Void)?

    private var updater: SPUUpdater? { controller?.updater }

    /// Work that an update must not interrupt.
    private var isBusy: Bool {
        AppModel.shared.isBusyWithFiles
    }

    /// Starts the updater, then checks right away if automatic checks are on.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.refresh(from: updater) }
            }
        ]
        refresh(from: updater)
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        updater?.automaticallyDownloadsUpdates = enabled
    }

    private func refresh(from updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        lastCheckDate = updater.lastUpdateCheckDate
    }

    /// Runs `install` once EchoNyla isn't busy any more.
    private func installWhenIdle(_ install: @escaping () -> Void) {
        pendingInstall = install
        installWaitTask?.cancel()
        installWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UpdateInstallPolicy.canInstallNow(isBusy: self.isBusy) {
                    self.installWaitTask = nil
                    let install = self.pendingInstall
                    self.pendingInstall = nil
                    install?()
                    return
                }
                try? await Task.sleep(for: .seconds(UpdateInstallPolicy.retryInterval))
            }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// With automatic installs on, Sparkle hands over the downloaded update; EchoNyla installs
    /// and relaunches as soon as it's idle instead of waiting for the next quit.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installWhenIdle(immediateInstallHandler)
        return true
    }

    /// An update the user chose to install also waits for a file to be dealt with.
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if UpdateInstallPolicy.canInstallNow(isBusy: isBusy) {
            return false
        }
        installWhenIdle(installHandler)
        return true
    }
}

/// A menu-bar app shows a scheduled find gently: a row in the panel instead of a window that may
/// open behind other apps.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    @objc var supportsGentleScheduledUpdateReminders: Bool { true }

    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            updateWaiting = update.displayVersionString
        }
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateWaiting = nil
    }

    @objc func standardUserDriverWillFinishUpdateSession() {
        updateWaiting = nil
    }
}
