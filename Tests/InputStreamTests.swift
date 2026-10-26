#if canImport(Libtailscale)
import Foundation
import XCTest
@testable import AwgScale

final class InputStreamTests: XCTestCase {
    func testDataStreamReturnsBodyOnceThenEOFAndCloseIsIdempotent() throws {
        let body = Data("request body".utf8)
        let stream = DataInputStream(body)
        XCTAssertEqual(try stream.read(), body)
        XCTAssertTrue(try stream.read().isEmpty)
        try stream.close()
        try stream.close()
        XCTAssertTrue(try stream.read().isEmpty)
    }

    func testDataStreamClosedBeforeReadReturnsEOF() throws {
        let stream = DataInputStream(Data("request body".utf8))
        try stream.close()
        XCTAssertTrue(try stream.read().isEmpty)
    }

    func testFileStreamReadsChunksThenEOFAndCloseIsIdempotent() throws {
        let chunkSize = 256 * 1024
        let body = Data((0..<(chunkSize * 2 + 17)).map { UInt8($0 % 251) })
        let url = try writeTemporaryFile(body)
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try FileInputStream(url)
        defer { try? stream.close() }

        XCTAssertEqual(try stream.read(), body.subdata(in: 0..<chunkSize))
        XCTAssertEqual(try stream.read(), body.subdata(in: chunkSize..<(chunkSize * 2)))
        XCTAssertEqual(try stream.read(), body.subdata(in: (chunkSize * 2)..<body.count))
        XCTAssertTrue(try stream.read().isEmpty)
        XCTAssertTrue(try stream.read().isEmpty)
        try stream.close()
        try stream.close()
        XCTAssertTrue(try stream.read().isEmpty)
    }

    func testFileStreamRejectsDirectoryInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Foundation can reject a directory when opening it or on the first
        // read, depending on the OS. Neither failure may turn into silent EOF.
        XCTAssertThrowsError(try {
            let stream = try FileInputStream(directory)
            defer { try? stream.close() }
            _ = try stream.read()
        }())
    }

    func testDataStreamConcurrentReadsAndClosesAreSafe() throws {
        let body = Data(repeating: 42, count: 1024)
        let stream = DataInputStream(body)
        let results = StreamRaceResults()
        DispatchQueue.concurrentPerform(iterations: 256) { iteration in
            do {
                if iteration % 3 == 2 {
                    try stream.close()
                } else {
                    results.record(try stream.read())
                }
            } catch {
                results.record(error)
            }
        }
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertLessThanOrEqual(results.chunks.filter { !$0.isEmpty }.count, 1)
        XCTAssertTrue(results.chunks.allSatisfy { $0.isEmpty || $0 == body })
        XCTAssertTrue(try stream.read().isEmpty)
        try stream.close()
    }

    func testFileStreamConcurrentReadsAndClosesAreSafe() throws {
        let body = Data(repeating: 42, count: 256 * 1024 * 8)
        let url = try writeTemporaryFile(body)
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try FileInputStream(url)
        defer { try? stream.close() }
        let results = StreamRaceResults()
        DispatchQueue.concurrentPerform(iterations: 256) { iteration in
            do {
                if iteration % 3 == 2 {
                    try stream.close()
                } else {
                    results.record(try stream.read())
                }
            } catch {
                results.record(error)
            }
        }
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertLessThanOrEqual(results.chunks.reduce(0) { $0 + $1.count }, body.count)
        XCTAssertTrue(results.chunks.allSatisfy { $0.count <= 256 * 1024 && $0.allSatisfy { $0 == 42 } })
        XCTAssertTrue(try stream.read().isEmpty)
        try stream.close()
    }

    private func writeTemporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}

private final class StreamRaceResults {
    private let lock = NSLock()
    private(set) var chunks: [Data] = []
    private(set) var errors: [Error] = []

    func record(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(data)
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }
}
#endif
