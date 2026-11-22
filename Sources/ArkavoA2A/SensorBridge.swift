import ArkavoSocial
import CoreLocation
import Foundation
import OSLog
#if os(iOS) || os(watchOS)
    import CoreMotion
#endif
import AVFoundation

/// Sensor bridge with policy enforcement for accessing device sensors
/// Handles permission prompting, scope limiting, rate limiting, and data redaction
@MainActor
public final class SensorBridge: NSObject, ObservableObject {
    @Published public private(set) var lastError: String?

    private struct SensorPayloadBox: @unchecked Sendable {
        let value: [String: Any]
    }

    private let locationManager = CLLocationManager()
    #if os(iOS) || os(watchOS)
        private let motionManager = CMMotionManager()
        private var compassWaiters: [UUID: (continuation: CheckedContinuation<SensorPayloadBox, Error>, timeoutTask: Task<Void, Never>)] = [:]
        private var motionWaiters: [UUID: CheckedContinuation<SensorPayloadBox, Error>] = [:]
    #endif
    private var permissionWaiters: [SensorType: [CheckedContinuation<Bool, Never>]] = [:]
    private var locationWaiters: [UUID: (continuation: CheckedContinuation<SensorPayloadBox, Error>, timeoutTask: Task<Void, Never>)] = [:]

    public override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Request sensor data with policy enforcement
    public func requestSensorData(_ request: SensorRequest) async throws -> SensorResponse {
        guard try await checkPermission(for: request.sensor) else {
            throw SensorBridgeError.permissionDenied(sensor: request.sensor)
        }

        guard validateScope(request.scope, for: request.sensor) else {
            throw SensorBridgeError.invalidScope(sensor: request.sensor, scope: request.scope)
        }

        if let rate = request.rate {
            guard validateRate(rate, for: request.sensor) else {
                throw SensorBridgeError.rateLimitExceeded(sensor: request.sensor, requestedRate: rate)
            }
        }

        let rawData = try await collectSensorData(request.sensor, rate: request.rate)
        let (processedData, redactions) = processData(rawData, scope: request.scope, sensor: request.sensor)

        logSensorAccess(request)

        if let retention = request.retention {
            scheduleDataDeletion(taskId: request.taskId, after: TimeInterval(retention))
        }

        return SensorResponse(
            taskId: request.taskId,
            payload: AnyCodable(processedData),
            redactions: redactions,
            timestamp: Date()
        )
    }

    private func checkPermission(for sensor: SensorType) async throws -> Bool {
        switch sensor {
        case .location:
            return await checkLocationPermission()
        case .camera:
            return await checkCameraPermission()
        case .microphone:
            return await checkMicrophonePermission()
        case .motion:
            return true
        case .nearbyDevices:
            return true
        case .compass:
            return await checkLocationPermission()
        case .ambientLight, .barometer:
            return true
        }
    }

    private func checkLocationPermission() async -> Bool {
        let status = locationManager.authorizationStatus

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .notDetermined:
            return await requestLocationPermission()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestLocationPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            let shouldRequest = (permissionWaiters[.location]?.isEmpty ?? true)
            permissionWaiters[.location, default: []].append(continuation)
            if shouldRequest {
                locationManager.requestWhenInUseAuthorization()
            }
        }
    }

    private func checkCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func checkMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func validateScope(_ scope: DataScope, for sensor: SensorType) -> Bool {
        true
    }

    func validateRate(_ rate: Double, for sensor: SensorType) -> Bool {
        guard rate.isFinite, rate > 0 else {
            return false
        }

        switch sensor {
        case .motion:
            return rate <= 100.0
        case .location:
            return rate <= 1.0
        case .camera, .microphone:
            return rate <= 60.0
        case .nearbyDevices, .compass, .ambientLight, .barometer:
            return rate <= 10.0
        }
    }

    private func collectSensorData(_ sensor: SensorType, rate: Double?) async throws -> [String: Any] {
        switch sensor {
        case .location:
            return try await collectLocationData()
        case .camera:
            throw SensorBridgeError.notImplemented(sensor: sensor)
        case .microphone:
            throw SensorBridgeError.notImplemented(sensor: sensor)
        case .motion:
            return try await collectMotionData()
        case .nearbyDevices:
            throw SensorBridgeError.notImplemented(sensor: sensor)
        case .compass:
            return try await collectCompassData()
        case .ambientLight, .barometer:
            throw SensorBridgeError.notImplemented(sensor: sensor)
        }
    }

    private func collectLocationData() async throws -> [String: Any] {
        let waiterId = UUID()
        let payload: SensorPayloadBox = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SensorPayloadBox, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let shouldRequest = locationWaiters.isEmpty
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        return
                    }
                    guard let self, let entry = self.locationWaiters.removeValue(forKey: waiterId) else {
                        return
                    }
                    entry.continuation.resume(throwing: SensorBridgeError.timeout(sensor: .location))
                }

                locationWaiters[waiterId] = (continuation: continuation, timeoutTask: timeoutTask)
                if shouldRequest {
                    locationManager.requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let entry = self.locationWaiters.removeValue(forKey: waiterId) else {
                    return
                }
                entry.timeoutTask.cancel()
                entry.continuation.resume(throwing: CancellationError())
            }
        }
        return payload.value
    }

    private func collectMotionData() async throws -> [String: Any] {
        #if os(iOS) || os(watchOS)
            guard motionManager.isDeviceMotionAvailable else {
                throw SensorBridgeError.sensorUnavailable(sensor: .motion)
            }

            let waiterId = UUID()
            let payload: SensorPayloadBox = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SensorPayloadBox, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let shouldStart = motionWaiters.isEmpty
                    motionWaiters[waiterId] = continuation

                    if shouldStart {
                        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.motionManager.stopDeviceMotionUpdates()

                                let waiters = self.motionWaiters
                                self.motionWaiters.removeAll()
                                guard !waiters.isEmpty else { return }

                                if let error {
                                    for (_, waiter) in waiters {
                                        waiter.resume(throwing: error)
                                    }
                                    return
                                }

                                guard let motion else {
                                    for (_, waiter) in waiters {
                                        waiter.resume(throwing: SensorBridgeError.noData(sensor: .motion))
                                    }
                                    return
                                }

                                let acc = motion.userAcceleration
                                let rot = motion.rotationRate
                                let grav = motion.gravity
                                for (_, waiter) in waiters {
                                    waiter.resume(returning: SensorPayloadBox(value: Self.makeMotionPayload(
                                        accX: acc.x, accY: acc.y, accZ: acc.z,
                                        rotX: rot.x, rotY: rot.y, rotZ: rot.z,
                                        gravX: grav.x, gravY: grav.y, gravZ: grav.z
                                    )))
                                }
                            }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, let waiter = self.motionWaiters.removeValue(forKey: waiterId) else {
                        return
                    }
                    if self.motionWaiters.isEmpty {
                        self.motionManager.stopDeviceMotionUpdates()
                    }
                    waiter.resume(throwing: CancellationError())
                }
            }
            return payload.value
        #else
            throw SensorBridgeError.sensorUnavailable(sensor: .motion)
        #endif
    }

    private func collectCompassData() async throws -> [String: Any] {
        #if os(iOS) || os(watchOS)
            guard CLLocationManager.headingAvailable() else {
                throw SensorBridgeError.sensorUnavailable(sensor: .compass)
            }

            let waiterId = UUID()
            let payload: SensorPayloadBox = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SensorPayloadBox, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let shouldStart = compassWaiters.isEmpty
                    let timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(5))
                        } catch {
                            return
                        }
                        guard let self, let entry = self.compassWaiters.removeValue(forKey: waiterId) else {
                            return
                        }
                        if self.compassWaiters.isEmpty {
                            self.locationManager.stopUpdatingHeading()
                        }
                        entry.continuation.resume(throwing: SensorBridgeError.timeout(sensor: .compass))
                    }

                    compassWaiters[waiterId] = (continuation: continuation, timeoutTask: timeoutTask)
                    if shouldStart {
                        locationManager.startUpdatingHeading()
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, let entry = self.compassWaiters.removeValue(forKey: waiterId) else {
                        return
                    }
                    entry.timeoutTask.cancel()
                    if self.compassWaiters.isEmpty {
                        self.locationManager.stopUpdatingHeading()
                    }
                    entry.continuation.resume(throwing: CancellationError())
                }
            }
            return payload.value
        #else
            throw SensorBridgeError.sensorUnavailable(sensor: .compass)
        #endif
    }

    private static func makeLocationPayload(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        timestamp: String
    ) -> [String: Any] {
        [
            "latitude": latitude,
            "longitude": longitude,
            "altitude": altitude,
            "horizontal_accuracy": horizontalAccuracy,
            "vertical_accuracy": verticalAccuracy,
            "timestamp": timestamp,
        ]
    }

    #if os(iOS) || os(watchOS)
        private static func makeCompassPayload(
            magneticHeading: Double,
            trueHeading: Double,
            headingAccuracy: Double,
            timestamp: String
        ) -> [String: Any] {
            [
                "magnetic_heading": magneticHeading,
                "true_heading": trueHeading,
                "heading_accuracy": headingAccuracy,
                "timestamp": timestamp,
            ]
        }

        private static func makeMotionPayload(
            accX: Double, accY: Double, accZ: Double,
            rotX: Double, rotY: Double, rotZ: Double,
            gravX: Double, gravY: Double, gravZ: Double
        ) -> [String: Any] {
            [
                "acceleration": [
                    "x": accX,
                    "y": accY,
                    "z": accZ,
                ],
                "rotation": [
                    "x": rotX,
                    "y": rotY,
                    "z": rotZ,
                ],
                "gravity": [
                    "x": gravX,
                    "y": gravY,
                    "z": gravZ,
                ],
            ]
        }
    #endif

    private func processData(_ data: [String: Any], scope: DataScope, sensor: SensorType) -> ([String: Any], [String]) {
        var processedData = data
        var redactions: [String] = []

        if sensor == .location {
            switch scope {
            case .minimal:
                if let lat = data["latitude"] as? Double, let lon = data["longitude"] as? Double {
                    processedData["latitude"] = roundToDecimalPlaces(lat, places: 0)
                    processedData["longitude"] = roundToDecimalPlaces(lon, places: 0)
                    redactions.append("Rounded coordinates to city-level precision")
                }
            case .standard:
                if let lat = data["latitude"] as? Double, let lon = data["longitude"] as? Double {
                    processedData["latitude"] = roundToDecimalPlaces(lat, places: 2)
                    processedData["longitude"] = roundToDecimalPlaces(lon, places: 2)
                    redactions.append("Rounded coordinates to street-level precision")
                }
            case .detailed:
                break
            }

            if scope != .detailed {
                processedData.removeValue(forKey: "altitude")
                redactions.append("Removed altitude data")
            }
        }

        return (processedData, redactions)
    }

    private func roundToDecimalPlaces(_ value: Double, places: Int) -> Double {
        let multiplier = pow(10.0, Double(places))
        return round(value * multiplier) / multiplier
    }

    private func logSensorAccess(_ request: SensorRequest) {
        print("[SensorBridge] Sensor access: \(request.sensor.rawValue), scope: \(request.scope.rawValue), policy: \(request.policyTag), task: \(request.taskId)")
    }

    private func scheduleDataDeletion(taskId: String, after duration: TimeInterval) {
        Task {
            // The sleep throws only if the task is cancelled, and then the retention timer is gone,
            // so there's nothing to report.
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            print("[SensorBridge] Data retention expired for task: \(taskId)")
        }
    }
}

extension SensorBridge: @preconcurrency CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let altitude = location.altitude
        let horizontalAccuracy = location.horizontalAccuracy
        let verticalAccuracy = location.verticalAccuracy
        let timestamp = ISO8601DateFormatter().string(from: location.timestamp)

        let waiters = locationWaiters
        locationWaiters.removeAll()
        for (_, entry) in waiters {
            entry.timeoutTask.cancel()
            entry.continuation.resume(returning: SensorPayloadBox(value: Self.makeLocationPayload(
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: horizontalAccuracy,
                verticalAccuracy: verticalAccuracy,
                timestamp: timestamp
            )))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[SensorBridge] Location error: \(error.localizedDescription)")

        #if os(iOS) || os(watchOS)
            if let clError = error as? CLError, clError.code == .headingFailure {
                let headingWaiters = compassWaiters
                compassWaiters.removeAll()
                manager.stopUpdatingHeading()
                for (_, entry) in headingWaiters {
                    entry.timeoutTask.cancel()
                    entry.continuation.resume(throwing: error)
                }
                return
            }
        #endif

        let waiters = locationWaiters
        locationWaiters.removeAll()
        for (_, entry) in waiters {
            entry.timeoutTask.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        #if os(iOS) || os(watchOS) || os(tvOS)
            let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        #elseif os(macOS)
            let authorized = status == .authorizedAlways
        #else
            let authorized = false
        #endif

        if authorized || status == .denied || status == .restricted {
            let waiters = permissionWaiters.removeValue(forKey: .location) ?? []
            for continuation in waiters {
                continuation.resume(returning: authorized)
            }
        }
    }

    #if os(iOS) || os(watchOS)
        public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            guard newHeading.headingAccuracy >= 0 else { return }

            let magneticHeading = newHeading.magneticHeading
            let trueHeading = newHeading.trueHeading
            let headingAccuracy = newHeading.headingAccuracy
            let timestamp = ISO8601DateFormatter().string(from: newHeading.timestamp)

            let waiters = compassWaiters
            compassWaiters.removeAll()
            manager.stopUpdatingHeading()

            for (_, entry) in waiters {
                entry.timeoutTask.cancel()
                entry.continuation.resume(returning: SensorPayloadBox(value: Self.makeCompassPayload(
                    magneticHeading: magneticHeading,
                    trueHeading: trueHeading,
                    headingAccuracy: headingAccuracy,
                    timestamp: timestamp
                )))
            }
        }
    #endif
}

public enum SensorBridgeError: Error, LocalizedError {
    case permissionDenied(sensor: SensorType)
    case invalidScope(sensor: SensorType, scope: DataScope)
    case rateLimitExceeded(sensor: SensorType, requestedRate: Double)
    case sensorUnavailable(sensor: SensorType)
    case noData(sensor: SensorType)
    case timeout(sensor: SensorType)
    case notImplemented(sensor: SensorType)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(sensor):
            return "Permission denied for sensor: \(sensor.rawValue)"
        case let .invalidScope(sensor, scope):
            return "Invalid scope '\(scope.rawValue)' for sensor: \(sensor.rawValue)"
        case let .rateLimitExceeded(sensor, rate):
            return "Rate limit exceeded for sensor \(sensor.rawValue): requested \(rate) Hz"
        case let .sensorUnavailable(sensor):
            return "Sensor unavailable: \(sensor.rawValue)"
        case let .noData(sensor):
            return "No data available from sensor: \(sensor.rawValue)"
        case let .timeout(sensor):
            return "Timeout waiting for sensor data: \(sensor.rawValue)"
        case let .notImplemented(sensor):
            return "Sensor not yet implemented: \(sensor.rawValue)"
        }
    }
}
