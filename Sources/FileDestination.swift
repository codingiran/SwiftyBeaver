//
//  FileDestination.swift
//  SwiftyBeaver
//
//  Created by Sebastian Kreutzberger on 05.12.15.
//  Copyright © 2015 Sebastian Kreutzberger
//  Some rights reserved: http://opensource.org/licenses/MIT
//

import Foundation
import os.lock

open class FileDestination: BaseDestination, @unchecked Sendable {
    /// The mode in which the file is written to.
    ///
    /// - fileURL: Write to a file URL.
    /// - fileHandle: Write to a file handle.
    /// - hybrid: Write to both a file URL and a file handle.
    public let fileWriteMode: FileWriteMode

    /// Whether to sync the file after each write.
    public var syncAfterEachWrite: Bool = false

    /// Whether to use colored output.
    public var colored: Bool = false {
        didSet {
            if colored {
                // bash font color, first value is intensity, second is color
                // see http://bit.ly/1Otu3Zr & for syntax http://bit.ly/1Tp6Fw9
                // uses the 256-color table from http://bit.ly/1W1qJuH
                reset = "\u{001b}[0m"
                escape = "\u{001b}[38;5;"
                levelColor.verbose = "251m" // silver
                levelColor.debug = "35m" // green
                levelColor.info = "38m" // blue
                levelColor.warning = "178m" // yellow
                levelColor.error = "197m" // red
            } else {
                reset = ""
                escape = ""
                levelColor.verbose = ""
                levelColor.debug = ""
                levelColor.info = ""
                levelColor.warning = ""
                levelColor.error = ""
            }
        }
    }

    /// Lock for thread-safe file handle access.
    private var fileHandleLock = os_unfair_lock()

    /// Controls whether to use NSFileCoordinator for file access coordination.
    /// Set to true for document-based apps, app extensions, or iCloud scenarios (default).
    /// Set to false for better performance in simple logging scenarios.
    public var useFileCoordination: Bool = true

    // LOGFILE ROTATION
    // ho many bytes should a logfile have until it is rotated?
    // default is 5 MB. Just is used if logFileAmount > 1
    public var logFileMaxSize = (5 * 1024 * 1024)
    // Number of log files used in rotation, default is 1 which deactivates file rotation
    public var logFileAmount = 1

    override public var defaultHashValue: Int { return 2 }

    /// Internal shared file manager.
    private let fileManager = FileManager.default

    /// Initializes a new FileDestination with the given file write mode and label.
    /// - Parameters:
    ///   - fileWriteMode: The mode in which the file is written to.
    ///   - label: The label for the destination.
    public init(fileWriteMode: FileWriteMode, label: String = UUID().uuidString) {
        self.fileWriteMode = fileWriteMode
        super.init(label: label)
    }

    /// Initializes a new FileDestination with the given log file URL and label.
    /// - Parameters:
    ///   - logFileURL: The URL of the log file.
    ///   - label: The label for the destination.
    public convenience init(logFileURL: URL? = nil, label: String = UUID().uuidString) {
        let fileURL = logFileURL ?? FileDestination.logFileURLForLegacy()
        self.init(fileWriteMode: .fileURL(fileURL), label: label)
    }

    /// Initializes a new FileDestination with the given log file handle and label.
    /// - Parameters:
    ///   - logFileHandle: The file handle to write to.
    ///   - label: The label for the destination.
    public convenience init(logFileHandle: FileHandle, label: String = UUID().uuidString) {
        self.init(fileWriteMode: .fileHandle(logFileHandle), label: label)
    }

    /// Initializes a new FileDestination with the given log file URL and log file handle and label.
    /// - Parameters:
    ///   - logFileURL: The URL of the log file.
    ///   - logFileHandle: The file handle to write to.
    ///   - label: The label for the destination.
    public convenience init(logFileURL: URL?, logFileHandle: FileHandle, label: String = UUID().uuidString) {
        self.init(fileWriteMode: .hybrid(logFileURL ?? FileDestination.logFileURLForLegacy(), logFileHandle), label: label)
    }

    // append to file. uses full base class functionality
    override open func send(_ level: SwiftyBeaver.Level, msg: String, thread: String,
                            file: String, function: String, line: Int, context: SendableAny? = nil) -> String?
    {
        let formattedString = super.send(level, msg: msg, thread: thread, file: file, function: function, line: line, context: context)

        if let str = formattedString {
            validateSaveFile(str: str)
        }
        return formattedString
    }

    // check if filesize is bigger than wanted and if yes then rotate them
    func validateSaveFile(str: String) {
        // check if file rotation is enabled and if the log file exists
        if logFileAmount > 1, let url = logFileURL {
            let filePath = url.path
            if fileManager.fileExists(atPath: filePath) {
                do {
                    // Get file size
                    let attr = try fileManager.attributesOfItem(atPath: filePath)
                    // Do file rotation
                    if let fileSize = attr[FileAttributeKey.size] as? UInt64,
                       fileSize > logFileMaxSize
                    {
                        rotateFile(url)
                    }
                } catch {
                    print("validateSaveFile error: \(error)")
                }
            }
        }

        // check if the log file handle exists and if it does, validate it
        if let logFileHandle {
            validateLogFileHandle(logFileHandle)
        }

        // save the string to the file
        saveToFile(str: str)
    }

    /// Appends a string as line to a file.
    func saveToFile(str: String) {
        let line = str + "\n"
        guard let data = line.data(using: .utf8) else { return }
        write(data: data)
    }

    /// Writes data to the log file.
    private func write(data: Data) {
        #if os(Linux)
            return
        #endif

        // Write to logFileURL
        if let logFileURL {
            performFileWrite(data: data, toFileURL: logFileURL, useCoordination: useFileCoordination)
        }

        // Write to logFileHandle
        if let logFileHandle {
            performFileWrite(data: data, toFileHandle: logFileHandle)
        }
    }

    /// Performs the actual file write operation to the logFileURL
    private func performFileWrite(data: Data, toFileURL url: URL, useCoordination: Bool) {
        let fileWriteOperation: () -> Void = { [weak self] in
            guard let self else { return }

            do {
                if fileManager.fileExists(atPath: url.path) == false {
                    let directoryURL = url.deletingLastPathComponent()
                    if fileManager.fileExists(atPath: directoryURL.path) == false {
                        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    }
                    _ = fileManager.createFile(atPath: url.path, contents: nil)

                    #if os(iOS) || os(watchOS)
                        if #available(iOS 10.0, watchOS 3.0, *) {
                            var attributes = try fileManager.attributesOfItem(atPath: url.path)
                            attributes[FileAttributeKey.protectionKey] = FileProtectionType.none
                            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
                        }
                    #endif
                }

                let fileHandle = try FileHandle(forWritingTo: url)
                try write(data: data, toFileHandle: fileHandle)
            } catch {
                print("SwiftyBeaver File Destination could not write to file \(url).")
            }
        }

        if useCoordination {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var error: NSError?
            coordinator.coordinate(writingItemAt: url, error: &error) { _ in
                fileWriteOperation()
            }
            if let error = error {
                print("Failed writing file with error: \(String(describing: error))")
            }
        } else {
            fileWriteOperation()
        }
    }

    /// Performs the actual file write operation to the logFileHandle
    private func performFileWrite(data: Data, toFileHandle fileHandle: FileHandle) {
        writeData(data, toLogFileHandle: fileHandle)
    }

    @discardableResult
    private func write(data: Data, toFileHandle fileHandle: FileHandle, closeWhenFinish: Bool = true) throws -> Bool {
        #if os(Linux)
            return true
        #else
            if #available(iOS 13.4, watchOS 6.2, tvOS 13.4, macOS 10.15.4, *) {
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
                if syncAfterEachWrite {
                    try fileHandle.synchronize()
                }
                if closeWhenFinish {
                    try fileHandle.close()
                }
            } else {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                if syncAfterEachWrite {
                    fileHandle.synchronizeFile()
                }
                if closeWhenFinish {
                    fileHandle.closeFile()
                }
            }
            return true
        #endif
    }

    /// deletes log file.
    /// returns true if file was removed or does not exist, false otherwise
    public func deleteLogFile() -> Bool {
        guard let url = logFileURL, fileManager.fileExists(atPath: url.path) == true else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            print("SwiftyBeaver File Destination could not remove file \(url).")
            return false
        }
    }
}

// MARK: - File Write Mode

public extension FileDestination {
    enum FileWriteMode: Sendable {
        case fileURL(URL)
        case fileHandle(FileHandle)
        case hybrid(URL, FileHandle)
    }

    private var logFileURL: URL? {
        switch fileWriteMode {
        case let .fileURL(url):
            return url
        case .fileHandle:
            return nil
        case let .hybrid(url, _):
            return url
        }
    }

    private var logFileHandle: FileHandle? {
        switch fileWriteMode {
        case .fileURL:
            return nil
        case let .fileHandle(fileHandle):
            return fileHandle
        case let .hybrid(_, fileHandle):
            return fileHandle
        }
    }
}

// MARK: - File Rotation

private extension FileDestination {
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

    func makeRotatedFileUrl(_ fileUrl: URL, index: Int) -> URL {
        // The index is appended to the file name, to preserve the original extension.
        fileUrl.deletingPathExtension()
            .appendingPathExtension("\(index).\(fileUrl.pathExtension)")
    }
}

// MARK: - LogFileHandle

extension FileDestination {
    private func validateLogFileHandle(_ fileHandle: FileHandle) {
        withFileHandleLock {
            let logFileSize = fileHandle.getSize()
            guard logFileSize > self.logFileMaxSize else { return }
            if #available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *) {
                do {
                    try fileHandle.truncate(atOffset: 0)
                } catch {
                    print("SwiftyBeaver File Destination could not truncate logFileHandle: \(String(describing: error)).")
                }
            } else {
                fileHandle.truncateFile(atOffset: 0)
            }
        }
    }

    private func writeData(_ data: Data, toLogFileHandle fileHandle: FileHandle) {
        withFileHandleLock {
            do {
                try self.write(data: data, toFileHandle: fileHandle, closeWhenFinish: false)
            } catch {
                print("SwiftyBeaver File Destination could not write to logFileHandle: \(String(describing: error)).")
            }
        }
    }

    /// Executes the given block while holding the file handle lock.
    private func withFileHandleLock<T>(_ block: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&fileHandleLock)
        defer { os_unfair_lock_unlock(&fileHandleLock) }
        return try block()
    }
}

// MARK: - LogFileURL for legacy support

extension FileDestination {
    static func logFileURLForLegacy() -> URL {
        var fileURL: URL
        #if os(Linux)
            fileURL = URL(fileURLWithPath: "/var/cache")
        #else
            let cachesDirectory = URL.cachesDirectory()
            fileURL = cachesDirectory
            #if os(macOS)
                // try to use ~/Library/Caches/APP NAME instead of ~/Library/Caches
                if let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String {
                    do {
                        fileURL = fileURL.appendingPath(appName, isDirectory: true)
                        if !FileManager.default.fileExists(atPath: fileURL.path) {
                            try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true, attributes: nil)
                        }
                    } catch {
                        print("Warning! Could not create folder ~/Library/Caches/\(appName)")
                        // fallback to ~/Library/Caches
                        fileURL = cachesDirectory
                    }
                }
            #endif
        #endif
        fileURL = fileURL.appendingPath("swiftybeaver.log", isDirectory: false)
        return fileURL
    }
}
