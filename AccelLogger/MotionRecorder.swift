import Foundation
import CoreMotion
import Combine

/// Читает акселерометр через CoreMotion, интегрирует ускорение в скорость
/// и перемещение и накапливает отсчёты для экспорта.
final class MotionRecorder: ObservableObject {

    // MARK: - Публичное состояние

    @Published private(set) var isRecording = false
    @Published private(set) var samples: [MotionSample] = []
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var liveAccel = Vector3.zero
    @Published private(set) var liveVelocity = Vector3.zero
    @Published private(set) var liveDisplacement = Vector3.zero
    @Published var statusMessage: String?
    @Published var lastExportURL: URL?

    // MARK: - Настройки

    /// Частота опроса, Гц.
    @Published var sampleRate: Double = 50
    /// Пересчитывать ускорение в неподвижную (мировую) систему координат.
    @Published var useWorldFrame: Bool = true
    /// Включить подавление дрейфа (leaky integrator + зона нечувствительности).
    @Published var suppressDrift: Bool = false
    /// Зона нечувствительности по ускорению, м/с^2.
    @Published var deadband: Double = 0.05
    /// Время половинного "затухания" скорости при подавлении дрейфа, с.
    @Published var velocityHalfLife: Double = 2.0

    // MARK: - Core Motion

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MotionRecorder.queue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// 1 g в м/с^2.
    private let gravity: Double = 9.80665

    // MARK: - Состояние интегрирования

    private var referenceTime: TimeInterval = 0
    private var lastTimestamp: TimeInterval?
    private var lastIntegratedAccel = Vector3.zero
    private var velocity = Vector3.zero
    private var displacement = Vector3.zero
    private var counter = 0

    // MARK: - Доступность

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    var canExport: Bool { !samples.isEmpty }

    // MARK: - Управление

    func toggleRecording() {
        isRecording ? stop() : start()
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            statusMessage = "Акселерометр недоступен на этом устройстве."
            return
        }
        resetState()
        manager.deviceMotionUpdateInterval = 1.0 / max(1.0, sampleRate)

        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                         to: queue) { [weak self] motion, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.statusMessage = error.localizedDescription }
                return
            }
            guard let motion = motion else { return }
            self.process(motion)
        }
        isRecording = true
        statusMessage = nil
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRecording = false
    }

    func reset() {
        stop()
        resetState()
    }

    private func resetState() {
        samples.removeAll()
        elapsed = 0
        liveAccel = .zero
        liveVelocity = .zero
        liveDisplacement = .zero
        lastTimestamp = nil
        lastIntegratedAccel = .zero
        velocity = .zero
        displacement = .zero
        counter = 0
    }

    // MARK: - Обработка одного замера

    private func process(_ motion: CMDeviceMotion) {
        let now = motion.timestamp
        if lastTimestamp == nil {
            lastTimestamp = now
            referenceTime = now
        }
        guard let previous = lastTimestamp else { return }

        var dt = now - previous
        lastTimestamp = now
        if dt <= 0 { return }
        // Защита от больших разрывов (например, паузы приложения).
        if dt > 0.5 { dt = 1.0 / max(1.0, sampleRate) }

        // 1) Ускорение: g -> м/с^2, при необходимости в мировой системе координат.
        let measured = makeAcceleration(motion)

        // 2) Интегрирование методом трапеций.
        var integrated = measured
        if suppressDrift && measured.magnitude < deadband { integrated = .zero }

        let average = (integrated + lastIntegratedAccel) * 0.5
        velocity = velocity + average * dt
        displacement = displacement + velocity * dt

        // 3) Подавление дрейфа (экспоненциальное затухание скорости).
        if suppressDrift {
            let halfLife = max(0.1, velocityHalfLife)
            velocity = velocity * exp(-log(2.0) * dt / halfLife)
        }
        lastIntegratedAccel = integrated

        let currentVelocity = velocity
        let currentDisplacement = displacement
        let sample = MotionSample(index: counter,
                                  time: now - referenceTime,
                                  accel: measured,
                                  velocity: currentVelocity,
                                  displacement: currentDisplacement)
        counter += 1

        DispatchQueue.main.async {
            self.samples.append(sample)
            self.liveAccel = measured
            self.liveVelocity = currentVelocity
            self.liveDisplacement = currentDisplacement
            self.elapsed = sample.time
        }
    }

    /// userAcceleration у CoreMotion выражено в g, переводим в м/с^2.
    private func makeAcceleration(_ motion: CMDeviceMotion) -> Vector3 {
        var a = Vector3(x: motion.userAcceleration.x * gravity,
                        y: motion.userAcceleration.y * gravity,
                        z: motion.userAcceleration.z * gravity)
        if useWorldFrame {
            a = rotateToReferenceFrame(a, attitude: motion.attitude)
        }
        return a
    }

    /// Переводит вектор из системы координат устройства в опорную (мировую),
    /// используя матрицу поворота отношения attitude: v_мир = R^T * v_устройства.
    private func rotateToReferenceFrame(_ v: Vector3, attitude: CMAttitude) -> Vector3 {
        let m = attitude.rotationMatrix
        return Vector3(x: m.m11 * v.x + m.m21 * v.y + m.m31 * v.z,
                       y: m.m12 * v.x + m.m22 * v.y + m.m32 * v.z,
                       z: m.m13 * v.x + m.m23 * v.y + m.m33 * v.z)
    }

    // MARK: - Экспорт

    /// Формирует текстовый файл (CSV, разделитель ";") с заголовком и всеми отсчётами.
    func csvString() -> String {
        let header = ["index", "time_s",
                      "ax_m_s2", "ay_m_s2", "az_m_s2", "a_total_m_s2",
                      "vx_m_s", "vy_m_s", "vz_m_s", "v_total_m_s",
                      "sx_m", "sy_m", "sz_m", "s_total_m"]
        var out = header.joined(separator: ";") + "\n"
        out.reserveCapacity(samples.count * 120)

        for s in samples {
            let row = [String(s.index),
                       format(s.time),
                       format(s.accel.x), format(s.accel.y), format(s.accel.z), format(s.accelTotal),
                       format(s.velocity.x), format(s.velocity.y), format(s.velocity.z), format(s.velocityTotal),
                       format(s.displacement.x), format(s.displacement.y), format(s.displacement.z), format(s.displacementTotal)]
            out += row.joined(separator: ";") + "\n"
        }
        return out
    }

    private func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// Записывает данные во временный файл и возвращает его URL.
    func makeExportFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "motion_\(formatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try csvString().write(to: url, atomically: true, encoding: .utf8)
        lastExportURL = url
        return url
    }

    /// Краткое описание сеанса для тела письма.
    func emailBody() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm:ss"
        let rate = Int(sampleRate)
        return """
        Данные измерений акселерометра.

        Дата: \(formatter.string(from: Date()))
        Отсчётов: \(samples.count)
        Длительность: \(String(format: "%.2f", elapsed)) с
        Частота опроса: \(rate) Гц
        Мировая система координат: \(useWorldFrame ? "да" : "нет")
        Подавление дрейфа: \(suppressDrift ? "включено" : "выключено")

        Файл (CSV, разделитель «;», точка как десятичный разделитель).
        Колонки:
        index — номер отсчёта;
        time_s — время от начала, с;
        ax/ay/az_m_s2 — ускорение по осям и его модуль, м/с^2;
        vx/vy/vz_m_s — скорость по осям и её модуль, м/с;
        sx/sy/sz_m — перемещение по осям и расстояние от начала, м.

        Примечание: скорость и перемещение получены интегрированием ускорения,
        поэтому при длительной записи возможен накопительный дрейф.
        """
    }
}
