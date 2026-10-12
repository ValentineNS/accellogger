import SwiftUI

enum ChartQuantity: String, CaseIterable, Identifiable {
    case acceleration = "Ускорение"
    case velocity = "Скорость"
    case displacement = "Перемещение"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .acceleration: return "м/с²"
        case .velocity: return "м/с"
        case .displacement: return "м"
        }
    }
}

enum ChartAxis: String, CaseIterable, Identifiable {
    case x = "X"
    case y = "Y"
    case z = "Z"
    case total = "Модуль"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .x: return .red
        case .y: return .green
        case .z: return .blue
        case .total: return .purple
        }
    }
}

/// Экран с графиками ускорения / скорости / перемещения во времени.
struct ChartsScreen: View {
    @EnvironmentObject private var recorder: MotionRecorder

    @State private var quantity: ChartQuantity = .acceleration
    @State private var axis: ChartAxis = .total

    /// Ограничение числа точек для отрисовки (важно для слабых устройств).
    private let maxPoints = 400

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Величина", selection: $quantity) {
                    ForEach(ChartQuantity.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Picker("Ось", selection: $axis) {
                    ForEach(ChartAxis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                VStack(spacing: 6) {
                    HStack {
                        Text(quantity.rawValue)
                            .font(.headline)
                        Spacer()
                        Text("ось \(axis.rawValue), \(quantity.unit)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)

                    LineChartView(series: series, unit: quantity.unit, height: 240)
                        .padding(.horizontal)
                }
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.10))
                .cornerRadius(12)
                .padding(.horizontal)

                statsView

                if recorder.samples.isEmpty {
                    Text("Начните запись, чтобы построить график.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Графики")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Данные

    private func value(for sample: MotionSample, axis: ChartAxis) -> Double {
        switch quantity {
        case .acceleration:
            switch axis {
            case .x: return sample.accel.x
            case .y: return sample.accel.y
            case .z: return sample.accel.z
            case .total: return sample.accelTotal
            }
        case .velocity:
            switch axis {
            case .x: return sample.velocity.x
            case .y: return sample.velocity.y
            case .z: return sample.velocity.z
            case .total: return sample.velocityTotal
            }
        case .displacement:
            switch axis {
            case .x: return sample.displacement.x
            case .y: return sample.displacement.y
            case .z: return sample.displacement.z
            case .total: return sample.displacementTotal
            }
        }
    }

    /// Прореживание: не более maxPoints точек для быстрой отрисовки.
    private func decimatedSamples() -> [MotionSample] {
        let all = recorder.samples
        guard all.count > maxPoints else { return all }
        let step = Double(all.count) / Double(maxPoints)
        var result: [MotionSample] = []
        result.reserveCapacity(maxPoints)
        var position = 0.0
        while Int(position) < all.count {
            result.append(all[Int(position)])
            position += step
        }
        return result
    }

    private var series: [ChartSeries] {
        let samples = decimatedSamples()
        var result: [ChartSeries] = []

        let points = samples.map { CGPoint(x: $0.time, y: value(for: $0, axis: axis)) }
        result.append(ChartSeries(points: points, color: axis.color, width: 2))

        // Для конкретной оси дополнительно показываем «модуль» тонкой серой линией.
        if axis != .total {
            let totalPoints = samples.map { CGPoint(x: $0.time, y: value(for: $0, axis: .total)) }
            result.append(ChartSeries(points: totalPoints, color: .gray.opacity(0.55), width: 1))
        }
        return result
    }

    // MARK: - Статистика

    private var statsView: some View {
        let samples = decimatedSamples()
        let values = samples.map { value(for: $0, axis: axis) }
        let current = values.last ?? 0
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0

        return HStack(spacing: 0) {
            stat(title: "Текущее", value: current, color: axis.color)
            Divider().frame(height: 34)
            stat(title: "Минимум", value: minValue, color: .secondary)
            Divider().frame(height: 34)
            stat(title: "Максимум", value: maxValue, color: .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.10))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func stat(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(String(format: "%.3f", value))
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(color)
            Text(quantity.unit)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
struct ChartsScreen_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ChartsScreen().environmentObject(MotionRecorder())
        }
    }
}
#endif
