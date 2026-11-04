import Darwin
import Foundation
import TerminalMacCore
import Virtualization

/// Experiment only, and nothing else depends on it. It answers two questions before anyone replaces
/// the shared-folder mailbox with virtio sockets: do macOS guests support them, and can the guest
/// side tell the host apart from other guest processes?
enum VsockProbe {
    static let port: UInt32 = 7777

    private static func address(cid: UInt32) -> sockaddr_vm {
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = cid
        return address
    }
    private static var lastError: String { String(cString: strerror(errno)) }

    /// Guest: answers host connections and refuses every other peer. Runs until interrupted.
    static func serve() throws -> Never {
        let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure("AF_VSOCK is unavailable in this guest: \(lastError)") }
        var local = address(cid: VMADDR_CID_ANY)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) } }
        guard bound == 0, listen(listener, 8) == 0 else { throw Failure("Cannot listen on vsock port \(port): \(lastError)") }
        print("Listening on vsock port \(port). Run `terminal-mac vsock-probe NAME` on the host.")
        fflush(stdout)
        while true {
            var peer = sockaddr_vm()
            var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let connection = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) } }
            guard connection >= 0 else { print("accept failed: \(lastError)"); continue }
            let fromHost = peer.svm_cid == VMADDR_CID_HOST
            print("Connection from CID \(peer.svm_cid): \(fromHost ? "accepted (host)" : "refused (not the host)")")
            fflush(stdout)
            if fromHost {
                let reply = Array("pong from guest\n".utf8)
                _ = reply.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            }
            close(connection)
        }
    }

    /// Guest: tries to reach the listener as an ordinary guest process would.
    static func tryLocalConnections() {
        for cid: UInt32 in [1, 3] {
            let client = socket(AF_VSOCK, SOCK_STREAM, 0)
            guard client >= 0 else { print("AF_VSOCK is unavailable in this guest: \(lastError)"); return }
            defer { close(client) }
            var target = address(cid: cid)
            let result = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) } }
            print("CID \(cid): \(result == 0 ? "connected" : "failed: \(lastError)")")
        }
    }

    /// Host: runs in the VM process, which owns the socket device.
    @MainActor
    static func ping(_ vm: VZVirtualMachine) async throws -> [String: String] {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw Failure("This VM has no socket device. Restart it with this build")
        }
        let connection = try await device.connect(toPort: port)
        defer { connection.close() }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(connection.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(connection.fileDescriptor, &buffer, buffer.count)
        guard count > 0 else { throw Failure("Connected, but the guest sent nothing: \(lastError)") }
        guard buffer.prefix(count).elementsEqual("pong from guest\n".utf8) else { throw Failure("Connected, but the guest sent an unexpected reply") }
        return ["reply": "pong from guest"]
    }
}
