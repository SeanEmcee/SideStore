#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Native-only SideStore integration entry point for the Crimson host.
///
/// Compile this file into SideStore's *real* application module when its AppManager,
/// signing pipeline, database and background services have been integrated into
/// the Nyxian containing application. DO NOT execute an unmodified SideStore IPA
/// inside a Procursus guest and assume it has permission to install host apps.
///
/// Source fork: SeanEmcee/SideStore (develop).
@MainActor
final class CrimsonSideStoreImporter: NSObject, UIDocumentPickerDelegate {
    private weak var presenter: UIViewController?
    private var pendingCompletion: ((Result<String, Error>) -> Void)?

    enum ImportError: LocalizedError {
        case invalidIPA
        case missingPresenter
        case alreadyPending
        var errorDescription: String? {
            switch self {
            case .invalidIPA: return "Select a local .ipa file."
            case .missingPresenter: return "The Crimson host screen is not available."
            case .alreadyPending: return "Finish or cancel the current IPA import first."
            }
        }
    }

    /// The guest may request that this *native* picker open, but may never supply
    /// an arbitrary file URL or receive signing credentials.
    func presentInstaller(from presenter: UIViewController,
                          completion: @escaping (Result<String, Error>) -> Void) {
        guard pendingCompletion == nil else {
            completion(.failure(ImportError.alreadyPending))
            return
        }
        self.presenter = presenter
        pendingCompletion = completion
        let ipaType = UTType(filenameExtension: "ipa") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [ipaType], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Always settle the completion. Otherwise ROMSpace retains a pending
        // installer state forever after the system document picker is cancelled.
        finish(.failure(CocoaError(.userCancelled)))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let selected = urls.first, selected.isFileURL,
              selected.pathExtension.lowercased() == "ipa" else {
            finish(.failure(ImportError.invalidIPA))
            return
        }
        guard let presenter else {
            finish(.failure(ImportError.missingPresenter))
            return
        }
        // Copy the system-picker selection to a dedicated temporary file.
        // SideStore owns the signing & installation pipeline; no guest IPA path is trusted.
        let scoped = selected.startAccessingSecurityScopedResource()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("crimson-selected-\(UUID().uuidString).ipa")
        do {
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
            let resource = try selected.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resource.isRegularFile == true,
                  let length = resource.fileSize,
                  length > 0, length <= 2_000_000_000 else {
                throw ImportError.invalidIPA
            }
            try FileManager.default.copyItem(at: selected, to: staging)
        } catch {
            finish(.failure(error))
            return
        }

        let alert = UIAlertController(
            title: "Install on this iPhone?",
            message: "SideStore will sign and install the selected IPA onto real iOS, not into the Crimson ROM. Review the source before installing.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            try? FileManager.default.removeItem(at: staging)
            self?.finish(.failure(CocoaError(.userCancelled)))
        })
        alert.addAction(UIAlertAction(title: "Install with SideStore", style: .default) { [weak self, weak presenter] _ in
            guard let self, let presenter else {
                try? FileManager.default.removeItem(at: staging)
                self?.finish(.failure(ImportError.missingPresenter))
                return
            }
            // IMPORTANT: this is SideStore's *real* native AppManager pipeline:
            // sign -> provision -> install -> installed-app database -> refresh management.
            _ = AppManager.shared.install(
                .url(staging),
                presentingViewController: presenter,
                completionHandler: { [weak self] result in
                    Task { @MainActor in
                        try? FileManager.default.removeItem(at: staging)
                        switch result {
                        case .success(let installedApp):
                            self?.finish(.success(installedApp.name))
                        case .failure(let error):
                            self?.finish(.failure(error))
                        }
                    }
                }
            )
        })
        presenter.present(alert, animated: true)
    }

    private func finish(_ result: Result<String, Error>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        presenter = nil
        completion?(result)
    }
}
#endif
