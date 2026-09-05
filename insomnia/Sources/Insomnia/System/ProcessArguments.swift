import Darwin
import Foundation

/// KERN_PROCARGS2 preserves argv boundaries; `ps` renders them as ambiguous spaces.
enum ProcessArguments {
    static func read(pid: Int32) throws -> [String] {
        var capacity: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &capacity, &size, nil, 0) == 0, capacity > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var bytes = [UInt8](repeating: 0, count: Int(capacity))
        size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try decode(Array(bytes.prefix(size)))
    }

    static func decode(_ bytes: [UInt8]) throws -> [String] {
        let corrupt = CocoaError(.fileReadCorruptFile)
        guard bytes.count >= MemoryLayout<Int32>.size else { throw corrupt }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= bytes.count else { throw corrupt }
        var offset = MemoryLayout<Int32>.size
        // Executable path and kernel alignment padding precede argv[0].
        guard let pathEnd = bytes[offset...].firstIndex(of: 0) else { throw corrupt }
        offset = pathEnd
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var args: [String] = []
        for _ in 0..<count {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[offset..<end], encoding: .utf8) else { throw corrupt }
            args.append(argument)
            offset = end + 1
        }
        return args
    }
}
