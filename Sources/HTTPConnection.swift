//
//  HTTPConnection.swift
//  FlyingFox
//
//  Created by Simon Whitty on 13/02/2022.
//  Copyright © 2022 Simon Whitty. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/FlyingFox
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

struct HTTPConnection {

    let hostname: String
    private let socket: AsyncSocket
    let requests: HTTPRequestSequence<AsyncSocketReadSequence>

    init(socket: AsyncSocket) {
        self.socket = socket
        self.hostname = HTTPConnection.makeIdentifer(from: socket.socket)
        self.requests = HTTPRequestSequence(bytes: socket.bytes)
    }

    func sendResponse(_ response: HTTPResponse) async throws {
        try await socket.write(HTTPEncoder.encodeResponse(response))

        if case let .webSocket(handler) = response.payload {
            requests.isComplete = true
            for try await frame in try await handler.makeSocketFrames(for: WSFrameSequence(socket.bytes)) {
                try await socket.write(WSFrameEncoder.encodeFrame(frame))
            }
        }
    }

    func close() throws {
        try socket.close()
    }
}

final class HTTPRequestSequence<S: ChunkedAsyncSequence>: AsyncSequence, AsyncIteratorProtocol where S.Element == UInt8 {
    typealias Element = HTTPRequest
    private let bytes: S
    fileprivate var isComplete: Bool

    init(bytes: S) {
        self.bytes = bytes
        self.isComplete = false
    }

    func makeAsyncIterator() -> HTTPRequestSequence { self }

    func next() async throws -> HTTPRequest? {
        guard !isComplete else { return nil }

        do {
            let request = try await HTTPDecoder.decodeRequest(from: bytes)
            if !request.shouldKeepAlive {
                isComplete = true
            }
            return request
        } catch SocketError.disconnected {
            return nil
        } catch is SequenceTerminationError {
            return nil
        } catch {
            throw error
        }
    }
}

extension HTTPConnection {

    static func makeIdentifer(from socket: Socket) -> String {
        guard let peer = try? socket.remotePeer() else {
            return "<unknown>"
        }

        if case .unix = peer, let unixAddress = try? socket.sockname() {
            return makeIdentifer(from: unixAddress)
        } else {
            return makeIdentifer(from: peer)
        }
    }

    static func makeIdentifer(from peer: Socket.Address) -> String {
        switch peer {
        case .ip4(let address, port: _):
            return address
        case .ip6(let address, port: _):
            return address
        case .unix(let path):
            return path
        }
    }
}
