import Foundation
import IOKit
import Darwin

/// A single sine tone inside a Force Touch trackpad actuation dictionary.
struct HapticTone {
    let hz: Double
    let amp: Double
    let durationMS: Double
    let delayMS: Double

    init(hz: Double, amp: Double, durationMS: Double, delayMS: Double = 0.0) {
        self.hz = hz
        self.amp = amp
        self.durationMS = durationMS
        self.delayMS = delayMS
    }
}

/// A single actuation burst sent to the trackpad haptic motor.
struct HapticBurst {
    let baseGaussianAmp: Double
    let baseDurationMS: Double
    let tones: [HapticTone]
    let level: Float
}

/// Drives the MacBook / Magic Trackpad Force Touch haptic motor directly via the
/// private `MultitouchSupport.framework` API (technique from os6/nospeaker).
///
/// The motor is never driven past its normal maximum (amplitudes are normalized
/// and level is clamped to 0...1).
final class HapticEngine {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    private let mtHandle: UnsafeMutableRawPointer?
    private let actuationCreateFn: ActuationCreate?
    private let actuationPlayFn: ActuationPlay?
    private let actuatorCloseFn: ActuatorClose?

    private var motorRef: CFTypeRef?
    private var motorPointer: UnsafeMutableRawPointer?
    private var deviceListRef: CFArray?

    private let queue = DispatchQueue(label: "com.mechpad.haptics", qos: .userInteractive)
    private var activeGeneration: UInt64 = 0

    private(set) var isAvailable: Bool = false
    private(set) var deviceDescription: String = "No Force Touch trackpad"
    private(set) var errorMessage: String?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        mtHandle = handle

        func loadSym<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        let createList = loadSym("MTDeviceCreateList", CreateList.self)
        let getID = loadSym("MTDeviceGetDeviceID", GetID.self)
        let isBuiltIn = loadSym("MTDeviceIsBuiltIn", IsBuiltIn.self)
        let actuatorCreate = loadSym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
        let actuatorOpen = loadSym("MTActuatorOpen", ActuatorOpen.self)
        actuatorCloseFn = loadSym("MTActuatorClose", ActuatorClose.self)
        actuationCreateFn = loadSym("MTActuationCreateFromDictionary", ActuationCreate.self)
        actuationPlayFn = loadSym("MTActuationActuate", ActuationPlay.self)

        guard let createList, let getID, let actuatorCreate, let actuatorOpen,
              actuationCreateFn != nil, actuationPlayFn != nil else {
            errorMessage = "MultitouchSupport haptic functions are unavailable on this macOS version."
            return
        }

        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
            errorMessage = "No Force Touch trackpad found. Connect a Magic Trackpad 2+ or use a MacBook."
            return
        }

        deviceListRef = list
        var candidates: [(id: UInt64, builtIn: Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(dev, &id) == 0 {
                candidates.append((id, isBuiltIn?(dev) ?? false))
            }
        }

        // Prefer built-in Force Touch trackpad over external devices.
        for candidate in candidates.sorted(by: { $0.builtIn && !$1.builtIn }) {
            if let ref = actuatorCreate(candidate.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                motorRef = ref
                motorPointer = Unmanaged.passUnretained(ref).toOpaque()
                isAvailable = true
                deviceDescription = candidate.builtIn ? "Built-in Force Touch Trackpad" : "External Force Touch Trackpad"
                return
            }
        }

        errorMessage = "Trackpad found, but it does not expose a Force Touch haptic actuator."
    }

    deinit {
        close()
    }

    func close() {
        queue.sync {
            if let ref = motorRef {
                _ = actuatorCloseFn?(ref)
                motorRef = nil
                motorPointer = nil
            }
        }
    }

    /// Plays a primary haptic burst immediately, and an optional secondary burst (e.g. spring ping)
    /// after `secondaryDelayMS` if no newer key event has superseded it.
    func playKeyEvent(
        primary: HapticBurst,
        secondary: (burst: HapticBurst, delayMS: Double)? = nil,
        masterIntensity: Float
    ) {
        guard isAvailable, masterIntensity > 0.001 else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.activeGeneration &+= 1
            let gen = self.activeGeneration

            self.actuate(primary, masterIntensity: masterIntensity)

            if let secondary {
                let delaySec = secondary.delayMS / 1000.0
                self.queue.asyncAfter(deadline: .now() + delaySec) { [weak self] in
                    guard let self, self.activeGeneration == gen else { return }
                    self.actuate(secondary.burst, masterIntensity: masterIntensity)
                }
            }
        }
    }

    private func actuate(_ burst: HapticBurst, masterIntensity: Float) {
        guard let motorPointer,
              let createFn = actuationCreateFn,
              let playFn = actuationPlayFn,
              !burst.tones.isEmpty || burst.baseGaussianAmp > 0 else { return }

        let clampedLevel = min(1.0, max(0.0, burst.level * masterIntensity))
        guard clampedLevel > 0.005 else { return }

        let toneSum = burst.tones.reduce(0.0) { $0 + max(0.0, $1.amp) }
        let baseAmp = max(0.0, min(0.6, burst.baseGaussianAmp))
        let totalNorm = max(toneSum + baseAmp, 0.0001)
        let toneScale = totalNorm > 1.0 ? (1.0 - baseAmp) / max(toneSum, 0.0001) : 1.0

        let toneDicts: [[String: Any]] = burst.tones.map { tone in
            let safeHz = min(4000.0, max(95.0, tone.hz))
            return [
                "Type": "Sine",
                "Amplitude": max(0.0, tone.amp) * toneScale,
                "DurationMS": max(1.5, tone.durationMS),
                "DelayMS": max(0.0, tone.delayMS),
                "FrequencykHz": safeHz / 1000.0,
            ]
        }

        let shape: [String: Any] = [
            "BaseWaveform": [
                "Type": "Gaussian",
                "Amplitude": baseAmp,
                "DurationMS": max(1.5, burst.baseDurationMS),
            ],
            "Tones": toneDicts,
        ]

        guard let actuation = createFn(shape as CFDictionary, 0) else { return }
        _ = playFn(actuation, motorPointer, 0, clampedLevel, 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()
    }
}
