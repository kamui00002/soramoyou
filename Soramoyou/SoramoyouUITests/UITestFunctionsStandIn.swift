//
//  UITestFunctionsStandIn.swift
//  SoramoyouUITests
//
//  退会のテストのあいだだけ、Functions の Emulator の代わりに返事をする受け口 ⭐️☁️
//
//  - アプリの退会は、データを消す前に Functions の soratomoDeleteMyData（そらともの削除）を呼ぶ
//    （SettingsViewModel.performReauthAndDelete）。UI テストのアプリは Functions を 127.0.0.1:5001 に向けるが、
//    テストで起こす Emulator は auth・firestore・storage だけなので、そこには何もいない。
//    そのままだと退会は最初の呼び出しで失敗し、写真を消す処理まで進まない
//  - そこで、この受け口が 127.0.0.1:5001 で待ち、soratomoDeleteMyData にだけ「完了」を返す
//  - ⚠️ そらともの削除は偽物。このテストが確かめるのは、そのあとの Storage と Firestore の削除だけ
//  - 待つのはこの Mac の中（127.0.0.1）だけ。外へは何も送らない
//

import Foundation
import Network

/// soratomoDeleteMyData にだけ「完了」を返す、テスト用の受け口
final class UITestFunctionsStandIn: @unchecked Sendable {
    /// Functions の Emulator のポート（FirebaseEmulatorSwitch.functionsPort と同じ）
    static let port: UInt16 = 5001
    /// アプリが呼ぶ道（Emulator の Callable は `/<プロジェクト>/<region>/<関数名>`。
    /// region は SoratomoGroupService.region、関数名は SoratomoAccountDeletionService.callableName と同じ）
    static let callablePath = "/\(UITestEmulatorSeeder.projectID)/asia-northeast1/soratomoDeleteMyData"

    private let listener: NWListener
    /// 受け口の処理は全部この列で動かす（数えた回数もこの列で読み書きする）
    private let queue = DispatchQueue(label: "uitest.functions.standin")
    private var answered = 0
    private var requests: [String] = []

    /// soratomoDeleteMyData に「完了」を返した回数
    var answeredCount: Int { queue.sync { answered } }

    /// 届いた要求の記録（届いた順。1 件は「POST /道 → 200」の形）。失敗の理由に出して、どこへ何が届いたかを読む
    var receivedRequests: [String] { queue.sync { requests } }

    /// - Throws: 受け口を作れないとき
    init() throws {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw StandInError.cannotStart("ポート \(Self.port) を作れない")
        }
        let parameters = NWParameters.tcp
        // この Mac の中からだけ届く住所で待つ
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// 待ち始める。待てる状態になるまで戻らない
    /// - Throws: 5 秒たっても待てない・ポートがふさがっているとき
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case let .failed(error):
                failure.message = "\(error)"
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw StandInError.cannotStart("5 秒たっても 127.0.0.1:\(Self.port) で待てない")
        }
        if let message = failure.message {
            throw StandInError.cannotStart("127.0.0.1:\(Self.port) で待てない（ほかが使っていないか確かめる）：\(message)")
        }
    }

    /// 待つのをやめる
    func stop() {
        listener.cancel()
    }

    // MARK: - 受け取りと返事

    /// 要求を最後まで受け取ってから返事をする（頭の部分と、Content-Length の分の本文）
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.parse(buffer) {
                respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    /// 返事を送って、つなぎを閉じる
    private func respond(to request: (method: String, path: String), on connection: NWConnection) {
        let status: String
        let json: String
        if request.method == "POST", request.path == Self.callablePath {
            // Callable の返事の形。アプリ（SoratomoAccountDeletionService.doneValue）は result の done を読む
            status = "200 OK"
            json = #"{"result":{"done":true}}"#
            answered += 1
        } else {
            // ほかの関数の代わりはしない
            status = "404 Not Found"
            json = #"{"error":{"status":"NOT_FOUND","message":"UI テストの代役は soratomoDeleteMyData だけに返事をする"}}"#
        }
        // 代役の返事も含めて、届いたものを全部記録する
        requests.append("\(request.method) \(request.path) → \(status)")
        let body = Data(json.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 受け取った分から、メソッドと道を読む。まだ全部届いていなければ nil
    private static func parse(_ buffer: Data) -> (method: String, path: String)? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex ..< headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        // 1 行目は「POST /道 HTTP/1.1」
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }

        // 本文が全部届くまで待つ
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let received = buffer.distance(from: headEnd.upperBound, to: buffer.endIndex)
        guard received >= contentLength else { return nil }

        // 道は「?」より前だけを比べる
        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return (String(parts[0]), path)
    }

    /// 待ち始めの失敗を受け渡す箱（状態の知らせは別のスレッドで届く）
    private final class FailureBox: @unchecked Sendable {
        var message: String?
    }

    /// 受け口の失敗
    enum StandInError: LocalizedError {
        /// 待ち始められない
        case cannotStart(String)

        var errorDescription: String? {
            switch self {
            case let .cannotStart(detail):
                "Functions の代役を起こせない：\(detail)"
            }
        }
    }
}
