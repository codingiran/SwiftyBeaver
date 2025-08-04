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
