import SwiftUI
import UIKit

/// Стандартный системный «Поделиться» — пригодится, если почта на устройстве
/// не настроена: файл можно отправить через любое приложение.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
