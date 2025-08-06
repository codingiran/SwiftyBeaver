@testable import SwiftyBeaverTests
import XCTest

XCTMain([
    testCase(BaseDestinationTests.allTests),
    testCase(ConsoleDestinationTests.allTests),
    testCase(SwiftyBeaverTests.allTests),
    testCase(UnfairLockPerformanceTests.allTests),
])
