//
//  HTTPServerTests.swift
//  FlyingFox
//
//  Created by Simon Whitty on 22/02/2022.
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

@testable import FlyingFox
import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPServerTests: XCTestCase {

    let pool: AsyncSocketPool = PollingSocketPool()
    var task: Task<Void, Error>?

    override func setUp() {
        task = Task { try await pool.run() }
    }

    override func tearDown() {
        task?.cancel()
    }

    func testRequests_AreMatchedToHandlers_ViaRoute() async throws {
        let server = HTTPServer(port: 8008)

        await server.appendHandler(for: "/accepted") { _ in
            HTTPResponse.make(statusCode: .accepted)
        }
        await server.appendHandler(for: "/gone") { _ in
            HTTPResponse.make(statusCode: .gone)
        }

        var response = await server.handleRequest(.make(method: .GET, path: "/accepted"))
        XCTAssertEqual(
            response.statusCode,
            .accepted
        )

        response = await server.handleRequest(.make(method: .GET, path: "/gone"))
        XCTAssertEqual(
            response.statusCode,
            .gone
        )
    }

    func testUnmatchedRequests_Return404() async throws {
        let server = HTTPServer(port: 8008)

        let response = await server.handleRequest(.make(method: .GET, path: "/accepted"))
        XCTAssertEqual(
            response.statusCode,
            .notFound
        )
    }

    func testHandlerErrors_Return500() async throws {
        let server = HTTPServer(port: 8008)
        await server.appendHandler(for: "*") { _ in
            throw SocketError.disconnected
        }

        let response = await server.handleRequest(.make(method: .GET, path: "/accepted"))
        XCTAssertEqual(
            response.statusCode,
            .internalServerError
        )
    }

    func testHandlerTimeout_Returns500() async throws {
        let server = HTTPServer(port: 8008, timeout: 0.1)
        await server.appendHandler(for: "*") { _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return HTTPResponse.make(statusCode: .accepted)
        }

        let response = await server.handleRequest(.make(method: .GET, path: "/accepted"))
        XCTAssertEqual(
            response.statusCode,
            .internalServerError
        )
    }

    func testKeepAlive_IsAddedToResponses() async throws {
        let server = HTTPServer(port: 8008)

        var response = await server.handleRequest(
            .make(method: .GET, path: "/accepted", headers: [.connection: "keep-alive"])
        )
        XCTAssertTrue(
            response.shouldKeepAlive
        )

        response = await server.handleRequest(
            .make(method: .GET, path: "/accepted")
        )
        XCTAssertFalse(
            response.shouldKeepAlive
        )
    }

    func testServer_ReturnsFile_WhenFileHandlerIsMatched() async throws {
        let server = HTTPServer(port: 8009)
        await server.appendHandler(for: "*", handler: .file(named: "fish.json", in: .module))
        let task = Task { try await server.start() }

        let request = URLRequest(url: URL(string: "http://localhost:8009")!)
        let (data, _) = try await URLSession.shared.makeData(for: request)

        XCTAssertEqual(
            data,
            #"{"fish": "cakes"}"#.data(using: .utf8)
        )
        task.cancel()
    }

#if canImport(Darwin)
    func testServer_Returns500_WhenHandlerTimesout() async throws {
        let server = HTTPServer(port: 8008, timeout: 0.1)
        await server.appendHandler(for: "*") { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .make(statusCode: .ok)
        }
        let task = Task { try await server.start() }

        let request = URLRequest(url: URL(string: "http://localhost:8008")!)
        let (_, response) = try await URLSession.shared.makeData(for: request)

        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            500
        )
        task.cancel()
    }
#endif

    func testServerWithUnixSocket() async throws {
        let socket = try Socket(domain: AF_UNIX, type: Socket.stream)
        let addr = Socket.sockaddr_un(family: AF_UNIX, path: "a1")
        try? Socket.unlink(addr)
        try socket.bind(addr)
        try socket.listen()

        let server = HTTPServer(port: 8080)
        await server.appendHandler(for: "*") { _ in
            return HTTPResponse.make(statusCode: .accepted)
        }

        let task = Task {
            try await server.start(on: socket)
        }

        let socket1 = try Socket(domain: AF_UNIX, type: Socket.stream)
        let addr1 = Socket.sockaddr_un(family: AF_UNIX, path: "a2")
        try? Socket.unlink(addr1)
        try socket1.bind(addr1)
        try socket1.connect(addr)

        let asyncSocket1 = try AsyncSocket(socket: socket1, pool: pool)
        try await asyncSocket1.writeString(
            """
            GET /hello/world HTTP/1.1\r
            \r

            """
        )

        let response = try await asyncSocket1.readString(length: 21)
        XCTAssertEqual(
            response,
            "HTTP/1.1 202 Accepted"
        )
        task.cancel()
    }
}

extension Socket {

    static func sockaddr_un(family: Int32, path: String) -> sockaddr_un {
        var addr = Socket.sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let len = UInt8(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString {
                strncpy(ptr, $0, Int(len))
            }
        }

        #if canImport(Darwin)
        addr.sun_len = len
        #endif

        return addr
    }

    static func unlink(_ addr: sockaddr_un) throws {
        var addr = addr
        if Socket.unlink(&addr.sun_path.0) == -1 {
            throw SocketError.makeFailed("Unlink")
        }
    }

    func bind(_ addr: sockaddr_un) throws {
        var addr = addr
        let result = withUnsafePointer(to: &addr) {
            Socket.bind(file, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_un>.size))
        }

        if result == -1 {
            throw SocketError.makeFailed("Bind")
        }
    }

    func connect(_ addr: sockaddr_un) throws {
        var addr = addr
        let result = withUnsafePointer(to: &addr) {
            Socket.connect(file, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_un>.size))
        }

        if result == -1 {
            throw SocketError.makeFailed("Connect")
        }
    }
}
