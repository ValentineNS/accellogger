import Foundation

/// Простой трёхмерный вектор с арифметикой, нужной для интегрирования.
struct Vector3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vector3()

    /// Длина вектора (модуль): |v| = sqrt(x^2 + y^2 + z^2)
    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    /// Умножение вектора на скаляр.
    static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func * (lhs: Double, rhs: Vector3) -> Vector3 {
        rhs * lhs
    }
}
