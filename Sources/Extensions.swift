//
//  Extensions.swift
//  SwiftyBeaver
//
//  Created by Sebastian Kreutzberger on 13.12.17.
//  Copyright © 2017 Sebastian Kreutzberger. All rights reserved.
//

import Foundation

extension String {
    /// cross-Swift compatible characters count
    var length: Int {
        return count
    }

    /// cross-Swift-compatible first character
    var firstChar: Character? {
        return first
    }

    /// cross-Swift-compatible last character
    var lastChar: Character? {
        return last
    }

    /// cross-Swift-compatible index
    func find(_ char: Character) -> Index? {
        #if swift(>=5)
            return firstIndex(of: char)
        #else
            return index(of: char)
        #endif
    }
}

extension FileHandle {
    /// Check if the file was deleted on the file system. Linux keep the file alive, as long as some processes have it open.
    var wasDeleted: Bool {
        var stats = stat()
        guard fstat(fileDescriptor, &stats) != -1 else {
            let error = String(cString: strerror(errno))
            fatalError("fstat failed on open file descriptor. Error \(errno) \(error)")
        }
        // This field contains the number of hard links to the file.
        return stats.st_nlink == 0
    }

    var isExsists: Bool {
        fstat(fileDescriptor, nil) == 0
    }

    var isRegularFile: Bool {
        var inodeInfo = stat()
        guard fstat(fileDescriptor, &inodeInfo) == 0 else {
            return false
        }
        return (inodeInfo.st_mode & S_IFMT) == S_IFREG
    }

    var isDirectory: Bool {
        var inodeInfo = stat()
        guard fstat(fileDescriptor, &inodeInfo) == 0 else {
            return false
        }
        return (inodeInfo.st_mode & S_IFMT) == S_IFDIR
    }

    func getSize() -> Int {
        var inodeInfo = stat()
        guard fstat(fileDescriptor, &inodeInfo) == 0 else {
            return 0
        }
        return Int(inodeInfo.st_size)
    }
}

extension URL {
    init(fileURLPath path: String, isDirectory: Bool) {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            self.init(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        } else {
            self.init(fileURLWithPath: path)
        }
    }

    func appendingPath(_ path: String, isDirectory: Bool) -> URL {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            return self.appending(path: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        } else {
            return appendingPathComponent(path, isDirectory: isDirectory)
        }
    }

    static func cachesDirectory() -> URL {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            return URL.cachesDirectory
        } else {
            let cachesDirectoryPath = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? "\(NSHomeDirectory())/Library/Caches"
            return URL(fileURLPath: cachesDirectoryPath, isDirectory: true)
        }
    }

    func urlPath(percentEncoded: Bool = true) -> String {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            return self.path(percentEncoded: percentEncoded)
        } else {
            return path
        }
    }
}

public extension FileHandle {
    /// Writes data to the file handle.
    /// - Parameters:
    ///   - data: The data to write.
    ///   - syncAfterEachWrite: Whether to sync the file handle after each write.
    ///   - closeWhenFinish: Whether to close the file handle when the write is finished.
    /// - Returns: True if the write was successful, false otherwise.
    @discardableResult
    func writeDataToFileEnd(_ data: Data,
                            syncAfterEachWrite: Bool = true,
                            closeWhenFinish: Bool = true) throws -> Bool
    {
        #if os(Linux)
            return true
        #else
            try seekToFileEnd()
            try writeData(data)
            if syncAfterEachWrite {
                try syncFileHandle()
            }
            if closeWhenFinish {
                try closeFileHandle()
            }
            return true
        #endif
    }

    @discardableResult
    func seekToFileEnd() throws -> UInt64 {
        if #available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, visionOS 1.0, *) {
            return try seekToEnd()
        } else {
            return seekToEndOfFile()
        }
    }

    func syncFileHandle() throws {
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, visionOS 1.0, *) {
            try synchronize()
        } else {
            synchronizeFile()
        }
    }

    func closeFileHandle() throws {
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, visionOS 1.0, *) {
            try close()
        } else {
            closeFile()
        }
    }

    func writeData(_ data: Data) throws {
        if #available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, visionOS 1.0,*) {
            try write(contentsOf: data)
        } else {
            write(data)
        }
    }
}

public extension FileManager {
    func fileExists(at url: URL) -> Bool {
        let path = url.urlPath(percentEncoded: false)
        return fileExists(atPath: path)
    }

    func fileExists(at url: URL, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let path = url.urlPath(percentEncoded: false)
        return fileExists(atPath: path, isDirectory: isDirectory)
    }
}
