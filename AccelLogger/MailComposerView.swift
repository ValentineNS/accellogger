import SwiftUI
import MessageUI

/// Обёртка над MFMailComposeViewController: открывает системное окно
/// «Новое письмо» с уже вложенным файлом. Пользователь нажимает «Отправить».
struct MailComposerView: UIViewControllerRepresentable {
    let recipients: [String]?
    let subject: String
    let body: String
    let attachment: (data: Data, mimeType: String, fileName: String)?
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        if let recipients = recipients, !recipients.isEmpty {
            controller.setToRecipients(recipients)
        }
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        if let attachment = attachment {
            controller.addAttachmentData(attachment.data,
                                         mimeType: attachment.mimeType,
                                         fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let parent: MailComposerView

        init(_ parent: MailComposerView) { self.parent = parent }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true)
            parent.onFinish()
        }
    }
}
