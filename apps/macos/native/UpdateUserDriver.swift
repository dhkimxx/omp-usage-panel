import AppKit
import Sparkle

/// Sparkle user driver. Decision points (check result, update found, ready to install) and the download/extraction
/// progress with its real Cancel are shown by this app (inline status, the nonmodal notice, the nonactivating progress
/// panel). The remaining stages Sparkle reports (permission request, installation, installation errors) are forwarded to
/// Sparkle's own standard driver. Every call is on the main thread.
final class UpdateUserDriver: NSObject, SPUUserDriver, SPUStandardUserDriverDelegate {
    private weak var coordinator: UpdaterCoordinator?
    private var standard: SPUStandardUserDriver?

    init(hostBundle: Bundle, coordinator: UpdaterCoordinator) {
        self.coordinator = coordinator
        super.init()
        standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: self)
    }

    // MARK: Permission (only if Sparkle has no stored/Info.plist answer; forwarded unchanged)

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard?.show(request, reply: reply)
    }

    // MARK: Check and result (inline)

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        coordinator?.driverBeganUserInitiatedCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let coordinator else { reply(.dismiss); return }
        coordinator.driverFoundUpdate(item: appcastItem, userInitiated: state.userInitiated, stage: state.stage, reply: reply)
    }

    /// Never reached: the updater delegate declines Sparkle's release-notes download. Notes shown in the notice come from
    /// the signed appcast item, with an HTTPS link the user may open.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    /// The result is published from `SPUUpdaterDelegate.updaterDidNotFindUpdate(_:error:)`, which fires for scheduled and
    /// user-initiated checks alike; this callback only has to acknowledge that no alert is shown.
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    /// Errors are reported inline (status) and acknowledged IMMEDIATELY. Sparkle keeps its installer job (Autoupdate +
    /// progress agent) alive until this acknowledgement, and the standard driver's alert only acknowledges after a person
    /// clicks OK. A background failure (for example an archive that fails signature validation) must never leave the
    /// installer running and the prepared lease undrainable behind a modal dialog, so the standard alert is not used.
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        coordinator?.driverError(error: error as NSError)
        acknowledgement()
    }

    // MARK: Download, extraction (own nonactivating progress + Sparkle's real cancellation), installation (standard)

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        coordinator?.driverDownloadStarted(cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        coordinator?.driverExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        coordinator?.driverReceivedData(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        coordinator?.driverExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        coordinator?.driverExtractionProgress(progress)
    }

    /// Cutover decision point: our coordinator prepares ownership, waits for a safe moment and replies. Sparkle's own
    /// "Install and Relaunch" prompt is intentionally NOT shown (the user already authorized or opted in).
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let coordinator else { reply(.skip); return }
        coordinator.driverReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        coordinator?.driverInstalling(applicationTerminated: applicationTerminated)
        standard?.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        coordinator?.driverInstalled(relaunched: relaunched)
        standard?.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        standard?.dismissUpdateInstallation()
        coordinator?.driverDismissed()
    }

    /// A user check while Sparkle shows progress: bring the Updates UI forward instead of a duplicate window.
    func showUpdateInFocus() {
        coordinator?.driverShowUpdateInFocus()
    }

    // MARK: SPUStandardUserDriverDelegate

    func standardUserDriverWillShowModalAlert() { coordinator?.driverModalAlert(visible: true) }
    func standardUserDriverDidShowModalAlert() { coordinator?.driverModalAlert(visible: false) }
}
