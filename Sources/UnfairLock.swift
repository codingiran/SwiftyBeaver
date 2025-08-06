//
//  UnfairLock.swift
//  SwiftyBeaver
//
//  Created by CodingIran on 2025/8/6.
//

import Foundation
import os.lock

public final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock()

    public func lock() {
        os_unfair_lock_lock(&_lock)
    }

    public func unlock() {
        os_unfair_lock_unlock(&_lock)
    }

    public func tryLock() -> Bool {
        return os_unfair_lock_trylock(&_lock)
    }

    public func withLock<R>(_ body: @Sendable () throws -> R) rethrows -> R where R: Sendable {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return try body()
    }
}
