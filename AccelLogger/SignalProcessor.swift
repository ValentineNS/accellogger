import Foundation

// MARK: - Сырой отсчёт

/// Отсчёт, сохраняемый во время записи. Обработка (подавление выбросов,
/// фильтрация, интегрирование) выполняется после остановки записи.
struct RawMotionSample {
    /// Порядковый номер отсчёта.
    let index: Int
    /// Время от начала записи, с.
    let time: Double
    /// Сырое ускорение в системе координат устройства (без компенсации
    /// смещения нуля), м/с².
    let accelDevice: Vector3
    /// Рабочее ускорение: мировая система координат, смещение нуля вычтено, м/с².
    let accel: Vector3
}

// MARK: - Настройки обработки

/// Параметры статистической обработки сигнала акселерометра.
struct ProcessingSettings {
    /// Частота опроса, Гц (нужна для выбора окон).
    var sampleRate: Double
    /// Порог фильтра Хампеля в единицах σ (0 — выбросы не удаляются).
    var outlierSigma: Double
    /// Полуокно фильтра Хампеля, с.
    var outlierWindowSeconds: Double
    /// Ширина медианного фильтра, отсчётов (должна быть нечётной; 1 — выкл).
    var medianWindow: Int
    /// Максимальное окно адаптивного сглаживания, с (0 — выкл).
    var smoothingMaxSeconds: Double
    /// Включить фильтр Калмана (совместная оценка ускорения/скорости/перемещения).
    var kalmanEnabled: Bool
    /// Степень сглаживания Калмана, 0…1 (больше — глаже).
    var kalmanSmoothing: Double
    /// Порог чувствительности ускорения, м/с² (0 — выкл).
    var deadband: Double
    /// Порог скорости, м/с (0 — выкл).
    var velocityDeadband: Double
    /// Подавление дрейфа: обнуление скорости при обнаружении покоя (ZUPT).
    var stationarityDetection: Bool
}

// MARK: - Результат обработки

/// Обработанные каналы, выровненные с исходными отсчётами.
struct ProcessedSignal {
    /// Статистически обработанное ускорение, м/с².
    var accel: [Vector3]
    /// Оценка скорости, м/с.
    var velocity: [Vector3]
    /// Оценка перемещения, м.
    var displacement: [Vector3]
    /// Стандартное отклонение оценки перемещения (доверительный интервал), м.
    var positionStd: [Double]
}

// MARK: - Статистика

/// Основные статистические характеристики одного канала.
struct AxisStatistics {
    var axis: String
    var mean: Double
    var std: Double
    var minimum: Double
    var maximum: Double
    var rms: Double
    var skewness: Double
    var excessKurtosis: Double
    var noiseSigma: Double
    var outliers: Int
    var maxOutlier: Double
}

/// Сводная статистика по сеансу.
struct SignalStatistics {
    var sampleCount: Int
    var duration: Double
    var nominalRate: Double
    var achievedRate: Double
    var outliersTotal: Int
    var axes: [AxisStatistics]
    var peakAccel: Double
    var peakVelocity: Double
    var peakDisplacement: Double
    /// Итоговая (на конец записи) оценка неопределённости перемещения, м.
    var finalPositionStd: Double

    /// Строки «параметр — значение» для отображения и экспорта.
    func rows() -> [(String, String)] {
        var out: [(String, String)] = []
        out.append(("Отсчётов", "\(sampleCount)"))
        out.append(("Длительность, с", fmt(duration)))
        out.append(("Частота (номинал), Гц", fmt(nominalRate)))
        out.append(("Частота (факт), Гц", fmt(achievedRate)))
        out.append(("Выбросов отброшено", "\(outliersTotal)"))
        out.append(("Пиковое ускорение, м/с²", fmt(peakAccel)))
        out.append(("Пиковая скорость, м/с", fmt(peakVelocity)))
        out.append(("Пиковое перемещение, м", fmt(peakDisplacement)))
        out.append(("Неопределённость перемещения, м", fmt(finalPositionStd)))
        for s in axes {
            out.append(("", ""))
            out.append(("Ось \(s.axis)", ""))
            out.append(("  среднее, м/с²", fmt(s.mean)))
            out.append(("  СКО, м/с²", fmt(s.std)))
            out.append(("  минимум, м/с²", fmt(s.minimum)))
            out.append(("  максимум, м/с²", fmt(s.maximum)))
            out.append(("  СКЗ (RMS), м/с²", fmt(s.rms)))
            out.append(("  асимметрия", fmt(s.skewness)))
            out.append(("  эксцесс", fmt(s.excessKurtosis)))
            out.append(("  шум (σ), м/с²", fmt(s.noiseSigma)))
            out.append(("  выбросов", "\(s.outliers)"))
            out.append(("  макс. выброс, м/с²", fmt(s.maxOutlier)))
        }
        return out
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.6g", v)
    }
}

// MARK: - Обработчик

/// Статистическая обработка сигнала акселерометра:
/// 1) робастное подавление выбросов (фильтр Хампеля: медиана + MAD);
/// 2) медианный фильтр;
/// 3) адаптивное сглаживание (окно выбирается по уровню шума);
/// 4) фильтр Калмана [перемещение, скорость, ускорение] — интегрирование
///    с совместной оценкой состояния и доверительными интервалами;
/// 5) статистическая сводка по осям и сеансу.
enum SignalProcessor {

    static let gravity = 9.80665

    // MARK: Публичный интерфейс

    static func process(times: [Double],
                        raw: [Vector3],
                        settings: ProcessingSettings) -> (ProcessedSignal, SignalStatistics) {
        let n = min(times.count, raw.count)
        guard n > 0 else {
            return (ProcessedSignal(accel: [], velocity: [], displacement: [], positionStd: []),
                    SignalStatistics(sampleCount: 0, duration: 0, nominalRate: settings.sampleRate,
                                     achievedRate: 0, outliersTotal: 0, axes: [],
                                     peakAccel: 0, peakVelocity: 0, peakDisplacement: 0,
                                     finalPositionStd: 0))
        }

        let rate = max(1.0, settings.sampleRate)
        let halfWindow = max(1, Int((settings.outlierWindowSeconds * rate).rounded()))
        let medianWindow = settings.medianWindow >= 3 ? (settings.medianWindow | 1) : 1
        let maxSmoothWindow = oddWindow(Int((settings.smoothingMaxSeconds * rate).rounded()))

        var channels: [[Double]] = [[], [], []]
        var outliers = [0, 0, 0]
        var maxOutlier = [0.0, 0.0, 0.0]

        // 1–3. Подавление выбросов + медиана + адаптивное сглаживание, по осям.
        for axis in 0..<3 {
            let series = raw.map { component($0, axis) }
            let (cleaned, count, dev) = hampel(series, halfWindow: halfWindow,
                                               threshold: settings.outlierSigma)
            outliers[axis] = count
            maxOutlier[axis] = dev
            let medianFiltered = medianWindow > 1 ? medianFilter(cleaned, window: medianWindow) : cleaned
            let noise = robustNoise(medianFiltered)
            let smoothed = adaptiveSmooth(medianFiltered, maxWindow: maxSmoothWindow, noise: noise)
            channels[axis] = smoothed
        }

        // Итоговое ускорение (до Калмана) и его остаточный шум.
        var filteredAccel: [Vector3] = []
        filteredAccel.reserveCapacity(n)
        var residualSigma = [0.0, 0.0, 0.0]
        for i in 0..<n {
            filteredAccel.append(Vector3(x: channels[0][i], y: channels[1][i], z: channels[2][i]))
        }
        for axis in 0..<3 {
            let series = raw.map { component($0, axis) }
            var sq = 0.0
            for i in 0..<n { let d = series[i] - channels[axis][i]; sq += d * d }
            residualSigma[axis] = (sq / Double(n)).squareRoot()
        }

        // 4. Фильтр Калмана или простое интегрирование.
        let signal: ProcessedSignal
        if settings.kalmanEnabled {
            signal = kalman(times: times, accel: filteredAccel,
                            sigmaAccel: residualSigma, settings: settings)
        } else {
            signal = integrate(times: times, accel: filteredAccel, settings: settings)
        }

        // 5. Статистика (по обработанному ускорению).
        let xCh = signal.accel.map { $0.x }
        let yCh = signal.accel.map { $0.y }
        let zCh = signal.accel.map { $0.z }
        let axesStats = [
            axisStatistics("X", xCh, outliers: outliers[0], maxOutlier: maxOutlier[0]),
            axisStatistics("Y", yCh, outliers: outliers[1], maxOutlier: maxOutlier[1]),
            axisStatistics("Z", zCh, outliers: outliers[2], maxOutlier: maxOutlier[2]),
        ]

        let duration = max(0, (times.last ?? 0) - (times.first ?? 0))
        let achieved = n > 1 && duration > 0 ? Double(n - 1) / duration : settings.sampleRate
        let peakAccel = signal.accel.map { $0.magnitude }.max() ?? 0
        let peakVelocity = signal.velocity.map { $0.magnitude }.max() ?? 0
        let peakDisplacement = signal.displacement.map { $0.magnitude }.max() ?? 0

        let statistics = SignalStatistics(
            sampleCount: n,
            duration: duration,
            nominalRate: settings.sampleRate,
            achievedRate: achieved,
            outliersTotal: outliers.reduce(0, +),
            axes: axesStats,
            peakAccel: peakAccel,
            peakVelocity: peakVelocity,
            peakDisplacement: peakDisplacement,
            finalPositionStd: signal.positionStd.last ?? 0)

        return (signal, statistics)
    }

    // MARK: Робастные фильтры

    /// Фильтр Хампеля: в скользящем окне считается медиана и MAD; отсчёты,
    /// отклонившиеся больше чем на threshold·σ, заменяются медианой.
    static func hampel(_ x: [Double], halfWindow: Int,
                       threshold: Double) -> (clean: [Double], outliers: Int, maxDeviation: Double) {
        guard threshold > 0, halfWindow >= 1, x.count > 2 else { return (x, 0, 0) }
        let n = x.count
        var y = x
        var count = 0
        var maxDev = 0.0
        for i in 0..<n {
            let lo = max(0, i - halfWindow)
            let hi = min(n - 1, i + halfWindow)
            let window = Array(x[lo...hi])
            let md = median(window)
            let mad = median(window.map { abs($0 - md) })
            let sigma = 1.4826 * mad
            guard sigma > 1e-12 else { continue }
            let dev = abs(x[i] - md)
            if dev > threshold * sigma {
                y[i] = md
                count += 1
                maxDev = max(maxDev, dev)
            }
        }
        return (y, count, maxDev)
    }

    /// Медианный фильтр с нечётным окном.
    static func medianFilter(_ x: [Double], window: Int) -> [Double] {
        let w = max(3, window | 1)
        let half = w / 2
        let n = x.count
        var y = x
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            y[i] = median(Array(x[lo...hi]))
        }
        return y
    }

    /// Адаптивное сглаживание центрированным скользящим средним. Окно растёт,
    /// пока невязка (данные − сглаженное) остаётся на уровне шума. Так шум
    /// сглаживается максимально, но реальный сигнал не «съедается».
    static func adaptiveSmooth(_ x: [Double], maxWindow: Int, noise: Double) -> [Double] {
        let limit = maxWindow | 1
        guard limit >= 3, x.count > 2 else { return x }
        let tolerance = max(noise * 1.15, 1e-9)
        var best = x
        var w = 3
        while w <= limit {
            let y = movingAverage(x, window: w)
            if rmsResidual(x, y) <= tolerance {
                best = y
            } else {
                break
            }
            w += 2
        }
        return best
    }

    /// Центрированное скользящее среднее (некаузальное — допустимо при
    /// постобработке). На краях окно сужается.
    static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        let w = max(1, window | 1)
        guard w > 1 else { return x }
        let n = x.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        let half = w / 2
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            y[i] = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return y
    }

    // MARK: Интегрирование

    /// Простое интегрирование методом трапеций (если Калман выключен).
    static func integrate(times: [Double], accel: [Vector3],
                          settings: ProcessingSettings) -> ProcessedSignal {
        let n = accel.count
        var velocity = Vector3.zero
        var displacement = Vector3.zero
        var velocities: [Vector3] = []
        var displacements: [Vector3] = []
        var accels: [Vector3] = []
        velocities.reserveCapacity(n)
        displacements.reserveCapacity(n)
        accels.reserveCapacity(n)
        var previous = accel.first ?? .zero
        for i in 0..<n {
            let dt = i > 0 ? max(0, times[i] - times[i - 1]) : 0
            let current = accel[i]
            let measured = applyDeadband(current, settings.deadband)
            let average = (measured + previous) * 0.5
            velocity = velocity + average * dt
            displacement = displacement + velocity * dt
            velocity = applyVelocityDeadband(velocity, settings.velocityDeadband)
            previous = measured
            accels.append(measured)
            velocities.append(velocity)
            displacements.append(displacement)
        }
        return ProcessedSignal(accel: accels, velocity: velocities,
                               displacement: displacements,
                               positionStd: [Double](repeating: 0, count: n))
    }

    // MARK: Фильтр Калмана

    /// Фильтр Калмана с состоянием [перемещение, скорость, ускорение] на ось.
    /// Ускорение наблюдается напрямую, а скорость и перемещение получаются
    /// интегрированием с коррекцией. Даёт оценку неопределённости.
    static func kalman(times: [Double], accel: [Vector3],
                       sigmaAccel: [Double],
                       settings: ProcessingSettings) -> ProcessedSignal {
        let n = accel.count
        var ax = AxisKalman()
        var ay = AxisKalman()
        var az = AxisKalman()
        ax.reset(settings: settings, sigma: sigmaAccel[0])
        ay.reset(settings: settings, sigma: sigmaAccel[1])
        az.reset(settings: settings, sigma: sigmaAccel[2])

        var outAccel: [Vector3] = []
        var outVelocity: [Vector3] = []
        var outDisplacement: [Vector3] = []
        var outPositionStd: [Double] = []
        outAccel.reserveCapacity(n)
        outVelocity.reserveCapacity(n)
        outDisplacement.reserveCapacity(n)
        outPositionStd.reserveCapacity(n)

        let epsilon = 1.0 / max(1.0, settings.sampleRate)
        var stationary = 0

        for i in 0..<n {
            let dt = i > 0 ? (times[i] - times[i - 1]) : epsilon
            let step = dt > 0 ? dt : epsilon
            ax.predict(dt: step)
            ay.predict(dt: step)
            az.predict(dt: step)

            // Обнаружение покоя для подавления дрейфа (ZUPT).
            if settings.stationarityDetection {
                let magnitude = accel[i].magnitude
                if magnitude < max(settings.deadband, 0.05) {
                    stationary += 1
                } else {
                    stationary = 0
                }
                if stationary > Int(0.3 * settings.sampleRate) {
                    ax.zeroVelocityUpdate()
                    ay.zeroVelocityUpdate()
                    az.zeroVelocityUpdate()
                }
            }

            ax.update(measurement: accel[i].x)
            ay.update(measurement: accel[i].y)
            az.update(measurement: accel[i].z)

            var velocity = Vector3(x: ax.velocity, y: ay.velocity, z: az.velocity)
            velocity = applyVelocityDeadband(velocity, settings.velocityDeadband)

            outAccel.append(Vector3(x: ax.accel, y: ay.accel, z: az.accel))
            outVelocity.append(velocity)
            outDisplacement.append(Vector3(x: ax.position, y: ay.position, z: az.position))
            let posStd = (ax.positionVariance + ay.positionVariance + az.positionVariance).squareRoot()
            outPositionStd.append(posStd)
        }

        return ProcessedSignal(accel: outAccel, velocity: outVelocity,
                               displacement: outDisplacement, positionStd: outPositionStd)
    }

    // MARK: Статистика оси

    static func axisStatistics(_ axis: String, _ x: [Double],
                               outliers: Int, maxOutlier: Double) -> AxisStatistics {
        let n = x.count
        guard n > 0 else {
            return AxisStatistics(axis: axis, mean: 0, std: 0, minimum: 0, maximum: 0, rms: 0,
                                  skewness: 0, excessKurtosis: 0, noiseSigma: 0,
                                  outliers: outliers, maxOutlier: maxOutlier)
        }
        let mean = x.reduce(0, +) / Double(n)
        var m2 = 0.0, m3 = 0.0, m4 = 0.0
        for v in x {
            let d = v - mean
            let d2 = d * d
            m2 += d2
            m3 += d2 * d
            m4 += d2 * d2
        }
        m2 /= Double(n); m3 /= Double(n); m4 /= Double(n)
        let std = m2.squareRoot()
        let rms = (m2 + mean * mean).squareRoot()
        let skew = std > 1e-12 ? m3 / (std * std * std) : 0
        let kurt = std > 1e-12 ? m4 / (std * std * std * std) - 3 : 0
        return AxisStatistics(axis: axis, mean: mean, std: std,
                              minimum: x.min() ?? 0, maximum: x.max() ?? 0, rms: rms,
                              skewness: skew, excessKurtosis: kurt,
                              noiseSigma: robustNoise(x),
                              outliers: outliers, maxOutlier: maxOutlier)
    }

    // MARK: Вспомогательное

    /// Робастная оценка СКО шума по первым разностям (медиана + MAD).
    static func robustNoise(_ x: [Double]) -> Double {
        guard x.count > 2 else { return 0 }
        var diffs = [Double](repeating: 0, count: x.count - 1)
        for i in 0..<x.count - 1 { diffs[i] = x[i + 1] - x[i] }
        let md = median(diffs)
        let mad = median(diffs.map { abs($0 - md) })
        return 1.4826 * mad / sqrt(2.0)
    }

    private static func rmsResidual(_ x: [Double], _ y: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        var sq = 0.0
        for i in 0..<x.count { let d = x[i] - y[i]; sq += d * d }
        return (sq / Double(x.count)).squareRoot()
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) * 0.5
    }

    private static func oddWindow(_ value: Int) -> Int {
        if value <= 1 { return 1 }
        return value % 2 == 1 ? value : value + 1
    }

    private static func component(_ v: Vector3, _ axis: Int) -> Double {
        axis == 0 ? v.x : (axis == 1 ? v.y : v.z)
    }

    private static func applyDeadband(_ v: Vector3, _ threshold: Double) -> Vector3 {
        guard threshold > 0 else { return v }
        return v.magnitude < threshold ? .zero : v
    }

    private static func applyVelocityDeadband(_ v: Vector3, _ threshold: Double) -> Vector3 {
        guard threshold > 0 else { return v }
        return v.magnitude < threshold ? .zero : v
    }
}

// MARK: - Матрица 3×3

/// Минимальная плотная матрица 3×3 (по строкам) для фильтра Калмана.
private struct Mat3 {
    var a = 0.0, b = 0.0, c = 0.0
    var d = 0.0, e = 0.0, f = 0.0
    var g = 0.0, h = 0.0, i = 0.0

    static let zero = Mat3()

    static func + (l: Mat3, r: Mat3) -> Mat3 {
        Mat3(a: l.a + r.a, b: l.b + r.b, c: l.c + r.c,
             d: l.d + r.d, e: l.e + r.e, f: l.f + r.f,
             g: l.g + r.g, h: l.h + r.h, i: l.i + r.i)
    }

    static func - (l: Mat3, r: Mat3) -> Mat3 {
        Mat3(a: l.a - r.a, b: l.b - r.b, c: l.c - r.c,
             d: l.d - r.d, e: l.e - r.e, f: l.f - r.f,
             g: l.g - r.g, h: l.h - r.h, i: l.i - r.i)
    }

    static func * (l: Mat3, r: Mat3) -> Mat3 {
        Mat3(a: l.a * r.a + l.b * r.d + l.c * r.g,
             b: l.a * r.b + l.b * r.e + l.c * r.h,
             c: l.a * r.c + l.b * r.f + l.c * r.i,
             d: l.d * r.a + l.e * r.d + l.f * r.g,
             e: l.d * r.b + l.e * r.e + l.f * r.h,
             f: l.d * r.c + l.e * r.f + l.f * r.i,
             g: l.g * r.a + l.h * r.d + l.i * r.g,
             h: l.g * r.b + l.h * r.e + l.i * r.h,
             i: l.g * r.c + l.h * r.f + l.i * r.i)
    }

    func transposed() -> Mat3 {
        Mat3(a: a, b: d, c: g, d: b, e: e, f: h, g: c, h: f, i: i)
    }
}

// MARK: - Калман по одной оси

/// Состояние [перемещение, скорость, ускорение] и его ковариация.
private struct AxisKalman {
    var position = 0.0
    var velocity = 0.0
    var accel = 0.0
    var covariance = Mat3.zero
    var measurementNoise = 1e-4
    var jerkStd = 1.0

    mutating func reset(settings: ProcessingSettings, sigma: Double) {
        position = 0
        velocity = 0
        accel = 0
        measurementNoise = max(sigma * sigma, 1e-8)
        // Больше сглаживание — меньше разрешённый рывок.
        jerkStd = max(sigma, 1e-4) * pow(10.0, 1.5 - 3.0 * min(max(settings.kalmanSmoothing, 0), 1))
        covariance = Mat3.zero
        covariance.i = measurementNoise
    }

    mutating func predict(dt: Double) {
        // F = [[1, dt, dt²/2], [0, 1, dt], [0, 0, 1]]
        let dt2 = dt * dt
        let f = Mat3(a: 1, b: dt, c: 0.5 * dt2,
                     d: 0, e: 1, f: dt,
                     g: 0, h: 0, i: 1)
        position = position + velocity * dt + 0.5 * accel * dt2
        velocity = velocity + accel * dt

        let q = jerkStd * jerkStd
        let dt3 = dt2 * dt, dt4 = dt3 * dt, dt5 = dt4 * dt
        let noise = Mat3(a: q * dt5 / 20, b: q * dt4 / 8, c: q * dt3 / 6,
                         d: q * dt4 / 8, e: q * dt3 / 3, f: q * dt2 / 2,
                         g: q * dt3 / 6, h: q * dt2 / 2, i: q * dt)
        covariance = f * covariance * f.transposed() + noise
    }

    /// Коррекция по измерению ускорения (H = [0, 0, 1]).
    mutating func update(measurement z: Double) {
        let s = covariance.i + measurementNoise
        guard s > 1e-15 else { return }
        let k = Vector3(x: covariance.c / s, y: covariance.f / s, z: covariance.i / s)
        let innovation = z - accel
        position += k.x * innovation
        velocity += k.y * innovation
        accel += k.z * innovation
        let row = Vector3(x: covariance.g, y: covariance.h, z: covariance.i)
        covariance = covariance - outer(k, row)
    }

    /// Псевдоизмерение нулевой скорости при покое (H = [0, 1, 0]).
    mutating func zeroVelocityUpdate() {
        let noise = max(measurementNoise * 1e-2, 1e-10)
        let s = covariance.e + noise
        guard s > 1e-15 else { return }
        let k = Vector3(x: covariance.b / s, y: covariance.e / s, z: covariance.h / s)
        let innovation = -velocity
        position += k.x * innovation
        velocity += k.y * innovation
        accel += k.z * innovation
        let row = Vector3(x: covariance.d, y: covariance.e, z: covariance.f)
        covariance = covariance - outer(k, row)
    }

    var positionVariance: Double { max(covariance.a, 0) }

    private func outer(_ u: Vector3, _ v: Vector3) -> Mat3 {
        Mat3(a: u.x * v.x, b: u.x * v.y, c: u.x * v.z,
             d: u.y * v.x, e: u.y * v.y, f: u.y * v.z,
             g: u.z * v.x, h: u.z * v.y, i: u.z * v.z)
    }
}
