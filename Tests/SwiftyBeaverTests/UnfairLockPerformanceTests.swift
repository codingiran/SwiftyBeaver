//
//  UnfairLockPerformanceTests.swift
//  SwiftyBeaverTests
//
//  Created by CodingIran on 2025/8/6.
//

import Foundation
@testable import SwiftyBeaver
import XCTest

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

    class UnfairLockPerformanceTests: XCTestCase {
        // MARK: - Performance Test Constants

        private let iterations = 1_000_000

        // MARK: - Basic Performance Tests

        func testStructUnfairLockPerformance() {
            // Test result(M1 Max macOS 15.6):
            // 1_000_000 times locking using 0.142s
            measure {
                let lock = UnfairLock()

                // Test single-threaded performance
                for _ in 0 ..< iterations {
                    lock.withLock {
                        // Simulate some work
//                        _ = sqrt(Double.random(in: 1 ... 100))
                    }
                }
            }
        }

        // MARK: - Helper Methods

        private func measureTime(_ block: () -> Void) -> TimeInterval {
            let start = CFAbsoluteTimeGetCurrent()
            block()
            let end = CFAbsoluteTimeGetCurrent()
            return end - start
        }

        // MARK: - Linux Test Support

        nonisolated(unsafe) static var allTests = [
            ("testStructUnfairLockPerformance", testStructUnfairLockPerformance),
        ]
    }
#endif
