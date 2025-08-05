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
    private lazy var fileHandleLock = os_unfair_lock()

    /// Lock for thread-safe rotation checker access.
    lazy var rotationCheckerLock = os_unfair_lock()

    /// Smart file rotation checker for performance optimization.
    var rotationChecker: FileRotationChecker?

    /// Controls whether to use NSFileCoordinator for file access coordination.
    /// Set to true for document-based apps, app extensions, or iCloud scenarios (default).
    /// Set to false for better performance in simple logging scenarios.
    public var useFileCoordination: Bool = true

    // LOGFILE ROTATION
    // ho many bytes should a logfile have until it is rotated?
    // default is 5 MB. Just is used if logFileAmount > 1
    public var logFileMaxSize = (5 * 1024 * 1024) {
        didSet {
            if logFileMaxSize != oldValue {
                resetRotationChecker()
            }
        }
    }

    // Number of log files used in rotation, default is 1 which deactivates file rotation
    public var logFileAmount = 1 {
        didSet {
            if logFileAmount != oldValue {
                resetRotationChecker()
            }
        }
    }

    override public var defaultHashValue: Int { return 2 }

    /// Internal shared file manager.
    let fileManager = FileManager.default

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
            // validate the file size and perform rotation if needed
            validateSaveFile(str: str)
            // save the string to the file
            saveToFile(str: str)
        }
        return formattedString
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
        let fileWriteOperation: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            guard let fileHandle = fileHandleForWriting(at: url) else {
                print("SwiftyBeaver could not create write file handle at \(url).")
                return
            }
            do {
                try write(data: data, toFileHandle: fileHandle)
            } catch {
                print("SwiftyBeaver File Destination could not write to file \(url).")
            }
        }

        if useCoordination || asynchronously {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var error: NSError?
            coordinator.coordinate(writingItemAt: url, error: &error) { url in
                fileWriteOperation(url)
            }
            if let error = error {
                print("Failed writing file with error: \(String(describing: error))")
            }
        } else {
            fileWriteOperation(url)
        }
    }

    private func fileHandleForWriting(at url: URL) -> FileHandle? {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            return fileHandle
        }
        // FileHandle create failed, maybe it's not exist
        do {
            try createLogFile(url)
            return try? FileHandle(forWritingTo: url)
        } catch {
            return nil
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
            try fileHandle.seekToFileEnd()
            try fileHandle.writeData(data)
            if syncAfterEachWrite {
                try fileHandle.syncFileHandle()
            }
            if closeWhenFinish {
                try fileHandle.closeFileHandle()
            }
            return true
        #endif
    }

    private func createLogFile(_ logFileURL: URL) throws {
        let logFilePath = logFileURL.urlPath(percentEncoded: false)
        guard !fileManager.fileExists(atPath: logFilePath) else { return }
        let directoryURL = logFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(at: directoryURL) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        _ = fileManager.createFile(atPath: logFilePath, contents: nil)

        #if os(iOS) || os(watchOS)
            if #available(iOS 10.0, watchOS 3.0, *) {
                var attributes = try fileManager.attributesOfItem(atPath: logFilePath)
                attributes[FileAttributeKey.protectionKey] = FileProtectionType.none
                try fileManager.setAttributes(attributes, ofItemAtPath: logFilePath)
            }
        #endif
    }

    /// deletes log file.
    /// returns true if file was removed or does not exist, false otherwise
    public func deleteLogFile() -> Bool {
        guard let logFileURL, fileManager.fileExists(at: logFileURL) else { return true }
        do {
            try fileManager.removeItem(at: logFileURL)
            return true
        } catch {
            print("SwiftyBeaver File Destination could not remove file \(logFileURL).")
            return false
        }
    }
}

// MARK: - File Write Mode

public extension FileDestination {
    enum FileWriteMode: Sendable, Equatable {
        case fileURL(URL)
        case fileHandle(FileHandle)
        case hybrid(URL, FileHandle)
    }

    internal var logFileURL: URL? {
        switch fileWriteMode {
        case let .fileURL(url):
            return url
        case .fileHandle:
            return nil
        case let .hybrid(url, _):
            return url
        }
    }

    internal var logFileHandle: FileHandle? {
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

// MARK: - LogFileHandle

extension FileDestination {
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
    func withFileHandleLock<T>(_ block: () throws -> T) rethrows -> T {
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
                        if !FileManager.default.fileExists(at: fileURL) {
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
