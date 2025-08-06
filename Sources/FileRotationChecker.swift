//
//  FileRotationChecker.swift
//  SwiftyBeaver
//
//  Created by Sebastian Kreutzberger on 05.12.15.
//  Copyright © 2015 Sebastian Kreutzberger
//  Some rights reserved: http://opensource.org/licenses/MIT
//

import Foundation
import os.lock

// MARK: - FileRotationChecker

/// A smart file rotation checker that adaptively determines when to check file size
/// to optimize performance while ensuring timely log rotation.
final class FileRotationChecker: @unchecked Sendable {
    // MARK: - Configuration

    /// Minimum number of writes before checking file size
    private let minCheckInterval: Int = 10

    /// Maximum number of writes before forcing a file size check
    private let maxCheckInterval: Int = 1000

    /// Safety factor to ensure we check before reaching the limit (Golden ratio)
    private let safetyFactor: Double = 0.618

    /// Maximum number of recent samples to keep for average calculation
    private let maxSampleCount: Int = 5

    // MARK: - Lock

    /// Thread-safe lock for protecting internal state
    private let lock = UnfairLock()

    // MARK: - State

    /// Estimated current file size (accumulated from write operations)
    private var estimatedFileSize: Int64

    /// Last actual file size from file system check
    private var lastActualFileSize: Int64

    /// Number of writes remaining before next check
    private var nextCheckInterval: Int

    /// Recent file size increases to calculate moving average (as precise averages)
    private var recentSizeSamples: [Double] = []

    /// Estimated average size increase per write
    private var perAverageSize: Int64 = 0

    /// Number of consecutive estimation errors
    private var consecutiveEstimationErrors: Int = 0

    /// Total number of writes since last check
    private var writesSinceLastCheck: Int = 0

    // MARK: - Initialization

    /// Initializes the checker with current file size
    /// - Parameters:
    ///   - initialFileSize: Current size of the log file
    init(initialFileSize: Int64 = 0) {
        estimatedFileSize = initialFileSize
        lastActualFileSize = initialFileSize
        nextCheckInterval = 1 // Check immediately on first write
        perAverageSize = 0 // Will be updated after first check
    }

    // MARK: - Public Methods

    /// Determines if a file size check should be performed
    func shouldCheckFileSize() -> Bool {
        return lock.withLock {
            nextCheckInterval -= 1
            return nextCheckInterval <= 0
        }
    }

    /// Records a write operation
    /// - Parameter estimatedWriteSize: Estimated size of the log entry being written
    func recordWrite(estimatedWriteSize: Int64) {
        lock.withLock {
            // Update estimated current size
            estimatedFileSize += estimatedWriteSize
            // Update write counter
            writesSinceLastCheck += 1
        }
    }

    /// Updates the checker with actual file size after a check
    /// - Parameters:
    ///   - actualFileSize: The actual file size from file system
    ///   - maxFileSize: Maximum allowed file size before rotation
    func updateWithActualSize(_ actualFileSize: Int64, maxFileSize: Int64) {
        lock.withLock {
            // Calculate estimation error (difference between estimated and actual)
            let sizeDifference = actualFileSize - estimatedFileSize
            let estimationError = abs(sizeDifference)

            // Update estimation error tracking
            let errorThreshold = Double(estimatedFileSize) / 10.0 // 10% of estimated size
            if Double(estimationError) > errorThreshold {
                consecutiveEstimationErrors += 1
            } else {
                consecutiveEstimationErrors = 0
            }

            // Calculate actual size increase since last check
            let sizeIncrease = actualFileSize - lastActualFileSize
            updateAverageSize(sizeIncrease: sizeIncrease, estimatedWriteSize: estimatedFileSize)

            // Update our tracking variables
            lastActualFileSize = actualFileSize
            estimatedFileSize = actualFileSize // Reset estimation to actual value

            // Calculate next check interval
            calculateNextCheckInterval(currentSize: actualFileSize, maxSize: maxFileSize)

            // Reset write counter
            writesSinceLastCheck = 0
        }
    }

    /// Estimates the size of a log entry
    /// - Parameter logString: The log string to be written
    /// - Returns: Estimated size in bytes
    static func estimateWriteSize(_ logString: String) -> Int64 {
        // UTF-8 encoding + newline character
        return Int64(logString.utf8.count + 1)
    }

    /// Thread-safe reset of all internal state
    func reset() {
        lock.withLock {
            nextCheckInterval = 1
            writesSinceLastCheck = 0
            consecutiveEstimationErrors = 0
            recentSizeSamples.removeAll()
            perAverageSize = 0
        }
    }

    // MARK: - Private Methods

    /// Updates the moving average of size increases
    private func updateAverageSize(sizeIncrease: Int64, estimatedWriteSize: Int64) {
        // If the size increase is 0 or the number of writes since last check is 0, means no write has been made since last check
        guard writesSinceLastCheck > 0, sizeIncrease > 0 else { return }

        // Use precise floating-point calculation
        let averageIncreasePerWrite = Double(sizeIncrease) / Double(writesSinceLastCheck)

        // Add to recent samples
        if averageIncreasePerWrite > 0 {
            recentSizeSamples.append(averageIncreasePerWrite)
        }

        // Keep only recent samples
        if recentSizeSamples.count > maxSampleCount {
            recentSizeSamples.removeFirst()
        }

        // Calculate moving average with floating-point precision
        if !recentSizeSamples.isEmpty {
            let preciseAverage = recentSizeSamples.reduce(0.0, +) / Double(recentSizeSamples.count)
            perAverageSize = Int64(preciseAverage.rounded()) // Round to nearest integer
        }

        // Ensure minimum reasonable size
        perAverageSize = max(10, perAverageSize)
    }

    /// Calculates the next check interval based on current state
    private func calculateNextCheckInterval(currentSize: Int64, maxSize: Int64) {
        // Calculate based on remaining space and average write size
        guard perAverageSize > 0 else {
            nextCheckInterval = minCheckInterval
            return
        }

        // Handle degraded estimation case
        if consecutiveEstimationErrors > 3 {
            nextCheckInterval = maxCheckInterval / 2 // More frequent checks
            consecutiveEstimationErrors = 0
            return
        }

        let remainingSize: Int64 = maxSize - currentSize

        let estimatedWritesRemaining = Double(remainingSize) / Double(perAverageSize)
        let safeInterval = Int(estimatedWritesRemaining * safetyFactor)

        // Apply boundaries
        nextCheckInterval = max(minCheckInterval, min(maxCheckInterval, safeInterval))
    }
}
