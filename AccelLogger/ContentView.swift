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
                statisticsSection
                statsSection
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
                Text(stateText)
                    .foregroundColor(stateColor)
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
            Text("Скорость и перемещение рассчитываются после остановки записи — при статистической обработке всего массива отсчётов.")
                .font(.footnote).foregroundColor(.secondary)
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
        Section("Параметры записи") {
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
        }
    }

    private var statisticsSection: some View {
        Section("Статистическая обработка") {
            VStack(alignment: .leading) {
                HStack {
                    Text("Порог выбросов (Хампель)")
                    Spacer()
                    Text(recorder.outlierSigma < 0.01
                         ? "выкл"
                         : String(format: "%.1f σ", recorder.outlierSigma))
                        .foregroundColor(.secondary)
                }
                Slider(value: $recorder.outlierSigma, in: 0...6, step: 0.5)
            }
            Text("Робастное подавление выпадающих точек: отсчёт заменяется медианой окна, если отклонился больше чем на указанное число σ (медиана + MAD). 0 — выключено.")
                .font(.footnote).foregroundColor(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Text("Адаптивное сглаживание")
                    Spacer()
                    Text(recorder.smoothingMaxSeconds < 0.01
                         ? "выкл"
                         : String(format: "до %.2f с", recorder.smoothingMaxSeconds))
                        .foregroundColor(.secondary)
                }
                Slider(value: $recorder.smoothingMaxSeconds, in: 0...0.5, step: 0.02)
            }
            Text("Медианный фильтр и сглаживание скользящим средним. Окно подбирается автоматически по уровню шума: шум снимается, но реальный сигнал не «съедается».")
                .font(.footnote).foregroundColor(.secondary)

            Toggle("Фильтр Калмана", isOn: $recorder.kalmanEnabled)
            if recorder.kalmanEnabled {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Степень сглаживания")
                        Spacer()
                        Text(String(format: "%.2f", recorder.kalmanSmoothing))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $recorder.kalmanSmoothing, in: 0...1, step: 0.05)
                }
                Text("Совместная оценка ускорения, скорости и перемещения; даёт доверительный интервал и снижает дрейф.")
                    .font(.footnote).foregroundColor(.secondary)
            }

            Toggle("Подавлять дрейф (обнуление в покое)", isOn: $recorder.suppressDrift)
            Text("При обнаружении покоя скорость принудительно обнуляется (ZUPT) — перемещение не «уползает».")
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
            Text("Ускорение слабее этого порога считается шумом покоя и обнуляется. 0 — выключено.")
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
            Text("Скорость слабее этого порога считается нулём. 0 — выключено.")
                .font(.footnote).foregroundColor(.secondary)

            Text("Обработка применяется ко всему массиву отсчётов после остановки записи, затем выполняется интегрирование.")
                .font(.footnote).foregroundColor(.secondary)

            if !recorder.isRecording && !recorder.samples.isEmpty {
                Button {
                    recorder.reprocess()
                } label: {
                    Label("Обработать заново", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(recorder.isProcessing)
            }
        }
    }

    private var statsSection: some View {
        Group {
            if recorder.statistics != nil {
                Section("Итоги сеанса") {
                    ForEach(statisticsRows.indices, id: \.self) { index in
                        HStack {
                            Text(statisticsRows[index].0)
                            Spacer()
                            Text(statisticsRows[index].1)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        .font(.footnote)
                    }
                }
            }
        }
    }

    /// Строки статистики без пустых подписей.
    private var statisticsRows: [(String, String)] {
        (recorder.statistics?.rows() ?? []).filter { !$0.0.isEmpty }
    }

    private var exportSection: some View {
        Section("Отправка") {
            TextField("E-mail получателя (необязательно)", text: $recipient)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)

            Button {
                prepareAndSendExcel()
            } label: {
                Label("Отправить Excel на e-mail", systemImage: "envelope")
            }
            .disabled(!recorder.canExport)

            Button {
                prepareAndShareExcel()
            } label: {
                Label("Поделиться Excel-файлом", systemImage: "square.and.arrow.up")
            }
            .disabled(!recorder.canExport)

            Button {
                prepareAndShareCSV()
            } label: {
                Label("Поделиться CSV-файлом", systemImage: "tablecells")
            }
            .disabled(!recorder.canExport)

            if !MFMailComposeViewController.canSendMail() {
                Text("Почтовый аккаунт на устройстве не настроен — используйте «Поделиться файлом».")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Вспомогательные представления

    private var stateText: String {
        if recorder.isProcessing { return "Обработка…" }
        if recorder.isRecording { return "Запись…" }
        return "Остановлено"
    }

    private var stateColor: Color {
        if recorder.isProcessing { return .orange }
        if recorder.isRecording { return .green }
        return .secondary
    }

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

    private let xlsxMimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    private func prepareAndSendExcel() {
        do {
            let url = try recorder.makeExcelFile()
            let data = try Data(contentsOf: url)
            attachment = (data, xlsxMimeType, url.lastPathComponent)
            showingMail = true
        } catch {
            recorder.statusMessage = "Не удалось создать Excel-файл: \(error.localizedDescription)"
        }
    }

    private func prepareAndShareExcel() {
        do {
            _ = try recorder.makeExcelFile()
            showingShare = true
        } catch {
            recorder.statusMessage = "Не удалось создать Excel-файл: \(error.localizedDescription)"
        }
    }

    private func prepareAndShareCSV() {
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
