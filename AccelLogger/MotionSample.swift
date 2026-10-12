import Foundation

/// Одно измерение: ускорение, скорость и перемещение на момент времени `time`.
struct MotionSample: Identifiable {
    let id = UUID()
    /// Порядковый номер отсчёта.
    let index: Int
    /// Время от начала записи, секунды.
    let time: Double
    /// Ускорение по осям, м/с^2.
    let accel: Vector3
    /// Скорость по осям, м/с.
    let velocity: Vector3
    /// Перемещение по осям, м.
    let displacement: Vector3

    /// "Главное" (по модулю) ускорение, м/с^2.
    var accelTotal: Double { accel.magnitude }
    /// "Главная" скорость, м/с.
    var velocityTotal: Double { velocity.magnitude }
    /// "Главное" перемещение (расстояние по прямой от начала), м.
    var displacementTotal: Double { displacement.magnitude }
}
