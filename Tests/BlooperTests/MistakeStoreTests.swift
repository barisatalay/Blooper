import XCTest
@testable import Blooper

final class MistakeStoreTests: XCTestCase {
    func testReloadParsesFile() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m-\(UUID().uuidString).jsonl")
        try #"{"ts":"2026-08-11T14:02:11Z","wrong":"a","right":"b","rule":"c"}"#.write(to: f, atomically: true, encoding: .utf8)
        let store = MistakeStore(fileURL: f)
        store.reload()
        XCTAssertEqual(store.mistakes.count, 1)
    }

    func testWatchPicksUpAppendedLine() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m-\(UUID().uuidString).jsonl")
        try "".write(to: f, atomically: true, encoding: .utf8)
        let store = MistakeStore(fileURL: f)
        store.reload(); store.startWatching()
        let exp = expectation(description: "new mistakes callback")
        store.onNewMistakes = { fresh in
            XCTAssertEqual(fresh.first?.wrong, "I am agree")
            exp.fulfill()
        }
        let h = FileHandle(forWritingAtPath: f.path)!
        h.seekToEndOfFile()
        h.write(#"{"ts":"2026-08-11T14:02:11Z","wrong":"I am agree","right":"I agree","rule":"r"}"#.data(using: .utf8)! + "\n".data(using: .utf8)!)
        try h.close()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(store.mistakes.count, 1)
    }
}
