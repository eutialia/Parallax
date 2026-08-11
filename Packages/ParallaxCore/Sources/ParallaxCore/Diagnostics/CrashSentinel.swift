import Darwin
import Foundation
import MachO

/// The descriptor a crash handler writes to. A plain global because a signal handler may not touch
/// Swift runtime state — no actors, no locks, no lazy globals. Written once by `CrashSentinel.install`
/// before any handler can run, and only ever read afterwards.
nonisolated(unsafe) private var crashReportDescriptor: Int32 = -1

/// Pre-allocated frame buffer for `backtrace`. Allocated at install time because `malloc` is not
/// async-signal-safe: a handler that allocated could deadlock on the same heap lock the crashing
/// thread was holding.
nonisolated(unsafe) private var crashFrameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private let crashFrameCapacity = 128

/// Guards against a crash INSIDE the handler. If a second fatal signal arrives while we're writing,
/// the handler bails straight to the previous disposition rather than looping — losing our report is
/// survivable, losing the system's crash report on top of it is not.
nonisolated(unsafe) private var crashHandlerIsRunning = false

/// The dispositions we replaced, so a report can chain to whatever was installed before us (the
/// system default in practice, which is what produces the OS crash report).
///
/// Raw C storage indexed by signal number, NOT a Swift `Dictionary`: the chain path runs from signal
/// context, and a dictionary read goes through the Swift runtime — buffer retain/release, hashing,
/// and exclusivity bookkeeping in Debug. Any of those can block on a lock the faulting thread was
/// already holding, which would hang the handler *after* it had written the report and before it
/// re-raised, costing us the system crash report as well.
nonisolated(unsafe) private var crashPreviousActions: UnsafeMutablePointer<sigaction>?
/// Bit N set means `crashPreviousActions[N]` holds a disposition we actually replaced.
nonisolated(unsafe) private var crashPreviousActionMask: UInt32 = 0
/// Every fatal signal we install for is well under 32, so a flat table indexed by number is both
/// smaller and simpler than any search.
private let crashSignalTableSize = 32

/// Captures a native crash into the retained diagnostics file, so a crash that happens with no
/// debugger attached still leaves a stack behind on the device.
///
/// **Why this exists.** The SMB layer's worst failures are native ones — libsmb2 dispatching a
/// callback into freed memory after a wedged socket — and they happen exactly when Xcode cannot be
/// attached: the device slept, the session dropped, and the app crashed on the wake. The OS still
/// writes its own crash report, but retrieving one from an Apple TV means re-pairing and digging
/// through the device log window; and the OS report says nothing about what the app was DOING. This
/// writes a stack into the same file the lifecycle records go to, so the two read together.
///
/// **It does not replace the system crash report.** Every handler restores the previous disposition
/// and re-raises, so the crash still lands where it would have — this only gets a copy first.
///
/// **Signal-handler discipline.** Everything the report DEPENDS on is async-signal-safe: `write(2)`,
/// `backtrace`, `time`, `sigaction`, `raise`. There is no allocation, no `String`, no Swift
/// interpolation, no Swift collection and no locking — all of which can deadlock against the very
/// thread that was interrupted. That is why the messages below are `StaticString`, the numbers are
/// formatted by hand, and the replaced dispositions live in a C table rather than a `Dictionary`.
///
/// The one deliberate exception is `backtrace_symbols_fd`, which resolves through `dladdr` and so
/// can block on the dyld lock. It runs LAST, after the raw frame addresses are already on disk, so
/// the worst it can cost is the convenience of pre-symbolicated output — never the report itself.
public enum CrashSentinel {

    /// The signals worth catching. `SIGSEGV`/`SIGBUS` are the use-after-free class; `SIGTRAP`/`SIGILL`
    /// are how Swift's runtime traps land (`fatalError`, forced unwrap of nil, precondition);
    /// `SIGABRT` is an uncaught ObjC exception's final step and `abort()`; `SIGFPE`/`SIGSYS` round out
    /// the set. `SIGPIPE` is deliberately absent from the *catch* list — a dead socket write is
    /// normal here, not a crash — but left to its default disposition it still TERMINATES the
    /// process, silently: no system crash report is written for it. `install` ignores it
    /// process-wide instead, so the write fails with `EPIPE` and the caller handles it as an
    /// ordinary connection error.
    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS]

    /// Marker the session scanner looks for when deciding whether a retained session ended in a crash.
    public static let crashMarker = "*** PARALLAX CRASH ***"

    /// Points the handlers at `descriptor` and installs them. Idempotent: a second call is ignored.
    ///
    /// Called once at launch, from `DiagnosticsLog.start`, with the live session's descriptor.
    static func install(writingTo descriptor: Int32) {
        guard crashReportDescriptor < 0 else { return }
        crashReportDescriptor = descriptor
        crashFrameBuffer = .allocate(capacity: crashFrameCapacity)

        // libsmb2 writes to raw sockets without `SO_NOSIGPIPE`, so the first write to a socket the
        // OS killed during suspension raises SIGPIPE — whose default action kills the process with
        // no crash report at all (launchd logs "exited due to SIGPIPE" and nothing else). A
        // debugger swallows the signal, so only unattached runs die. Ignoring it turns that write
        // into a plain EPIPE failure, which the connection layers already treat as a dead link.
        signal(SIGPIPE, SIG_IGN)

        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = crashSignalHandler
        // SA_SIGINFO selects the three-argument handler shape, which is what carries the faulting
        // address. There is deliberately no alternate signal stack: `sigaltstack` is unavailable on
        // tvOS, and this package may not branch on platform. The cost is that a crash caused by stack
        // EXHAUSTION leaves no room to run the handler and so goes unrecorded here — it still
        // produces a system crash report, and it is not the failure class this exists for (native
        // use-after-free on a dead socket).
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)

        let table = UnsafeMutablePointer<sigaction>.allocate(capacity: crashSignalTableSize)
        table.initialize(repeating: sigaction(), count: crashSignalTableSize)
        crashPreviousActions = table
        for number in fatalSignals where number > 0 && Int(number) < crashSignalTableSize {
            var previous = sigaction()
            if sigaction(number, &action, &previous) == 0 {
                table[Int(number)] = previous
                crashPreviousActionMask |= (1 << UInt32(number))
            }
        }

        NSSetUncaughtExceptionHandler(crashExceptionHandler)
    }

    /// The fatal signals whose handler is no longer ours, if any.
    ///
    /// **Why this is worth checking.** A log that ends with no crash record means no fatal signal
    /// reached `crashSignalHandler` — and one boring explanation for that is that somebody else
    /// installed their own disposition after we did. This process loads two third-party native
    /// stacks (VLCKit and AMSMB2/libsmb2), either of which may touch signal dispositions when it
    /// initialises, which happens well after launch. Reporting the answer turns "the handler
    /// probably ran" into a fact, and rules a whole branch of the investigation in or out.
    ///
    /// Read-only: it inspects dispositions with a null `act` and never reinstalls. Silently
    /// re-arming would destroy the evidence AND stomp whoever legitimately took over.
    static func displacedSignals() -> [String] {
        // C function pointers aren't `Equatable`, so identity is compared as raw addresses.
        let ours = unsafeBitCast(crashSignalHandler, to: UnsafeRawPointer.self)
        var displaced: [String] = []
        for number in fatalSignals {
            var current = sigaction()
            guard sigaction(number, nil, &current) == 0 else { continue }
            let installed = unsafeBitCast(current.__sigaction_u.__sa_sigaction, to: UnsafeRawPointer?.self)
            if installed != ours {
                displaced.append(name(of: number))
            }
        }
        return displaced
    }

    /// Signal names for the ordinary-context reporting above. The signal handler has its own
    /// `StaticString` version — it may not touch a Swift `String`.
    private static func name(of number: Int32) -> String {
        switch number {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGSYS: "SIGSYS"
        default: "SIG\(number)"
        }
    }

    /// Whether the handlers are installed at all, so a session can state it plainly rather than
    /// leaving a reader to infer it from the absence of a crash record.
    static var isArmed: Bool { crashReportDescriptor >= 0 }

    // MARK: - Symbolication context

    /// A header, written once at install time from ORDINARY context, that makes the handler's raw
    /// addresses symbolicatable later.
    ///
    /// `backtrace_symbols_fd` prints `<image> <address> <image> + <offset>` — enough to identify the
    /// framework a frame is in, but the Swift names come out mangled and inlined frames are missing.
    /// Recording each image's UUID and load address lets the addresses be resolved properly afterwards
    /// with `atos -o <binary> -l <loadAddress> <address>`, which is what turns "crashed somewhere in
    /// AMSMB2" into a function and line.
    ///
    /// Only the app and its own frameworks are listed: system images are symbolicated from the
    /// matching OS symbol set, and printing all ~1500 of them would bury the report.
    static func imageManifest() -> String {
        var lines: [String] = ["images:"]
        for index in 0..<_dyld_image_count() {
            guard let namePointer = _dyld_get_image_name(index) else { continue }
            let path = String(cString: namePointer)
            // App binary + embedded frameworks live under the bundle; everything else is the OS.
            guard path.contains(".app/") else { continue }
            let slide = _dyld_get_image_vmaddr_slide(index)
            let name = (path as NSString).lastPathComponent
            let uuid = machOUUID(atImageIndex: index).map { " uuid=\($0)" } ?? ""
            lines.append("  \(name) load=0x\(String(UInt(bitPattern: slide) &+ loadAddress(atImageIndex: index), radix: 16))\(uuid)")
        }
        return lines.joined(separator: "\n")
    }

    /// The image's `__TEXT` virtual address before sliding — added to the ASLR slide to get the load
    /// address `atos -l` wants.
    private static func loadAddress(atImageIndex index: UInt32) -> UInt {
        guard let header = _dyld_get_image_header(index) else { return 0 }
        return UInt(bitPattern: header)
    }

    /// The image's LC_UUID as the canonical dashed hex string, or nil if the load command is absent.
    private static func machOUUID(atImageIndex index: UInt32) -> String? {
        guard let header = _dyld_get_image_header(index) else { return nil }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self)
            if command.pointee.cmd == LC_UUID {
                let uuidCommand = cursor.assumingMemoryBound(to: uuid_command.self)
                return UUID(uuid: uuidCommand.pointee.uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.pointee.cmdsize))
        }
        return nil
    }
}

// MARK: - The fatal-signal handler

/// Converts to a C function pointer because it captures nothing — every piece of state it touches is
/// a file-scope global set up before any signal can arrive.
private let crashSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { number, info, _ in
    let descriptor = crashReportDescriptor
    guard descriptor >= 0 else { crashChainToPrevious(number); return }

    // Re-entered from inside our own report: give up immediately and let the crash land where it
    // would have. A partial report beats no system crash report.
    if crashHandlerIsRunning { crashChainToPrevious(number); return }
    crashHandlerIsRunning = true

    crashWrite(descriptor, "\n")
    crashWrite(descriptor, "*** PARALLAX CRASH *** signal=")
    crashWriteSignalName(descriptor, number)
    crashWrite(descriptor, " code=")
    crashWriteInt(descriptor, Int(info?.pointee.si_code ?? 0))
    crashWrite(descriptor, " address=0x")
    crashWriteHex(descriptor, UInt(bitPattern: info?.pointee.si_addr))
    crashWrite(descriptor, " epoch=")
    crashWriteInt(descriptor, Int(time(nil)))
    crashWrite(descriptor, "\n")

    if let buffer = crashFrameBuffer {
        let frames = backtrace(buffer, Int32(crashFrameCapacity))
        // RAW ADDRESSES FIRST, and this ordering is the whole point.
        //
        // `backtrace_symbols_fd` is NOT async-signal-safe despite being the obvious tool here: it
        // resolves every frame through `dladdr`, which takes the dyld loader lock. This process
        // dlopens third-party native code, so a fault taken while another thread holds that lock —
        // or taken inside dyld itself — would hang the handler right here, with no `*** END CRASH ***`
        // and no re-raise, so the OS never writes its report either. The death then looks like a
        // watchdog kill, which is the one distinction this file exists to make.
        //
        // So the addresses go down first with nothing but `write(2)`. Combined with the image
        // manifest in the session header they are fully resolvable by `atos` even if the symbolicated
        // block below never appears.
        crashWrite(descriptor, "frames=")
        crashWriteInt(descriptor, Int(frames))
        crashWrite(descriptor, "\n")
        for index in 0..<Int(frames) {
            crashWrite(descriptor, "0x")
            crashWriteHex(descriptor, UInt(bitPattern: buffer[index]))
            crashWrite(descriptor, "\n")
        }
        // Best-effort convenience: when it works it saves an `atos` round trip, and when it hangs
        // everything above is already on disk.
        backtrace_symbols_fd(buffer, frames, descriptor)
    }
    crashWrite(descriptor, "*** END CRASH ***\n")

    crashChainToPrevious(number)
}

/// Restores whatever disposition we replaced and re-raises, so the OS still produces its own crash
/// report (and a debugger, if one is attached, still stops).
private func crashChainToPrevious(_ number: Int32) {
    if let table = crashPreviousActions, number > 0, Int(number) < crashSignalTableSize,
       crashPreviousActionMask & (1 << UInt32(number)) != 0 {
        sigaction(number, table + Int(number), nil)
    } else {
        signal(number, SIG_DFL)
    }
    raise(number)
}

// MARK: - Async-signal-safe formatting
//
// `String` interpolation allocates, and `malloc` in a signal handler can deadlock against the
// interrupted thread. Everything below writes from `StaticString` literals (whose bytes live in the
// binary) or formats integers into a fixed stack buffer.

@inline(__always)
private func crashWrite(_ descriptor: Int32, _ text: StaticString) {
    text.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress else { return }
        diagnosticsWriteAll(descriptor, base, buffer.count)
    }
}

/// Digit scratch space. `withUnsafeTemporaryAllocation` keeps a buffer this small on the STACK, which
/// is what makes these formatters usable from a signal handler — an `Array` would reach `malloc`.
private let crashDigitCapacity = 24

private func crashWriteInt(_ descriptor: Int32, _ value: Int) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: crashDigitCapacity) { digits in
        var count = 0
        var magnitude = value.magnitude
        repeat {
            digits[count] = UInt8(ascii: "0") + UInt8(magnitude % 10)
            magnitude /= 10
            count += 1
        } while magnitude > 0
        if value < 0 {
            digits[count] = UInt8(ascii: "-")
            count += 1
        }
        crashWriteReversed(descriptor, digits, count)
    }
}

private func crashWriteHex(_ descriptor: Int32, _ value: UInt) {
    let alphabet: StaticString = "0123456789abcdef"
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: crashDigitCapacity) { digits in
        var count = 0
        var magnitude = value
        repeat {
            let nibble = Int(magnitude & 0xF)
            alphabet.withUTF8Buffer { digits[count] = $0[nibble] }
            magnitude >>= 4
            count += 1
        } while magnitude > 0
        crashWriteReversed(descriptor, digits, count)
    }
}

/// The digit routines above produce least-significant-first; this emits them in reading order,
/// through a second stack buffer so the reversal never allocates either.
private func crashWriteReversed(
    _ descriptor: Int32,
    _ digits: UnsafeMutableBufferPointer<UInt8>,
    _ count: Int
) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: crashDigitCapacity) { ordered in
        for index in 0..<count { ordered[index] = digits[count - 1 - index] }
        guard let base = ordered.baseAddress else { return }
        diagnosticsWriteAll(descriptor, base, count)
    }
}

private func crashWriteSignalName(_ descriptor: Int32, _ number: Int32) {
    switch number {
    case SIGSEGV: crashWrite(descriptor, "SIGSEGV")
    case SIGBUS: crashWrite(descriptor, "SIGBUS")
    case SIGILL: crashWrite(descriptor, "SIGILL")
    case SIGTRAP: crashWrite(descriptor, "SIGTRAP")
    case SIGABRT: crashWrite(descriptor, "SIGABRT")
    case SIGFPE: crashWrite(descriptor, "SIGFPE")
    case SIGSYS: crashWrite(descriptor, "SIGSYS")
    default: crashWrite(descriptor, "SIG")
    }
}

// MARK: - Uncaught ObjC exceptions

/// Runs in ORDINARY context (the runtime calls it before `abort()`), so `String` work is allowed
/// here — unlike the signal handler above. The `SIGABRT` that follows will append its own stack,
/// which is why this only records what the signal path cannot see: the exception's identity.
private let crashExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    let descriptor = crashReportDescriptor
    guard descriptor >= 0 else { return }
    var report = "\n\(CrashSentinel.crashMarker) uncaught exception\n"
    report += "name=\(exception.name.rawValue)\n"
    report += "reason=\(exception.reason ?? "nil")\n"
    report += exception.callStackSymbols.joined(separator: "\n")
    report += "\n*** END CRASH ***\n"
    let bytes = Array(report.utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        diagnosticsWriteAll(descriptor, base, buffer.count)
    }
}
