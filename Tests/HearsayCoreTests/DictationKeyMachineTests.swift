import XCTest
@testable import HearsayCore

final class DictationKeyMachineTests: XCTestCase {
    func run(_ events: [DictationKeyMachine.Event]) -> ([DictationKeyMachine.Action], DictationKeyMachine.State) {
        var m = DictationKeyMachine()
        let actions = events.map { m.handle($0) }
        return (actions, m.state)
    }

    func testHoldAndReleaseFinishes() {
        let (a, s) = run([.keyDown(at: 0), .keyUp(at: 1.2)])
        XCTAssertEqual(a, [.start, .finish])
        XCTAssertEqual(s, .idle)
    }

    func testReleaseAtExactlyLatchTimeFinishes() {
        XCTAssertEqual(run([.keyDown(at: 10), .keyUp(at: 10.3)]).0, [.start, .finish])
    }

    func testOtherKeyWhileHoldingCancelsAndSwallowsRelease() {
        let (a, s) = run([.keyDown(at: 0), .otherKey(escape: false), .keyUp(at: 2)])
        XCTAssertEqual(a, [.start, .cancel, .none])
        XCTAssertEqual(s, .idle)
    }

    func testShortPressLatchesUntilNextPress() {
        let (a, s) = run([.keyDown(at: 0), .keyUp(at: 0.1), .otherKey(escape: false), .otherKey(escape: false),
                          .keyDown(at: 5), .keyUp(at: 5.1)])
        XCTAssertEqual(a, [.start, .none, .none, .none, .finish, .none])
        XCTAssertEqual(s, .idle)
    }

    func testEscCancelsWhenLatched() {
        let (a, s) = run([.keyDown(at: 0), .keyUp(at: 0.2), .otherKey(escape: true)])
        XCTAssertEqual(a, [.start, .none, .cancel])
        XCTAssertEqual(s, .idle)
    }

    func testEscWhileHoldingCancels() {
        XCTAssertEqual(run([.keyDown(at: 0), .otherKey(escape: true)]).0, [.start, .cancel])
    }

    func testIdleIgnoresStrayEvents() {
        let (a, s) = run([.keyUp(at: 0), .otherKey(escape: true), .otherKey(escape: false)])
        XCTAssertEqual(a, [.none, .none, .none])
        XCTAssertEqual(s, .idle)
    }

    func testStartsAgainAfterFinish() {
        XCTAssertEqual(run([.keyDown(at: 0), .keyUp(at: 1), .keyDown(at: 2), .keyUp(at: 2.05)]).0,
                       [.start, .finish, .start, .none])
    }
}
