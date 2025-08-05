//
//  FileDestination+Rotation.swift
//  SwiftyBeaver
//
//  Created by Sebastian Kreutzberger on 05.12.15.
//  Copyright © 2015 Sebastian Kreutzberger
//  Some rights reserved: http://opensource.org/licenses/MIT
//

import Foundation
import os.lock

// MARK: - File Rotation Methods

extension FileDestination {
    /// Validates file size and performs rotation if needed
    func validateSaveFile(str: String) {
        if let logFileURL {
            validateLogFileURL(logFileURL, str: str)
        }
        if let logFileHandle {
            validateLogFileHandle(logFileHandle, str: str)
        }
    }

    /// Validates the log file URL and performs rotation if needed
    private func validateLogFileURL(_ url: URL, str: String) {
        guard logFileAmount > 1 else { return }

        // Initialize rotation checker if needed
        if fileURLRotationChecker == nil {
            initializeURLRotationChecker(url: url)
        }

        guard let checker = fileURLRotationChecker else { return }

        // Use smart rotation checker for file URL rotation
        let estimatedSize = FileRotationChecker.estimateWriteSize(str)
        let shouldCheck = checker.shouldCheckFileSize(estimatedWriteSize: estimatedSize)
        guard shouldCheck else { return }

        guard fileManager.fileExists(at: url) else { return }

        // Get actual file size using the unified method
        let actualSize = getCurrentFileSize(at: url)

        // Update rotation checker with actual size
        checker.updateWithActualSize(actualSize, maxFileSize: Int64(logFileMaxSize), estimatedWriteSize: estimatedSize)

        // Do file rotation if needed
        guard actualSize > Int64(logFileMaxSize) else { return }
        rotateFile(url)
    }

    /// Validates the log file handle and performs rotation if needed
    private func validateLogFileHandle(_ fileHandle: FileHandle, str: String) {
        // Initialize rotation checker if needed
        if fileHandleRotationChecker == nil {
            initializeFileHandleRotationChecker(fileHandle: fileHandle)
        }

        guard let checker = fileHandleRotationChecker else { return }

        // Use smart rotation checker for file handle rotation
        let estimatedSize = FileRotationChecker.estimateWriteSize(str)
        let shouldCheck = checker.shouldCheckFileSize(estimatedWriteSize: estimatedSize)
        guard shouldCheck else { return }

        // Get actual file size
        let actualSize = Int64(fileHandle.getSize())

        // Update rotation checker with actual size
        checker.updateWithActualSize(actualSize, maxFileSize: Int64(logFileMaxSize), estimatedWriteSize: estimatedSize)

        // Do file truncation if needed
        guard actualSize > Int64(logFileMaxSize) else { return }

        // Perform the actual truncation
        withFileHandleLock {
            do {
                try fileHandle.truncateFile(at: 0)
            } catch {
                print("SwiftyBeaver File Destination could not truncate logFileHandle: \(String(describing: error)).")
            }
        }
    }

    /// Initializes the rotation checker with current file size
    private func initializeURLRotationChecker(url: URL) {
        if fileURLRotationChecker == nil {
            let currentSize = getCurrentFileSize(at: url)
            fileURLRotationChecker = FileRotationChecker(initialFileSize: currentSize)
        }
    }

    /// Initializes the file handle rotation checker with current file size
    private func initializeFileHandleRotationChecker(fileHandle: FileHandle) {
        if fileHandleRotationChecker == nil {
            let currentSize = Int64(fileHandle.getSize())
            fileHandleRotationChecker = FileRotationChecker(initialFileSize: currentSize)
        }
    }

    /// Resets the rotation checker when configuration changes
    func resetRotationChecker() {
        if let checker = fileURLRotationChecker {
            checker.reset()
        } else {
            fileURLRotationChecker = nil
        }

        if let checker = fileHandleRotationChecker {
            checker.reset()
        } else {
            fileHandleRotationChecker = nil
        }
    }

    /// Gets the current file size at the given URL
    /// - Parameter url: The file URL to check
    /// - Returns: File size in bytes, or 0 if file doesn't exist or error occurs
    func getCurrentFileSize(at url: URL) -> Int64 {
        let filePath = url.urlPath(percentEncoded: false)
        guard fileManager.fileExists(atPath: filePath) else { return 0 }

        do {
            let attr = try fileManager.attributesOfItem(atPath: filePath)
            return Int64(attr[FileAttributeKey.size] as? UInt64 ?? 0)
        } catch {
            return 0
        }
    }
}

// MARK: - File Rotation Implementation

private extension FileDestination {
    /// Rotates log files by moving them to indexed backup files
    func rotateFile(_ fileUrl: URL) {
        let filePath = fileUrl.path
        let lastIndex = (logFileAmount - 1)
        let firstIndex = 1
        do {
            for index in stride(from: lastIndex, through: firstIndex, by: -1) {
                let oldFile = makeRotatedFileUrl(fileUrl, index: index).path

                if fileManager.fileExists(atPath: oldFile) {
                    if index == lastIndex {
                        // Delete the last file
                        try fileManager.removeItem(atPath: oldFile)
                    } else {
                        // Move the current file to next index
                        let newFile = makeRotatedFileUrl(fileUrl, index: index + 1).path
                        try fileManager.moveItem(atPath: oldFile, toPath: newFile)
                    }
                }
            }

            // Finally, move the current file
            let newFile = makeRotatedFileUrl(fileUrl, index: firstIndex).path
            try fileManager.moveItem(atPath: filePath, toPath: newFile)
        } catch {
            print("rotateFile error: \(error)")
        }
    }

    /// Creates a rotated file URL with the given index
    func makeRotatedFileUrl(_ fileUrl: URL, index: Int) -> URL {
        // The index is appended to the file name, to preserve the original extension.
        fileUrl.deletingPathExtension()
            .appendingPathExtension("\(index).\(fileUrl.pathExtension)")
    }
}
