import CoreAudio
import CrashSupport
import Foundation

struct OSStatusError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String {
        let n = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
        let fourCC = chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") } ? " '\(String(chars))'" : ""
        return "\(what) failed: OSStatus \(status)\(fourCC)"
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw OSStatusError(status: status, what: what) }
}

struct ObjCException: Error, CustomStringConvertible {
    let description: String
}

/// Runs `body`, turning an Objective-C exception into a Swift error (CrashSupport's `hs_try_objc`).
func tryObjC(_ what: String, _ body: () throws -> Void) throws {
    var swiftError: Error?
    if let raw = hs_try_objc({ do { try body() } catch { swiftError = error } }) {
        let text = String(cString: raw)
        free(raw)
        throw ObjCException(description: "\(what): \(text)")
    }
    if let swiftError { throw swiftError }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        try check(st, "get \(selector)")
        return value
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size \(selector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buf.deallocate() }
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf), "get \(selector)")
        let typed = buf.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    /// Core Audio process object for a pid, or nil if that process has no audio client.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Adds a block listener on the main queue; returns a remover.
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ handler: @escaping () -> Void) -> () -> Void {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let st = AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block)
        guard st == noErr else { return {} }
        return {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
    }
}
