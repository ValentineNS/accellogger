import SwiftUI

/// Один ряд данных для графика: точки (время, значение) и оформление.
struct ChartSeries: Identifiable {
    let id = UUID()
    let points: [CGPoint]
    let color: Color
    let width: CGFloat
}

/// Простой линейный график на Canvas (совместим с iOS 15,
/// поэтому не используется Swift Charts из iOS 16).
struct LineChartView: View {
    let series: [ChartSeries]
    let unit: String
    var xAxisLabel: String = "с"
    var height: CGFloat = 220

    private let axisColor = Color.secondary
    private let gridColor = Color.gray.opacity(0.22)

    var body: some View {
        if series.allSatisfy({ $0.points.isEmpty }) {
            Text("Нет данных")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            canvasBody.frame(height: height)
        }
    }

    private var canvasBody: some View {
        Canvas { context, size in
            let left: CGFloat = 48
            let right: CGFloat = 10
            let top: CGFloat = 12
            let bottom: CGFloat = 24
            let plot = CGRect(x: left, y: top,
                              width: max(1, size.width - left - right),
                              height: max(1, size.height - top - bottom))

            // Границы данных
            var xMin = Double.greatestFiniteMagnitude
            var xMax = -Double.greatestFiniteMagnitude
            var yMin = Double.greatestFiniteMagnitude
            var yMax = -Double.greatestFiniteMagnitude
            for s in series {
                for p in s.points {
                    xMin = min(xMin, Double(p.x)); xMax = max(xMax, Double(p.x))
                    yMin = min(yMin, Double(p.y)); yMax = max(yMax, Double(p.y))
                }
            }
            if !xMin.isFinite { xMin = 0; xMax = 1; yMin = 0; yMax = 1 }
            if xMax - xMin < 1e-9 { xMax = xMin + 1 }
            yMin = min(yMin, 0); yMax = max(yMax, 0)
            if yMax - yMin < 1e-9 { yMax = yMin + 1 }
            let pad = (yMax - yMin) * 0.05
            yMin -= pad; yMax += pad

            func sx(_ x: Double) -> CGFloat {
                plot.minX + CGFloat((x - xMin) / (xMax - xMin)) * plot.width
            }
            func sy(_ y: Double) -> CGFloat {
                plot.maxY - CGFloat((y - yMin) / (yMax - yMin)) * plot.height
            }

            // Горизонтальные линии сетки и подписи по Y
            let rows = 4
            for i in 0...rows {
                let value = yMin + (yMax - yMin) * Double(i) / Double(rows)
                let y = sy(value)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(gridColor), lineWidth: 0.5)

                let label = Text(String(format: "%.2f", value))
                    .font(.system(size: 9))
                    .foregroundColor(axisColor)
                context.draw(label, at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
            }

            // Подписи времени (начало и конец)
            let start = Text(String(format: "%.1f", xMin)).font(.system(size: 9)).foregroundColor(axisColor)
            let end = Text(String(format: "%.1f", xMax)).font(.system(size: 9)).foregroundColor(axisColor)
            context.draw(start, at: CGPoint(x: plot.minX, y: plot.maxY + 8), anchor: .topLeading)
            context.draw(end, at: CGPoint(x: plot.maxX, y: plot.maxY + 8), anchor: .topTrailing)

            let unitLabel = Text(xAxisLabel).font(.system(size: 9)).foregroundColor(axisColor)
            context.draw(unitLabel, at: CGPoint(x: plot.maxX, y: plot.minY - 8), anchor: .bottomTrailing)

            // Нулевая линия
            if yMin < 0 && yMax > 0 {
                var zero = Path()
                zero.move(to: CGPoint(x: plot.minX, y: sy(0)))
                zero.addLine(to: CGPoint(x: plot.maxX, y: sy(0)))
                context.stroke(zero, with: .color(axisColor.opacity(0.5)), lineWidth: 0.75)
            }

            // Кривые
            for s in series {
                guard let first = s.points.first else { continue }
                var path = Path()
                path.move(to: CGPoint(x: sx(Double(first.x)), y: sy(Double(first.y))))
                for p in s.points.dropFirst() {
                    path.addLine(to: CGPoint(x: sx(Double(p.x)), y: sy(Double(p.y))))
                }
                context.stroke(path, with: .color(s.color), lineWidth: s.width)
            }
        }
    }
}
