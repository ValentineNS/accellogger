import SwiftUI
import MessageUI

struct ContentView: View {
    @EnvironmentObject private var recorder: MotionRecorder

    @State private var recipient = ""
    @State private var showingMail = false
    @State private var showingShare = false
    @State private var attachment: (data: Data, mimeType: String, fileName: String)?

    var body: some View {
        NavigationView {
            Form {
                statusSection
                controlSection
                liveSection
                chartsSection
                settingsSection
                exportSection
            }
            .navigationTitle("Акселерометр")
            .sheet(isPresented: $showingMail, onDismiss: { attachment = nil }) {
                MailComposerView(recipients: recipients,
                                 subject: "Данные акселерометра",
                                 body: recorder.emailBody(),
                                 attachment: attachment,
                                 onFinish: { showingMail = false })
            }
            .sheet(isPresented: $showingShare) {
                if let url = recorder.lastExportURL {
                    ShareSheet(items: [url])
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Секции

    private var statusSection: some View {
        Section {
            HStack {
                Text("Состояние")
                Spacer()
                Text(recorder.isRecording ? "Запись…" : "Остановлено")
                    .foregroundColor(recorder.isRecording ? .green : .secondary)
            }
            HStack {
                Text("Отсчётов")
                Spacer()
                Text("\(recorder.samples.count)").monospacedDigit()
            }
            HStack {
                Text("Длительность")
                Spacer()
                Text(String(format: "%.2f с", recorder.elapsed)).monospacedDigit()
            }
            HStack {
                Text("Смещение нуля")
                Spacer()
                Text(biasString(recorder.bias))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if recorder.isCalibrating {
                HStack {
                    Text("Калибровка")
                    Spacer()
                    Text("\(Int(recorder.calibrationProgress * 100)) %")
                        .monospacedDigit()
                        .foregroundColor(.orange)
                }
            }
            if !recorder.isAvailable {
                Text("Акселерометр недоступен")
                    .foregroundColor(.red)
            }
            if let message = recorder.statusMessage {
                Text(message)
                    .foregroundColor(recorder.isCalibrating ? .orange : .red)
            }
        }
    }

    private var controlSection: some View {
        Section {
            Button {
                recorder.toggleRecording()
            } label: {
                Label(recorder.isRecording ? "Остановить" : "Начать запись",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundColor(recorder.isRecording ? .red : .green)
            }
            .disabled(!recorder.isAvailable)

            Button {
                recorder.calibrate()
            } label: {
                Label(recorder.isCalibrating ? "Калибровка…" : "Калибровка (обнуление)",
                      systemImage: "scope")
            }
            .disabled(recorder.isCalibrating || !recorder.isAvailable)

            Button {
                recorder.reset()
            } label: {
                Label("Сбросить", systemImage: "arrow.counterclockwise")
            }
            .disabled(recorder.samples.isEmpty && !recorder.isRecording)
        }
    }

    private var liveSection: some View {
        Section("Текущие значения") {
            valueRow(title: "Ускорение", vector: recorder.liveAccel, unit: "м/с²",
                     total: recorder.liveAccel.magnitude)
            valueRow(title: "Скорость", vector: recorder.liveVelocity, unit: "м/с",
                     total: recorder.liveVelocity.magnitude)
            valueRow(title: "Перемещение", vector: recorder.liveDisplacement, unit: "м",
                     total: recorder.liveDisplacement.magnitude)
        }
    }

    private var chartsSection: some View {
        Section {
            NavigationLink(destination: ChartsScreen()) {
                Label("Графики", systemImage: "chart.xyaxis.line")
            }
        }
    }

    private var settingsSection: some View {
        Section("Параметры") {
            VStack(alignment: .leading) {
                HStack {
                    Text("Частота")
                    Spacer()
                    Text("\(Int(recorder.sampleRate)) Гц").foregroundColor(.secondary)
                }
                Slider(value: $recorder.sampleRate, in: 10...100, step: 10)
            }
            .disabled(recorder.isRecording)

            Toggle("Автокалибровка при старте", isOn: $recorder.autoCalibrateOnStart)
                .disabled(recorder.isRecording)
            Text("В начале записи телефон должен полежать неподвижно ~1,5 с — измеряется и вычитается смещение нуля датчика.")
                .font(.footnote).foregroundColor(.secondary)

            Toggle("Мировая система координат", isOn: $recorder.useWorldFrame)
                .disabled(recorder.isRecording)
            Text("Ускорение пересчитывается в неподвижную систему — оси не «крутятся» вместе с телефоном.")
                .font(.footnote).foregroundColor(.secondary)

            Toggle("Подавлять дрейф", isOn: $recorder.suppressDrift)
            if recorder.suppressDrift {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Время затухания")
                        Spacer()
                        Text(String(format: "%.1f с", recorder.velocityHalfLife))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $recorder.velocityHalfLife, in: 0.5...10, step: 0.5)
                }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Сглаживание")
                    Spacer()
                    Text(recorder.smoothingSeconds < 0.01
                         ? "выкл"
                         : String(format: "%.2f с", recorder.smoothingSeconds))
                        .foregroundColor(.secondary)
                }
                Slider(value: $recorder.smoothingSeconds, in: 0...0.5, step: 0.02)
            }
            Text("Скользящее среднее по ускорению. Убирает шум на графике и уменьшает дрейф скорости. 0 — без сглаживания.")
                .font(.footnote).foregroundColor(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Text("Порог чувствительности")
                    Spacer()
                    Text(recorder.deadband < 0.005
                         ? "выкл"
                         : String(format: "%.2f м/с²", recorder.deadband))
                        .foregroundColor(.secondary)
                }
                Slider(value: $recorder.deadband, in: 0...1.0, step: 0.01)
            }
            Text("Ускорение слабее этого порога считается шумом покоя и обнуляется — убирает «дрожание» графика в покое. 0 — выключено.")
                .font(.footnote).foregroundColor(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Text("Порог скорости")
                    Spacer()
                    Text(recorder.velocityDeadband < 0.005
                         ? "выкл"
                         : String(format: "%.3f м/с", recorder.velocityDeadband))
                        .foregroundColor(.secondary)
                }
                Slider(value: $recorder.velocityDeadband, in: 0...0.5, step: 0.005)
            }
            Text("Скорость слабее этого порога считается нулём — перемещение перестаёт «уползать» после остановки. 0 — выключено.")
                .font(.footnote).foregroundColor(.secondary)

            Text("Скорость и перемещение получаются интегрированием ускорения и со временем накапливают погрешность. Компенсация смещения нуля и подавление дрейфа уменьшают этот рост.")
                .font(.footnote).foregroundColor(.secondary)
        }
    }

    private var exportSection: some View {
        Section("Отправка") {
            TextField("E-mail получателя (необязательно)", text: $recipient)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)

            Button {
                prepareAndSend()
            } label: {
                Label("Отправить на e-mail", systemImage: "envelope")
            }
            .disabled(!recorder.canExport)

            Button {
                prepareAndShare()
            } label: {
                Label("Поделиться файлом", systemImage: "square.and.arrow.up")
            }
            .disabled(!recorder.canExport)

            if !MFMailComposeViewController.canSendMail() {
                Text("Почтовый аккаунт на устройстве не настроен — используйте «Поделиться файлом».")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Вспомогательные представления

    private func valueRow(title: String, vector: Vector3, unit: String, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            Text(String(format: "x %@   y %@   z %@",
                        format(vector.x), format(vector.y), format(vector.z)))
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.secondary)
            Text("модуль: \(format(total)) \(unit)")
                .font(.system(.footnote, design: .monospaced))
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func biasString(_ vector: Vector3) -> String {
        String(format: "x %@  y %@  z %@",
               format(vector.x), format(vector.y), format(vector.z))
    }

    private var recipients: [String]? {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : [trimmed]
    }

    // MARK: - Действия

    private func prepareAndSend() {
        do {
            let url = try recorder.makeExportFile()
            let data = try Data(contentsOf: url)
            attachment = (data, "text/csv", url.lastPathComponent)
            showingMail = true
        } catch {
            recorder.statusMessage = "Не удалось создать файл: \(error.localizedDescription)"
        }
    }

    private func prepareAndShare() {
        do {
            _ = try recorder.makeExportFile()
            showingShare = true
        } catch {
            recorder.statusMessage = "Не удалось создать файл: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environmentObject(MotionRecorder())
    }
}
#endif
