import Foundation

// 1.0.6 고침: 잠자기에서 깨어난 직후 앱이 꺼졌다 (EXC_BREAKPOINT, CheckedContinuation.resume(throwing:)).
// URLSessionStreamTask의 readData/write 완료 처리가 끊긴 연결에서 두 번 불리면,
// Swift가 자동으로 만든 async 버전은 continuation을 두 번 이어 가려다 앱을 멈춘다.
// 여기서는 완료 처리를 직접 받아 처음 한 번만 넘기고 나머지는 버린다.

/// continuation을 한 번만 이어 가게 지키는 상자 (완료 처리는 아무 스레드에서나 올 수 있다)
nonisolated private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// 읽은 결과 (Data는 Sendable이므로 튜플 대신 이것으로 넘긴다)
nonisolated struct StreamRead: Sendable {
    let data: Data?
    let atEOF: Bool
}

nonisolated extension URLSessionStreamTask {
    /// `readData(ofMinLength:maxLength:timeout:)`와 같지만 완료 처리가 두 번 와도 앱이 꺼지지 않는다
    func readOnce(ofMinLength min: Int, maxLength max: Int, timeout: TimeInterval) async throws -> (Data?, Bool) {
        let r: StreamRead = try await withCheckedThrowingContinuation { c in
            let box = OnceBox(c)
            readData(ofMinLength: min, maxLength: max, timeout: timeout) { data, atEOF, error in
                if let error { box.resume(with: .failure(error)) }
                else { box.resume(with: .success(StreamRead(data: data, atEOF: atEOF))) }
            }
        }
        return (r.data, r.atEOF)
    }

    /// `write(_:timeout:)`와 같지만 완료 처리가 두 번 와도 앱이 꺼지지 않는다
    func writeOnce(_ data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = OnceBox(c)
            write(data, timeout: timeout) { error in
                if let error { box.resume(with: .failure(error)) } else { box.resume(with: .success(())) }
            }
        }
    }
}
