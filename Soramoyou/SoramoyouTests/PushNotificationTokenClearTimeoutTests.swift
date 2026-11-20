//
//  PushNotificationTokenClearTimeoutTests.swift
//  SoramoyouTests
//
//  ログアウトのときの FCM トークン削除を「時間切れつき」で待つ部品のテスト ⭐️
//  電波が無いと Firestore の updateData は返事をしない（取り消しにも反応しない）。
//  それでもログアウトが進むよう、決めた時間で待つのをやめて結果を返すことを確かめる。
//

@testable import Soramoyou
import XCTest

final class PushNotificationTokenClearTimeoutTests: XCTestCase {
    func testOperationThatDoesNotAnswerTimesOut() async {
        // 返事の無い操作（電波が無いときの updateData と同じ）は、待つ時間の上限で打ち切る
        // （偽物はキャンセルされても止まり続け、3 秒後にだけ返事をする。
        //   こうしておくと「子の終わりを待ってしまう形」は約 3 秒かかって下の時間の確かめで落ちる）
        let gate = HangingGate()
        Task {
            try? await Task.sleep(for: .seconds(3))
            gate.release()
        }
        let start = ContinuousClock.now

        let outcome = await PushNotificationManager.wait(atMost: .milliseconds(100)) {
            await gate.wait()
        }

        guard case .timedOut = outcome else {
            return XCTFail("timedOut を返すはず: \(outcome)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testOperationThatFinishesReturnsFinished() async {
        // 時間内に終わった操作は、終わったとして返す
        let outcome = await PushNotificationManager.wait(atMost: .seconds(5)) {}

        guard case .finished = outcome else {
            return XCTFail("finished を返すはず: \(outcome)")
        }
    }

    func testOperationThatFailsReturnsFailedNotTimedOut() async {
        // 時間内に失敗した操作は、時間切れでなく失敗として返す（投げない）
        let expected = NSError(domain: "TestDomain", code: 7)

        let outcome = await PushNotificationManager.wait(atMost: .seconds(5)) {
            throw expected
        }

        guard case let .failed(error) = outcome else {
            return XCTFail("failed を返すはず: \(outcome)")
        }
        XCTAssertEqual((error as NSError).domain, "TestDomain")
        XCTAssertEqual((error as NSError).code, 7)
    }
}

// MARK: - HangingGate

/// キャンセルを無視して止まり続け、`release()` でだけ返事をする偽物
/// - 電波が無いときの Firestore の async（中身は止まらない continuation）と同じふるまい
private final class HangingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// `release()` が呼ばれるまで返さない（呼ばれた後なら、すぐ返す）
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            waiting.append(continuation)
            lock.unlock()
        }
    }

    /// 待っている操作に返事をする
    func release() {
        lock.lock()
        released = true
        let all = waiting
        waiting = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}
