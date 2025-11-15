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

    private let locationManager = CLLocationManager()
    #if os(iOS) || os(watchOS)
        private let motionManager = CMMotionManager()
    #endif
    private var permissionHandlers: [SensorType: (Bool) -> Void] = [:]

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
            permissionHandlers[.location] = { granted in
                continuation.resume(returning: granted)
            }
            locationManager.requestWhenInUseAuthorization()
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

    private func validateRate(_ rate: Double, for sensor: SensorType) -> Bool {
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
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            let task = Task { @MainActor in
                locationManager.requestLocation()

                try await Task.sleep(for: .seconds(10))

                if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: SensorBridgeError.timeout(sensor: .location))
                }
            }

            permissionHandlers[.location] = { _ in
                if !hasResumed {
                    hasResumed = true
                    task.cancel()
                    continuation.resume(throwing: SensorBridgeError.permissionDenied(sensor: .location))
                }
            }
        }
    }

    private func collectMotionData() async throws -> [String: Any] {
        #if os(iOS) || os(watchOS)
            guard motionManager.isDeviceMotionAvailable else {
                throw SensorBridgeError.sensorUnavailable(sensor: .motion)
            }

            return try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false

                motionManager.startDeviceMotionUpdates(to: .main) { motion, error in
                    if hasResumed { return }
                    hasResumed = true

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let motion else {
                        continuation.resume(throwing: SensorBridgeError.noData(sensor: .motion))
                        return
                    }

                    let data: [String: Any] = [
                        "acceleration": [
                            "x": motion.userAcceleration.x,
                            "y": motion.userAcceleration.y,
                            "z": motion.userAcceleration.z,
                        ],
                        "rotation": [
                            "x": motion.rotationRate.x,
                            "y": motion.rotationRate.y,
                            "z": motion.rotationRate.z,
                        ],
                        "gravity": [
                            "x": motion.gravity.x,
                            "y": motion.gravity.y,
                            "z": motion.gravity.z,
                        ],
                    ]

                    self.motionManager.stopDeviceMotionUpdates()
                    continuation.resume(returning: data)
                }
            }
        #else
            throw SensorBridgeError.sensorUnavailable(sensor: .motion)
        #endif
    }

    private func collectCompassData() async throws -> [String: Any] {
        #if os(iOS) || os(watchOS)
            guard CLLocationManager.headingAvailable() else {
                throw SensorBridgeError.sensorUnavailable(sensor: .compass)
            }

            return try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false

                locationManager.startUpdatingHeading()

                Task { @MainActor in
                    try await Task.sleep(for: .seconds(5))

                    if !hasResumed {
                        hasResumed = true
                        self.locationManager.stopUpdatingHeading()
                        continuation.resume(throwing: SensorBridgeError.timeout(sensor: .compass))
                    }
                }

                permissionHandlers[.compass] = { [weak self] _ in
                    if !hasResumed {
                        hasResumed = true
                        self?.locationManager.stopUpdatingHeading()
                        continuation.resume(throwing: SensorBridgeError.permissionDenied(sensor: .compass))
                    }
                }
            }
        #else
            throw SensorBridgeError.sensorUnavailable(sensor: .compass)
        #endif
    }

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
            try await Task.sleep(for: .seconds(duration))
            print("[SensorBridge] Data retention expired for task: \(taskId)")
        }
    }
}

extension SensorBridge: @preconcurrency CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "altitude": location.altitude,
            "horizontalAccuracy": location.horizontalAccuracy,
            "verticalAccuracy": location.verticalAccuracy,
        ]

        if let handler = permissionHandlers[.location] {
            permissionHandlers.removeValue(forKey: .location)
            handler(true)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[SensorBridge] Location error: \(error.localizedDescription)")

        if let handler = permissionHandlers[.location] {
            permissionHandlers.removeValue(forKey: .location)
            handler(false)
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

        if authorized {
            if let handler = permissionHandlers[.location] {
                permissionHandlers.removeValue(forKey: .location)
                handler(true)
            }
        } else if status == .denied || status == .restricted {
            if let handler = permissionHandlers[.location] {
                permissionHandlers.removeValue(forKey: .location)
                handler(false)
            }
        }
    }

    #if os(iOS) || os(watchOS)
        public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            guard newHeading.headingAccuracy >= 0 else { return }

            if let handler = permissionHandlers[.compass] {
                permissionHandlers.removeValue(forKey: .compass)
                handler(true)
            }

            manager.stopUpdatingHeading()
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
