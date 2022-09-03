//
//  NCNetworkingUploadChunk.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 05/04/21.
//  Copyright © 2021 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import Queuer
import NextcloudKit

extension NCNetworking {

    internal func uploadChunkedFile(metadata: tableMetadata, start: @escaping () -> Void, completion: @escaping (_ error: NKError) -> Void) {

        let directoryProviderStorageOcId = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId)!
        let chunkFolder = NCManageDatabase.shared.getChunkFolder(account: metadata.account, ocId: metadata.ocId)
        let chunkFolderPath = metadata.urlBase + "/" + NCUtilityFileSystem.shared.getWebDAV(account: metadata.account) + "/uploads/" + metadata.userId + "/" + chunkFolder
        let fileNameLocalPath = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView)!
        let chunkSize = CCUtility.getChunkSize()
        let fileSizeInGB = Double(metadata.size) / 1e9
        let ocIdTemp = metadata.ocId
        let selector = metadata.sessionSelector
        var uploadError = NKError(errorCode: 0, errorDescription: "")

        var filesNames = NCManageDatabase.shared.getChunks(account: metadata.account, ocId: metadata.ocId)
        if filesNames.count == 0 {
            NCContentPresenter.shared.noteTop(text: NSLocalizedString("_upload_chunk_", comment: ""), image: nil, type: NCContentPresenter.messageType.info, delay: .infinity, priority: .max)
            filesNames = NKCommon.shared.chunkedFile(inputDirectory: directoryProviderStorageOcId, outputDirectory: directoryProviderStorageOcId, fileName: metadata.fileName, chunkSizeMB: chunkSize)
            if filesNames.count > 0 {
                NCManageDatabase.shared.addChunks(account: metadata.account, ocId: metadata.ocId, chunkFolder: chunkFolder, fileNames: filesNames)
            } else {
                NCContentPresenter.shared.dismiss()
                NCContentPresenter.shared.messageNotification("_error_", description: "_err_file_not_found_", delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error, errorCode: NCGlobal.shared.errorReadFile)
                NCManageDatabase.shared.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", metadata.ocId))
                return completion(uploadError)
            }
        } else {
            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterReloadDataSource, userInfo: ["serverUrl": metadata.serverUrl])
        }

        createChunkedFolder(chunkFolderPath: chunkFolderPath, account: metadata.account) { error in

            NCContentPresenter.shared.dismiss(after: NCGlobal.shared.dismissAfterSecond)
            start()

            guard error == .success else {
                self.uploadChunkFileError(metadata: metadata, chunkFolderPath: chunkFolderPath, directoryProviderStorageOcId: directoryProviderStorageOcId, error: error)
                completion(error)
                return
            }

            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterUploadStartFile, userInfo: ["ocId": metadata.ocId, "serverUrl": metadata.serverUrl, "account": metadata.account, "fileName": metadata.fileName, "sessionSelector": metadata.sessionSelector])

            for fileName in filesNames {

                let serverUrlFileName = chunkFolderPath + "/" + fileName
                let fileNameChunkLocalPath = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: fileName)!

                var size: Int64?
                if let tableChunk = NCManageDatabase.shared.getChunk(account: metadata.account, fileName: fileName) {
                    size = tableChunk.size - NCUtilityFileSystem.shared.getFileSize(filePath: fileNameChunkLocalPath)
                }

                let semaphore = Semaphore()

                NextcloudKit.shared.upload(serverUrlFileName: serverUrlFileName, fileNameLocalPath: fileNameChunkLocalPath, requestHandler: { request in

                    self.uploadRequest[fileNameLocalPath] = request

                }, taskHandler: { task in

                    NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, sessionError: "", sessionTaskIdentifier: task.taskIdentifier, status: NCGlobal.shared.metadataStatusUploading)
                    NKCommon.shared.writeLog("Upload chunk: " + fileName)

                }, progressHandler: { progress in

                    if let size = size {
                        let totalBytesExpected = metadata.size
                        let totalBytes = size + progress.completedUnitCount
                        let fractionCompleted = Float(totalBytes) / Float(totalBytesExpected)

                        NotificationCenter.default.postOnMainThread(
                            name: NCGlobal.shared.notificationCenterProgressTask,
                            object: nil,
                            userInfo: [
                                "account": metadata.account,
                                "ocId": metadata.ocId,
                                "fileName": metadata.fileName,
                                "serverUrl": metadata.serverUrl,
                                "status": NSNumber(value: NCGlobal.shared.metadataStatusInUpload),
                                "progress": NSNumber(value: fractionCompleted),
                                "totalBytes": NSNumber(value: totalBytes),
                                "totalBytesExpected": NSNumber(value: totalBytesExpected)])
                    }

                }) { _, _, _, _, _, _, _, error in

                    self.uploadRequest.removeValue(forKey: fileNameLocalPath)
                    uploadError = error
                    semaphore.continue()
                }

                semaphore.wait()

                if uploadError == .success {
                    NCManageDatabase.shared.deleteChunk(account: metadata.account, ocId: metadata.ocId, fileName: fileName)
                } else {
                    break
                }
            }

            guard uploadError == .success else {
                self.uploadChunkFileError(metadata: metadata, chunkFolderPath: chunkFolderPath, directoryProviderStorageOcId: directoryProviderStorageOcId, error: uploadError)
                completion(error)
                return
            }

            // Assembling the chunks
            let serverUrlFileNameSource = chunkFolderPath + "/.file"
            let pathServerUrl = CCUtility.returnPathfromServerUrl(metadata.serverUrl, urlBase: metadata.urlBase, account: metadata.account)!
            let serverUrlFileNameDestination = metadata.urlBase + "/" + NCUtilityFileSystem.shared.getWebDAV(account: metadata.account) + "/files/" + metadata.userId + pathServerUrl + "/" + metadata.fileName

            var addCustomHeaders: [String: String] = [:]
            let creationDate = "\(metadata.creationDate.timeIntervalSince1970)"
            let modificationDate = "\(metadata.date.timeIntervalSince1970)"

            addCustomHeaders["X-OC-CTime"] = creationDate
            addCustomHeaders["X-OC-MTime"] = modificationDate

            // Calculate Assemble Timeout
            let ASSEMBLE_TIME_PER_GB: Double    = 3 * 60            // 3  min
            let ASSEMBLE_TIME_MIN: Double       = 60                // 60 sec
            let ASSEMBLE_TIME_MAX: Double       = 30 * 60           // 30 min
            let timeout = max(ASSEMBLE_TIME_MIN, min(ASSEMBLE_TIME_PER_GB * fileSizeInGB, ASSEMBLE_TIME_MAX))

            NextcloudKit.shared.moveFileOrFolder(serverUrlFileNameSource: serverUrlFileNameSource, serverUrlFileNameDestination: serverUrlFileNameDestination, overwrite: true, addCustomHeaders: addCustomHeaders, timeout: timeout, queue: DispatchQueue.global(qos: .background)) { _, error in

                NKCommon.shared.writeLog("Assembling chunk with error code: \(error.errorCode)")

                guard error == .success else {
                    self.uploadChunkFileError(metadata: metadata, chunkFolderPath: chunkFolderPath, directoryProviderStorageOcId: directoryProviderStorageOcId, error: error)
                    completion(error)
                    return
                }

                let serverUrl = metadata.serverUrl
                let assetLocalIdentifier = metadata.assetLocalIdentifier
                let isLivePhoto = metadata.livePhoto
                let isE2eEncrypted = metadata.e2eEncrypted
                let account = metadata.account
                let fileName = metadata.fileName

                NCManageDatabase.shared.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", ocIdTemp))
                NCManageDatabase.shared.deleteChunks(account: metadata.account, ocId: ocIdTemp)

                self.readFile(serverUrlFileName: serverUrlFileNameDestination) { (_, metadata, _) in

                    if error == .success, let metadata = metadata {

                        metadata.assetLocalIdentifier = assetLocalIdentifier
                        metadata.e2eEncrypted = isE2eEncrypted
                        metadata.livePhoto = isLivePhoto

                        // Delete Asset on Photos album
                        if CCUtility.getRemovePhotoCameraRoll() && !metadata.assetLocalIdentifier.isEmpty {
                            metadata.deleteAssetLocalIdentifier = true
                        }
                        NCManageDatabase.shared.addMetadata(metadata)

                        if selector == NCGlobal.shared.selectorUploadFileNODelete {
                            NCUtilityFileSystem.shared.moveFile(atPath: CCUtility.getDirectoryProviderStorageOcId(ocIdTemp, fileNameView: fileName), toPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: fileName))
                            NCManageDatabase.shared.addLocalFile(metadata: metadata)
                        }
                        NCUtilityFileSystem.shared.deleteFile(filePath: directoryProviderStorageOcId)

                        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterReloadDataSource, userInfo: ["serverUrl": serverUrl])
                        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterUploadedFile, userInfo: ["ocId": metadata.ocId, "serverUrl": serverUrl, "account": account, "fileName": fileName, "ocIdTemp": ocIdTemp, "errorCode": error.errorCode, "errorDescription": ""])

                    } else {

                        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterReloadDataSourceNetworkForced, userInfo: ["serverUrl": serverUrl])
                        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterUploadedFile, userInfo: ["ocId": ocIdTemp, "serverUrl": serverUrl, "account": account, "fileName": fileName, "ocIdTemp": ocIdTemp, "errorCode": error.errorCode, "errorDescription": ""])
                    }

                    completion(error)
                }
            }
        }
    }

    private func createChunkedFolder(chunkFolderPath: String, account: String, completion: @escaping (_ errorCode: NKError) -> Void) {

        NextcloudKit.shared.readFileOrFolder(serverUrlFileName: chunkFolderPath, depth: "0", showHiddenFiles: CCUtility.getShowHiddenFiles(), queue: NKCommon.shared.backgroundQueue) { _, _, _, error in

            if error == .success {
                completion(NKError(errorCode: 0, errorDescription: ""))
            } else if error.errorCode == NCGlobal.shared.errorResourceNotFound {
                NextcloudKit.shared.createFolder(chunkFolderPath, queue: NKCommon.shared.backgroundQueue) { _, _, _, error in
                    completion(error)
                }
            } else {
                completion(error)
            }
        }
    }

    private func uploadChunkFileError(metadata: tableMetadata, chunkFolderPath: String, directoryProviderStorageOcId: String, error: NKError) {

        var errorDescription = error.errorDescription

        NKCommon.shared.writeLog("Upload chunk error code: \(error.errorCode)")

        if error.errorCode == NSURLErrorCancelled || error.errorCode == NCGlobal.shared.errorRequestExplicityCancelled {

            // Delete chunk folder
            NextcloudKit.shared.deleteFileOrFolder(chunkFolderPath) { _, _ in }

            NCManageDatabase.shared.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", metadata.ocId))
            NCManageDatabase.shared.deleteChunks(account: metadata.account, ocId: metadata.ocId)
            NCUtilityFileSystem.shared.deleteFile(filePath: directoryProviderStorageOcId)

            NextcloudKit.shared.deleteFileOrFolder(chunkFolderPath) { _, _ in }

            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterUploadCancelFile, userInfo: ["ocId": metadata.ocId, "serverUrl": metadata.serverUrl, "account": metadata.account])

        } else {

            // NO report for the connection lost
            if error.errorCode == NCGlobal.shared.errorConnectionLost {
                errorDescription = ""
            } else {
                let description = errorDescription + " code: \(error.errorCode)"
                NCContentPresenter.shared.messageNotification("_error_", description: description, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error, errorCode: NCGlobal.shared.errorInternalError)
            }

            NCManageDatabase.shared.setMetadataSession(ocId: metadata.ocId, session: nil, sessionError: errorDescription, sessionTaskIdentifier: NCGlobal.shared.metadataStatusNormal, status: NCGlobal.shared.metadataStatusUploadError)
        }

        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterUploadedFile, userInfo: ["ocId": metadata.ocId, "serverUrl": metadata.serverUrl, "account": metadata.account, "fileName": metadata.fileName, "ocIdTemp": metadata.ocId, "errorCode": error.errorCode, "errorDescription": ""])
    }
}
