import Foundation
import CoreMotion
import Combine

/// Читает акселерометр через CoreMotion. Во время записи сохраняются сырые
/// отсчёты; после остановки весь массив проходит статистическую обработку
/// (подавление выбросов, фильтрация, фильтр Калмана) и только затем
/// интегрируется в скорость и перемещение.
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

    /// Текущее измеренное смещение нуля (в системе координат устройства), м/с².
    @Published private(set) var bias = Vector3.zero
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProgress: Double = 0

    /// Идёт статистическая обработка записанных данных.
    @Published private(set) var isProcessing = false
    /// Статистика последнего сеанса.
    @Published private(set) var statistics: SignalStatistics?

    // MARK: - Настройки

    /// Частота опроса, Гц.
    @Published var sampleRate: Double = 50
    /// Пересчитывать ускорение в неподвижную (мировую) систему координат.
    @Published var useWorldFrame: Bool = true
    /// Автоматически калибровать смещение при старте записи.
    @Published var autoCalibrateOnStart: Bool = true

    // Параметры статистической обработки.

    /// Порог фильтра Хампеля в единицах σ (0 — выбросы не удаляются).
    @Published var outlierSigma: Double = 3.0
    /// Максимальное окно адаптивного сглаживания, с (0 — выключено).
    @Published var smoothingMaxSeconds: Double = 0.20
    /// Включить фильтр Калмана.
    @Published var kalmanEnabled: Bool = true
    /// Степень сглаживания Калмана, 0…1.
    @Published var kalmanSmoothing: Double = 0.5
    /// Порог чувствительности: ускорение слабее порога считается нулём, м/с².
    @Published var deadband: Double = 0.05
    /// Порог скорости: скорость слабее порога обнуляется, м/с.
    @Published var velocityDeadband: Double = 0.05
    /// Подавление дрейфа: обнаружение покоя и обнуление скорости (ZUPT).
    @Published var suppressDrift: Bool = true

    // MARK: - Core Motion

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MotionRecorder.queue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Очередь статистической постобработки.
    private let processingQueue = DispatchQueue(label: "MotionRecorder.processing",
                                                qos: .userInitiated)

    /// 1 g в м/с².
    private let gravity: Double = 9.80665

    // MARK: - Состояние записи

    private var referenceTime: TimeInterval = 0
    private var lastTimestamp: TimeInterval?
    private var counter = 0
    /// Идентификатор сеанса: защищает от применения устаревшей обработки.
    private var recordingID = 0
    /// Сырые отсчёты текущего/последнего сеанса.
    private var rawSamples: [RawMotionSample] = []

    // MARK: - Состояние калибровки

    private var calibrationSamples: [Vector3] = []
    private var calibrationTarget = 0
    /// true, если калибровка сама запустила сеанс измерений (вне записи).
    private var calibrationOwnsSession = false
    /// Признак активного сбора калибровочных отсчётов (читается на очереди датчика).
    private var calibrationActive = false

    // MARK: - Доступность

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var canExport: Bool {
        !samples.isEmpty && !isRecording && !isProcessing && statistics != nil
    }

    // MARK: - Управление записью

    func toggleRecording() {
        isRecording ? stop() : start()
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            statusMessage = "Акселерометр недоступен на этом устройстве."
            return
        }
        recordingID += 1
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
        finalizeProcessing()
    }

    /// Повторно обрабатывает последний сеанс текущими параметрами (без записи).
    func reprocess() {
        guard !isRecording, !isProcessing, !rawSamples.isEmpty else { return }
        finalizeProcessing()
    }

    func reset() {
        // Обесценить возможную обработку «в полёте».
        recordingID += 1
        manager.stopDeviceMotionUpdates()
        isRecording = false
        resetData()
        bias = .zero
        isCalibrating = false
        calibrationActive = false
        calibrationSamples.removeAll()
        calibrationProgress = 0
        statistics = nil
        isProcessing = false
        statusMessage = nil
    }

    private func resetData() {
        samples.removeAll()
        rawSamples.removeAll()
        elapsed = 0
        liveAccel = .zero
        liveVelocity = .zero
        liveDisplacement = .zero
        lastTimestamp = nil
        counter = 0
        statistics = nil
        isProcessing = false
        calibrationActive = false
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
        calibrationActive = true
        calibrationProgress = 0
        isCalibrating = true
        statusMessage = "Калибровка… не двигайте телефон"
    }

    private func finishCalibration() {
        let count = calibrationSamples.count
        var sum = Vector3.zero
        for sample in calibrationSamples { sum = sum + sample }
        let mean = count > 0 ? sum * (1.0 / Double(count)) : Vector3.zero

        // Останавливаем сбор синхронно (на очереди датчика), чтобы калибровка
        // не запустилась повторно; публикуем результат уже в главном потоке.
        let owns = calibrationOwnsSession
        calibrationActive = false
        calibrationSamples.removeAll()
        calibrationOwnsSession = false

        DispatchQueue.main.async {
            self.bias = mean
            self.isCalibrating = false
            self.calibrationProgress = 0
            self.statusMessage = nil
            if owns { self.manager.stopDeviceMotionUpdates() }
        }
        // После калибровки отсчёт времени начинается заново.
        lastTimestamp = nil
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

    /// Во время записи только сохраняет сырой отсчёт и обновляет «живой» график.
    private func process(_ motion: CMDeviceMotion) {
        let now = motion.timestamp
        if lastTimestamp == nil {
            lastTimestamp = now
            referenceTime = now
        }
        guard let previous = lastTimestamp else { return }
        lastTimestamp = now

        // Сырое ускорение в системе координат устройства, м/с².
        let rawDevice = Vector3(x: motion.userAcceleration.x * gravity,
                                y: motion.userAcceleration.y * gravity,
                                z: motion.userAcceleration.z * gravity)

        // Во время калибровки только накапливаем отсчёты и ничего не пишем.
        if calibrationActive {
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

        _ = previous
        let corrected = rawDevice - bias
        let measured = useWorldFrame
            ? rotateToReferenceFrame(corrected, attitude: motion.attitude)
            : corrected

        let time = now - referenceTime
        let record = RawMotionSample(index: counter, time: time,
                                     accelDevice: rawDevice, accel: measured)
        rawSamples.append(record)
        counter += 1

        // «Живой» график: показываем необработанное ускорение, скорость и
        // перемещение появятся после статистической обработки при остановке.
        let preview = MotionSample(index: record.index, time: time,
                                   accel: measured, velocity: .zero, displacement: .zero)
        DispatchQueue.main.async {
            self.samples.append(preview)
            self.liveAccel = measured
            self.elapsed = time
        }
    }

    // MARK: - Постобработка

    private var processingSettings: ProcessingSettings {
        ProcessingSettings(sampleRate: sampleRate,
                           outlierSigma: outlierSigma,
                           outlierWindowSeconds: 0.10,
                           medianWindow: 3,
                           smoothingMaxSeconds: smoothingMaxSeconds,
                           kalmanEnabled: kalmanEnabled,
                           kalmanSmoothing: kalmanSmoothing,
                           deadband: deadband,
                           velocityDeadband: velocityDeadband,
                           stationarityDetection: suppressDrift)
    }

    private func finalizeProcessing() {
        guard !rawSamples.isEmpty else { return }
        let id = recordingID
        let times = rawSamples.map { $0.time }
        let accelerations = rawSamples.map { $0.accel }
        let settings = processingSettings

        isProcessing = true
        statusMessage = "Статистическая обработка…"
        processingQueue.async { [weak self] in
            let (signal, stats) = SignalProcessor.process(times: times,
                                                          raw: accelerations,
                                                          settings: settings)
            DispatchQueue.main.async {
                guard let self = self, self.recordingID == id else { return }
                self.applyProcessed(signal, statistics: stats)
            }
        }
    }

    private func applyProcessed(_ signal: ProcessedSignal, statistics: SignalStatistics) {
        var processed: [MotionSample] = []
        let n = min(rawSamples.count, signal.accel.count)
        processed.reserveCapacity(n)
        for i in 0..<n {
            processed.append(MotionSample(index: rawSamples[i].index,
                                          time: rawSamples[i].time,
                                          accel: signal.accel[i],
                                          velocity: signal.velocity[i],
                                          displacement: signal.displacement[i]))
        }
        samples = processed
        self.statistics = statistics
        isProcessing = false
        statusMessage = nil
        liveVelocity = signal.velocity.last ?? .zero
        liveDisplacement = signal.displacement.last ?? .zero
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

    /// Формирует текстовый файл (CSV, разделитель ";") с заголовком и всеми
    /// отсчётами. Обработанные данные и сырое ускорение — рядом.
    func csvString() -> String {
        let header = ["N", "t, s",
                      "ax, м/с2", "ay, м/с2", "az, м/с2", "a, м/с2",
                      "Vx, м/с", "Vy, м/с", "Vz, м/с", "V, м/с",
                      "Sx, м", "Sy, м", "Sz, м", "S, м",
                      "ax_raw, м/с2", "ay_raw, м/с2", "az_raw, м/с2"]
        var out = header.joined(separator: ";") + "\n"
        out.reserveCapacity(samples.count * 160)

        for (i, s) in samples.enumerated() {
            let raw = i < rawSamples.count ? rawSamples[i].accelDevice : .zero
            let row = [String(s.index),
                       format(s.time),
                       format(s.accel.x), format(s.accel.y), format(s.accel.z), format(s.accelTotal),
                       format(s.velocity.x), format(s.velocity.y), format(s.velocity.z), format(s.velocityTotal),
                       format(s.displacement.x), format(s.displacement.y), format(s.displacement.z), format(s.displacementTotal),
                       format(raw.x), format(raw.y), format(raw.z)]
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

    /// Формирует книгу Excel (.xlsx): таблица данных + 12 графиков + сырые
    /// данные и статистика.
    func makeExcelFile() throws -> URL {
        let data = XLSXWriter.makeWorkbook(samples: samples,
                                           statistics: statistics,
                                           rawSamples: rawSamples)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "motion_\(formatter.string(from: Date())).xlsx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
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
        var text = """
        Данные измерений акселерометра.

        Дата: \(formatter.string(from: Date()))
        Отсчётов: \(samples.count)
        Длительность: \(String(format: "%.2f", elapsed)) с
        Частота опроса: \(rate) Гц
        Мировая система координат: \(useWorldFrame ? "да" : "нет")
        Компенсация смещения нуля: \(biasText)

        Статистическая обработка:
        Подавление выбросов (Хампель): \(outlierSigma < 0.01 ? "выключено" : String(format: "%.1f σ", outlierSigma))
        Медианный фильтр: \(smoothingMaxSeconds < 0.01 ? "выключен" : "включён")
        Адаптивное сглаживание: \(smoothingMaxSeconds < 0.01 ? "выключено" : String(format: "до %.2f с", smoothingMaxSeconds))
        Фильтр Калмана: \(kalmanEnabled ? String(format: "включён (сглаживание %.2f)", kalmanSmoothing) : "выключен")
        Порог чувствительности: \(deadband < 0.005 ? "выключен" : String(format: "%.2f м/с²", deadband))
        Порог скорости: \(velocityDeadband < 0.005 ? "выключен" : String(format: "%.3f м/с", velocityDeadband))
        Подавление дрейфа (ZUPT): \(suppressDrift ? "включено" : "выключено")

        Файл: книга Excel (.xlsx).
        Лист «Данные» — таблица обработанных отсчётов:
        N — номер отсчёта;
        t, s — время от начала, с;
        ax/ay/az, м/с² — ускорение по осям и его модуль, м/с²;
        Vx/Vy/Vz, м/с — скорость по осям и её модуль, м/с;
        Sx/Sy/Sz, м — перемещение по осям и расстояние от начала, м.
        Лист «Сырые данные» — необработанное ускорение датчика.
        Лист «Статистика» — статистические характеристики сеанса.
        12 листов-диаграмм — ускорение, скорость и перемещение по осям
        X/Y/Z и их модули во времени (по одному графику на листе).

        Примечание: скорость и перемещение получены интегрированием ускорения
        (в тракте обработки — с фильтром Калмана), поэтому при длительной
        записи возможен накопительный дрейф.
        """
        if let statistics = statistics {
            text += "\n\nСтатистика сеанса:\n"
            for (label, value) in statistics.rows() where !label.isEmpty {
                text += value.isEmpty ? "\(label)\n" : "\(label): \(value)\n"
            }
        }
        return text
    }
}
