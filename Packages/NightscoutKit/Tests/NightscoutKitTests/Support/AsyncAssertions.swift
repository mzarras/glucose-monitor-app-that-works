// Original to Sensor (no ported code).
// XCTest's assertion macros take synchronous autoclosures, so `XCTAssertEqual(await x, y)` does not
// compile. These evaluate the async expressions first, then assert.

import XCTest

func XCTAssertEqualAsync<T: Equatable>(
    _ expression1: @autoclosure () async -> T,
    _ expression2: @autoclosure () async -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let value1 = await expression1()
    let value2 = await expression2()
    XCTAssertEqual(value1, value2, message(), file: file, line: line)
}

func XCTAssertTrueAsync(_ expression: @autoclosure () async -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    let value = await expression()
    XCTAssertTrue(value, message(), file: file, line: line)
}

func XCTAssertFalseAsync(_ expression: @autoclosure () async -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    let value = await expression()
    XCTAssertFalse(value, message(), file: file, line: line)
}

func XCTAssertNilAsync<T>(_ expression: @autoclosure () async -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    let value = await expression()
    XCTAssertNil(value, message(), file: file, line: line)
}

func XCTAssertGreaterThanAsync<T: Comparable>(_ expression1: @autoclosure () async -> T, _ expression2: @autoclosure () async -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    let value1 = await expression1()
    let value2 = await expression2()
    XCTAssertGreaterThan(value1, value2, message(), file: file, line: line)
}

func XCTAssertLessThanAsync<T: Comparable>(_ expression1: @autoclosure () async -> T, _ expression2: @autoclosure () async -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    let value1 = await expression1()
    let value2 = await expression2()
    XCTAssertLessThan(value1, value2, message(), file: file, line: line)
}

func XCTUnwrapAsync<T>(_ expression: @autoclosure () async -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = await expression()
    return try XCTUnwrap(value, message(), file: file, line: line)
}
