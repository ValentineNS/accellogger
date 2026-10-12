import Foundation
import CoreMotion
import Combine

/// Читает акселерометр через CoreMotion, компенсирует смещение нуля,
/// интегрирует ускорение в скорость и перемещение и накапливает отсчёты.
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

    /// Текущее измеренное смещение нуля (в системе координат устройства), м/с^2.
    @Published private(set) var bias = Vector3.zero
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProgress: Double = 0

    // MARK: - Настройки

    /// Частота опроса, Гц.
    @Published var sampleRate: Double = 50
    /// Пересчитывать ускорение в неподвижную (мировую) систему координат.
    @Published var useWorldFrame: Bool = true
    /// Автоматически калибровать смещение при старте записи.
    @Published var autoCalibrateOnStart: Bool = true
    /// Включить подавление дрейфа (leaky integrator + зона нечувствительности).
    @Published var suppressDrift: Bool = false
    /// Скользящее среднее для ускорения (0 = выключено), с.
    @Published var smoothingSeconds: Double = 0.10
    /// Порог чувствительности: ускорение слабее порога считается нулём, м/с^2.
    /// 0 — порог выключен.
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
    /// История ускорения для скользящего среднего.
    private var accelHistory: [Vector3] = []

    // MARK: - Состояние калибровки

    private var calibrationSamples: [Vector3] = []
    private var calibrationTarget = 0
    /// true, если калибровка сама запустила сеанс измерений (вне записи).
    private var calibrationOwnsSession = false

    // MARK: - Доступность

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var canExport: Bool { !samples.isEmpty }

    // MARK: - Управление записью

    func toggleRecording() {
        isRecording ? stop() : start()
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            statusMessage = "Акселерометр недоступен на этом устройстве."
            return
        }
        resetData()
        startUpdates()
        isRecording = true
        if autoCalibrateOnStart {
            beginCalibration(seconds: 1.5, ownsSession: false)
        } else {
            statusMessage = nil
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRecording = false
    }

    func reset() {
        stop()
        resetData()
        bias = .zero
        isCalibrating = false
        calibrationSamples.removeAll()
        calibrationProgress = 0
        statusMessage = nil
    }

    private func resetData() {
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
        accelHistory.removeAll()
    }

    // MARK: - Калибровка

    /// Запускает измерение смещения нуля. Телефон в это время должен лежать
    /// неподвижно. Если запись не идёт — временно включает датчик сам.
    func calibrate(seconds: Double = 1.5) {
        guard manager.isDeviceMotionAvailable else {
            statusMessage = "Акселерометр недоступен на этом устройстве."
            return
        }
        let owns = !manager.isDeviceMotionActive
        if owns { startUpdates() }
        beginCalibration(seconds: seconds, ownsSession: owns)
    }

    private func beginCalibration(seconds: Double, ownsSession: Bool) {
        let target = max(10, Int(sampleRate * seconds))
        calibrationSamples.removeAll()
        calibrationTarget = target
        calibrationOwnsSession = ownsSession
        calibrationProgress = 0
        isCalibrating = true
        statusMessage = "Калибровка… не двигайте телефон"
    }

    private func finishCalibration() {
        let count = calibrationSamples.count
        var sum = Vector3.zero
        for sample in calibrationSamples { sum = sum + sample }
        let mean = count > 0 ? sum * (1.0 / Double(count)) : Vector3.zero

        let owns = calibrationOwnsSession
        calibrationSamples.removeAll()
        calibrationOwnsSession = false

        // Сброс интегрирования, чтобы не было скачка из-за паузы калибровки.
        lastTimestamp = nil
        lastIntegratedAccel = .zero
        velocity = .zero
        displacement = .zero
        accelHistory.removeAll()

        DispatchQueue.main.async {
            self.bias = mean
            self.isCalibrating = false
            self.calibrationProgress = 0
            self.statusMessage = nil
            if owns { self.manager.stopDeviceMotionUpdates() }
        }
    }

    // MARK: - Запуск потока измерений

    private func startUpdates() {
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

        // Сырое ускорение в системе координат устройства, м/с^2.
        let rawDevice = Vector3(x: motion.userAcceleration.x * gravity,
                                y: motion.userAcceleration.y * gravity,
                                z: motion.userAcceleration.z * gravity)

        // Во время калибровки только накапливаем отсчёты и ничего не пишем.
        if isCalibrating {
            calibrationSamples.append(rawDevice)
            let progress = min(1.0, Double(calibrationSamples.count) / Double(calibrationTarget))
            DispatchQueue.main.async {
                self.calibrationProgress = progress
                self.statusMessage = "Калибровка… \(Int(progress * 100))%"
            }
            if calibrationSamples.count >= calibrationTarget {
                finishCalibration()
            }
            return
        }

        // Компенсация смещения нуля (в системе координат устройства).
        let corrected = rawDevice - bias
        var measured = corrected
        if useWorldFrame {
            measured = rotateToReferenceFrame(corrected, attitude: motion.attitude)
        }
        measured = smoothed(measured)

        // Порог чувствительности: колебания слабее порога считаются шумом покоя
        // и обнуляются. Влияет и на график, и на интегрирование.
        if deadband > 0, measured.magnitude < deadband {
            measured = .zero
        }

        // Интегрирование методом трапеций.
        let integrated = measured
        let average = (integrated + lastIntegratedAccel) * 0.5
        velocity = velocity + average * dt
        displacement = displacement + velocity * dt

        // Подавление дрейфа (экспоненциальное затухание скорости).
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

    /// Скользящее среднее по ускорению: убирает высокочастотный шум датчика
    /// и уменьшает накопление ошибки при интегрировании.
    private func smoothed(_ v: Vector3) -> Vector3 {
        let window = max(1, Int(smoothingSeconds * sampleRate))
        guard window > 1 else { return v }

        accelHistory.append(v)
        let cap = window * 2
        if accelHistory.count > cap {
            accelHistory.removeFirst(accelHistory.count - cap)
        }
        let count = min(window, accelHistory.count)
        var sum = Vector3.zero
        for index in (accelHistory.count - count)..<accelHistory.count {
            sum = sum + accelHistory[index]
        }
        return sum * (1.0 / Double(count))
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
        let biasText = String(format: "x %.4f, y %.4f, z %.4f м/с²",
                              bias.x, bias.y, bias.z)
        return """
        Данные измерений акселерометра.

        Дата: \(formatter.string(from: Date()))
        Отсчётов: \(samples.count)
        Длительность: \(String(format: "%.2f", elapsed)) с
        Частота опроса: \(rate) Гц
        Мировая система координат: \(useWorldFrame ? "да" : "нет")
        Компенсация смещения нуля: \(biasText)
        Сглаживание (скользящее среднее): \(smoothingSeconds < 0.01 ? "выключено" : String(format: "%.2f с", smoothingSeconds))
        Порог чувствительности: \(deadband < 0.005 ? "выключен" : String(format: "%.2f м/с²", deadband))
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
