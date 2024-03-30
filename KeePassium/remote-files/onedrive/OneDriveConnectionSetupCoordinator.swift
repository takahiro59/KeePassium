//  KeePassium Password Manager
//  Copyright © 2018-2024 KeePassium Labs <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact us.

import KeePassiumLib

protocol OneDriveConnectionSetupCoordinatorDelegate: AnyObject {
    func didPickRemoteFile(
        url: URL,
        oauthToken: OAuthToken,
        stateIndicator: BusyStateIndicating?,
        in coordinator: OneDriveConnectionSetupCoordinator
    )
    func didPickRemoteFolder(
        _ folder: OneDriveItem,
        oauthToken: OAuthToken,
        stateIndicator: BusyStateIndicating?,
        in coordinator: OneDriveConnectionSetupCoordinator
    )
}

final class OneDriveConnectionSetupCoordinator: RemoteDataSourceSetupCoordinator {
    typealias Manager = OneDriveManager

    var childCoordinators = [Coordinator]()
    var dismissHandler: CoordinatorDismissHandler?

    weak var delegate: OneDriveConnectionSetupCoordinatorDelegate?

    let router: NavigationRouter

    let stateIndicator: BusyStateIndicating
    let selectionMode: RemoteItemSelectionMode
    let manager = OneDriveManager.shared

    private var oldRef: URLReference?
    weak var firstVC: UIViewController?

    var token: OAuthToken?
    private var driveInfo: OneDriveDriveInfo?

    init(
        stateIndicator: BusyStateIndicating,
        selectionMode: RemoteItemSelectionMode = .file,
        oldRef: URLReference?,
        router: NavigationRouter
    ) {
        self.stateIndicator = stateIndicator
        self.selectionMode = selectionMode
        self.oldRef = oldRef
        self.router = router
    }

    deinit {
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
    }

    func start() {
        driveInfo = nil
        startSignIn()
    }
}

extension OneDriveConnectionSetupCoordinator {
    func onAuthorized(token: OAuthToken) {
        stateIndicator.indicateState(isBusy: true)
        manager.getDriveInfo(parent: nil, freshToken: token) { [weak self] result in
            guard let self else { return }
            self.stateIndicator.indicateState(isBusy: false)
            switch result {
            case .success(let driveInfo):
                onDriveInfoAcquired(driveInfo)
            case .failure(let oneDriveError):
                router.navigationController.showErrorAlert(oneDriveError)
            }
        }
    }

    private func onDriveInfoAcquired(_ driveInfo: OneDriveDriveInfo) {
        self.driveInfo = driveInfo
        if let oldRef,
           let url = oldRef.url,
           oldRef.fileProvider == .keepassiumOneDrive
        {
            trySelectFile(url, onFailure: { [weak self] in
                guard let self else { return }
                self.oldRef = nil
                self.onDriveInfoAcquired(driveInfo)
            })
            return
        }

        maybeSuggestPremium(isCorporateStorage: driveInfo.type.isCorporate) { [weak self] _ in
            self?.showWelcomeFolder()
        }
    }

    private func trySelectFile(_ fileURL: URL, onFailure: @escaping () -> Void) {
        guard let token,
              let oneDriveItem = OneDriveItem.fromURL(fileURL)
        else {
            onFailure()
            return
        }
        manager.getItemInfo(
            oneDriveItem,
            token: token,
            tokenUpdater: nil
        ) { [self, onFailure] result in
            switch result {
            case .success(let oneDriveItem):
                Diag.info("Old file reference reinstated successfully")
                didSelectFile(oneDriveItem, stateIndicator: stateIndicator)
            case .failure(let oneDriveError):
                Diag.debug("Failed to reinstate old file reference [message: \(oneDriveError.localizedDescription)]")
                onFailure()
            }
        }
    }

    private func showWelcomeFolder() {
        guard let driveInfo else {
            Diag.warning("Not signed into any OneDrive account, cancelling")
            assertionFailure()
            return
        }
        let vc = RemoteFolderViewerVC.make()
        vc.items = [
            OneDriveItem.getPersonalFilesFolder(driveInfo: driveInfo),
            OneDriveItem.getSharedWithMeFolder(driveInfo: driveInfo),
        ]
        vc.folder = nil
        vc.folderName = driveInfo.type.description
        vc.delegate = self
        vc.selectionMode = selectionMode
        router.push(vc, animated: true, onPop: {})

        if firstVC == nil {
            firstVC = vc
        }
    }
}

extension OneDriveConnectionSetupCoordinator: RemoteFolderViewerDelegate {
    func didPressSave(to folder: RemoteFileItem, in viewController: RemoteFolderViewerVC) {
        guard let token else {
            Diag.warning("Not signed into any OneDrive account, cancelling")
            assertionFailure()
            return
        }
        guard let oneDriveFolder = folder as? OneDriveItem else {
            Diag.warning("Unexpected type of selected remote item")
            assertionFailure()
            return
        }
        guard oneDriveFolder.isFolder else {
            Diag.warning("Selected item is not a folder")
            assertionFailure()
            return
        }
        delegate?.didPickRemoteFolder(
            oneDriveFolder,
            oauthToken: token,
            stateIndicator: viewController,
            in: self
        )
    }

    func didSelectItem(_ item: RemoteFileItem, in viewController: RemoteFolderViewerVC) {
        guard let token else {
            Diag.warning("Not signed into any OneDrive account, cancelling")
            assertionFailure()
            return
        }
        guard let oneDriveItem = item as? OneDriveItem else {
            Diag.warning("Unexpected type of selected item")
            assertionFailure()
            return
        }

        if item.isFolder {
            showFolder(folder: oneDriveItem, presenter: viewController)
            return
        }

        stateIndicator.indicateState(isBusy: true)
        manager.updateItemInfo(
            oneDriveItem,
            freshToken: token,
            completionQueue: .main,
            completion: { [weak self, weak viewController] result in
                guard let self, let viewController  else { return }
                viewController.indicateState(isBusy: false)
                switch result {
                case .success(let fileItem):
                    self.onSelectedFileInfoUpdated(fileItem, in: viewController)
                case .failure(let oneDriveError):
                    Diag.info("Failed to update shared item [message: \(oneDriveError.localizedDescription)]")
                    viewController.showErrorAlert(oneDriveError)
                }
            }
        )
    }

    private func onSelectedFileInfoUpdated(
        _ fileItem: OneDriveItem,
        in viewController: RemoteFolderViewerVC
    ) {
        if fileItem.driveInfo.type.isCorporate {
            performPremiumActionOrOfferUpgrade(for: .canUseBusinessClouds, in: viewController) { [weak self] in
                self?.didSelectFile(fileItem, stateIndicator: viewController)
            }
        } else {
            didSelectFile(fileItem, stateIndicator: viewController)
        }
    }

    private func didSelectFile(_ fileItem: OneDriveItem, stateIndicator: BusyStateIndicating?) {
        guard let token else {
            Diag.error("Not signed into any OneDrive account, cancelling")
            assertionFailure()
            return
        }
        let fileURL = fileItem.toURL()
        delegate?.didPickRemoteFile(url: fileURL, oauthToken: token, stateIndicator: stateIndicator, in: self)
        dismiss()
    }
}
