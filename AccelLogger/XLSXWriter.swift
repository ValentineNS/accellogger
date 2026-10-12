import Foundation

/// Генератор книги Excel (.xlsx) без внешних зависимостей.
///
/// Файл .xlsx — это ZIP-архив с XML-частями. Архив пишется **без сжатия**
/// (метод store), что полностью поддерживается Excel; так надёжнее, чем
/// собственная реализация DEFLATE.
///
/// Книга содержит три листа:
/// 1. «Данные»        — таблица всех отсчётов;
/// 2. «Графики»       — 12 встроенных диаграмм;
/// 3. «ГрафикДанные»  — служебный (скрытый) лист с прореженными данными,
///                      на которые ссылаются диаграммы.
enum XLSXWriter {

    // MARK: - Пространства имён

    private enum NS {
        static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        static let c = "http://schemas.openxmlformats.org/drawingml/2006/chart"
        static let xdr = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
        static let ct = "http://schemas.openxmlformats.org/package/2006/content-types"
        static let pr = "http://schemas.openxmlformats.org/package/2006/relationships"
    }

    // MARK: - Описания столбцов

    private static let dataHeaders = ["index", "time_s",
                                      "ax_m_s2", "ay_m_s2", "az_m_s2", "a_total_m_s2",
                                      "vx_m_s", "vy_m_s", "vz_m_s", "v_total_m_s",
                                      "sx_m", "sy_m", "sz_m", "s_total_m"]

    private static let chartHeaders = ["time_s", "ax", "ay", "az", "a_total",
                                       "vx", "vy", "vz", "v_total",
                                       "sx", "sy", "sz", "s_total"]

    private static let chartTitles = ["Ускорение X", "Ускорение Y", "Ускорение Z", "Главное ускорение",
                                      "Скорость X", "Скорость Y", "Скорость Z", "Главная скорость",
                                      "Перемещение X", "Перемещение Y", "Перемещение Z", "Главное перемещение"]

    private static let chartColors = ["FF0000", "00B050", "0070C0", "7030A0",
                                      "FF0000", "00B050", "0070C0", "7030A0",
                                      "FF0000", "00B050", "0070C0", "7030A0"]

    /// Сколько точек максимум попадает на диаграммы (для скорости Excel).
    private static let maxChartPoints = 300

    // MARK: - Публичный интерфейс

    static func makeWorkbook(samples: [MotionSample]) -> Data {
        let chartSamples = decimate(samples, maxCount: maxChartPoints)

        var files: [Entry] = []
        files.append(Entry("[Content_Types].xml", contentTypes()))
        files.append(Entry("_rels/.rels", rootRels()))
        files.append(Entry("docProps/core.xml", coreXML()))
        files.append(Entry("docProps/app.xml", appXML()))
        files.append(Entry("xl/workbook.xml", workbookXML()))
        files.append(Entry("xl/_rels/workbook.xml.rels", workbookRels()))
        files.append(Entry("xl/styles.xml", stylesXML()))
        files.append(Entry("xl/worksheets/sheet1.xml", sheetDataXML(samples)))
        files.append(Entry("xl/worksheets/sheet2.xml", sheetCanvasXML()))
        files.append(Entry("xl/worksheets/sheet3.xml", sheetChartDataXML(chartSamples)))
        files.append(Entry("xl/worksheets/_rels/sheet2.xml.rels", sheetDrawingRels()))
        files.append(Entry("xl/drawings/drawing1.xml", drawingXML()))
        files.append(Entry("xl/drawings/_rels/drawing1.xml.rels", drawingRels()))

        let xValues = chartSamples.map { $0.time }
        let lastRow = chartSamples.count + 1
        for index in 0..<12 {
            let column = columnLetter(index + 2) // B…M
            let xRef = "'ГрафикДанные'!$A$2:$A$\(lastRow)"
            let yRef = "'ГрафикДанные'!$\(column)$2:$\(column)$\(lastRow)"
            let yValues = chartSamples.map { chartValue($0, index: index) }
            files.append(Entry("xl/charts/chart\(index + 1).xml",
                               chartXML(title: chartTitles[index],
                                        color: chartColors[index],
                                        xRef: xRef, yRef: yRef,
                                        xValues: xValues, yValues: yValues)))
        }

        return archive(files)
    }

    // MARK: - Данные

    private static func chartValue(_ sample: MotionSample, index: Int) -> Double {
        switch index {
        case 0: return sample.accel.x
        case 1: return sample.accel.y
        case 2: return sample.accel.z
        case 3: return sample.accelTotal
        case 4: return sample.velocity.x
        case 5: return sample.velocity.y
        case 6: return sample.velocity.z
        case 7: return sample.velocityTotal
        case 8: return sample.displacement.x
        case 9: return sample.displacement.y
        case 10: return sample.displacement.z
        default: return sample.displacementTotal
        }
    }

    private static func decimate(_ samples: [MotionSample], maxCount: Int) -> [MotionSample] {
        guard samples.count > maxCount, maxCount > 0 else { return samples }
        let step = Double(samples.count) / Double(maxCount)
        var result: [MotionSample] = []
        result.reserveCapacity(maxCount)
        var position = 0.0
        while Int(position) < samples.count {
            result.append(samples[Int(position)])
            position += step
        }
        return result
    }

    // MARK: - Листы

    private static func sheetDataXML(_ samples: [MotionSample]) -> String {
        var out = header()
        out += "<worksheet xmlns=\"\(NS.main)\" xmlns:r=\"\(NS.r)\"><sheetData>"

        out += "<row r=\"1\">"
        for (index, title) in dataHeaders.enumerated() {
            out += stringCell("\(columnLetter(index + 1))1", title)
        }
        out += "</row>"

        out.reserveCapacity(out.count + samples.count * 360)
        for (offset, sample) in samples.enumerated() {
            let row = offset + 2
            out += "<row r=\"\(row)\">"
            let values: [Double] = [Double(sample.index), sample.time,
                                    sample.accel.x, sample.accel.y, sample.accel.z, sample.accelTotal,
                                    sample.velocity.x, sample.velocity.y, sample.velocity.z, sample.velocityTotal,
                                    sample.displacement.x, sample.displacement.y, sample.displacement.z, sample.displacementTotal]
            for (column, value) in values.enumerated() {
                out += numberCell("\(columnLetter(column + 1))\(row)", value)
            }
            out += "</row>"
        }

        out += "</sheetData></worksheet>"
        return out
    }

    private static func sheetCanvasXML() -> String {
        header()
            + "<worksheet xmlns=\"\(NS.main)\" xmlns:r=\"\(NS.r)\">"
            + "<sheetData/>"
            + "<drawing r:id=\"rId1\"/>"
            + "</worksheet>"
    }

    private static func sheetChartDataXML(_ chartSamples: [MotionSample]) -> String {
        var out = header()
        out += "<worksheet xmlns=\"\(NS.main)\" xmlns:r=\"\(NS.r)\"><sheetData>"

        out += "<row r=\"1\">"
        for (index, title) in chartHeaders.enumerated() {
            out += stringCell("\(columnLetter(index + 1))1", title)
        }
        out += "</row>"

        for (offset, sample) in chartSamples.enumerated() {
            let row = offset + 2
            out += "<row r=\"\(row)\">"
            var values: [Double] = [sample.time]
            for index in 0..<12 { values.append(chartValue(sample, index: index)) }
            for (column, value) in values.enumerated() {
                out += numberCell("\(columnLetter(column + 1))\(row)", value)
            }
            out += "</row>"
        }

        out += "</sheetData></worksheet>"
        return out
    }

    // MARK: - Диаграммы

    private static func chartXML(title: String, color: String,
                                 xRef: String, yRef: String,
                                 xValues: [Double], yValues: [Double]) -> String {
        let axX = 111111111
        let axY = 222222222
        return header()
            + "<c:chartSpace xmlns:c=\"\(NS.c)\" xmlns:a=\"\(NS.a)\" xmlns:r=\"\(NS.r)\"><c:chart>"
            + "<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(escape(title))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
            + "<c:autoTitleDeleted val=\"0\"/>"
            + "<c:plotArea><c:layout/>"
            + "<c:scatterChart><c:scatterStyle val=\"line\"/><c:varyColors val=\"0\"/>"
            + "<c:ser><c:idx val=\"0\"/><c:order val=\"0\"/>"
            + "<c:tx><c:v>\(escape(title))</c:v></c:tx>"
            + "<c:spPr><a:ln w=\"19050\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill></a:ln></c:spPr>"
            + "<c:xVal><c:numRef><c:f>\(escape(xRef))</c:f>\(numberCache(xValues))</c:numRef></c:xVal>"
            + "<c:yVal><c:numRef><c:f>\(escape(yRef))</c:f>\(numberCache(yValues))</c:numRef></c:yVal>"
            + "<c:smooth val=\"0\"/></c:ser>"
            + "<c:axId val=\"\(axX)\"/><c:axId val=\"\(axY)\"/>"
            + "</c:scatterChart>"
            + "<c:valAx><c:axId val=\"\(axX)\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"\(axY)\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"midCat\"/></c:valAx>"
            + "<c:valAx><c:axId val=\"\(axY)\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"l\"/><c:majorGridlines/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"\(axX)\"/><c:crosses val=\"autoZero\"/></c:valAx>"
            + "</c:plotArea>"
            + "<c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend>"
            + "<c:plotVisOnly val=\"0\"/>"
            + "</c:chart></c:chartSpace>"
    }

    private static func numberCache(_ values: [Double]) -> String {
        var out = "<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"\(values.count)\"/>"
        for (index, value) in values.enumerated() {
            out += "<c:pt idx=\"\(index)\"><c:v>\(number(value))</c:v></c:pt>"
        }
        out += "</c:numCache>"
        return out
    }

    private static func drawingXML() -> String {
        var anchors = ""
        for index in 0..<12 {
            let column = (index % 3) * 9
            let row = (index / 3) * 16
            anchors += "<xdr:oneCellAnchor>"
                + "<xdr:from><xdr:col>\(column)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"
                + "<xdr:ext cx=\"4572000\" cy=\"2743200\"/>"
                + "<xdr:graphicFrame macro=\"\">"
                + "<xdr:nvGraphicFramePr><xdr:cNvPr id=\"\(index + 2)\" name=\"Chart \(index + 1)\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>"
                + "<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm>"
                + "<a:graphic><a:graphicData uri=\"\(NS.c)\">"
                + "<c:chart xmlns:c=\"\(NS.c)\" xmlns:r=\"\(NS.r)\" r:id=\"rId\(index + 1)\"/>"
                + "</a:graphicData></a:graphic>"
                + "</xdr:graphicFrame>"
                + "<xdr:clientData/>"
                + "</xdr:oneCellAnchor>"
        }
        return header()
            + "<xdr:wsDr xmlns:xdr=\"\(NS.xdr)\" xmlns:a=\"\(NS.a)\" xmlns:r=\"\(NS.r)\">"
            + anchors
            + "</xdr:wsDr>"
    }

    // MARK: - Служебные части книги

    private static func workbookXML() -> String {
        header()
            + "<workbook xmlns=\"\(NS.main)\" xmlns:r=\"\(NS.r)\"><sheets>"
            + "<sheet name=\"Данные\" sheetId=\"1\" r:id=\"rId1\"/>"
            + "<sheet name=\"Графики\" sheetId=\"2\" r:id=\"rId2\"/>"
            + "<sheet name=\"ГрафикДанные\" sheetId=\"3\" state=\"hidden\" r:id=\"rId3\"/>"
            + "</sheets></workbook>"
    }

    private static func workbookRels() -> String {
        header()
            + "<Relationships xmlns=\"\(NS.pr)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(NS.r)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(NS.r)/worksheet\" Target=\"worksheets/sheet2.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"\(NS.r)/worksheet\" Target=\"worksheets/sheet3.xml\"/>"
            + "<Relationship Id=\"rId4\" Type=\"\(NS.r)/styles\" Target=\"styles.xml\"/>"
            + "</Relationships>"
    }

    private static func sheetDrawingRels() -> String {
        header()
            + "<Relationships xmlns=\"\(NS.pr)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(NS.r)/drawing\" Target=\"../drawings/drawing1.xml\"/>"
            + "</Relationships>"
    }

    private static func drawingRels() -> String {
        var out = header() + "<Relationships xmlns=\"\(NS.pr)\">"
        for index in 0..<12 {
            out += "<Relationship Id=\"rId\(index + 1)\" Type=\"\(NS.r)/chart\" Target=\"../charts/chart\(index + 1).xml\"/>"
        }
        out += "</Relationships>"
        return out
    }

    private static func rootRels() -> String {
        header()
            + "<Relationships xmlns=\"\(NS.pr)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(NS.r)/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"\(NS.r)/extended-properties\" Target=\"docProps/app.xml\"/>"
            + "</Relationships>"
    }

    private static func contentTypes() -> String {
        var out = header() + "<Types xmlns=\"\(NS.ct)\">"
        out += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        out += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        out += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for index in 1...3 {
            out += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        out += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        out += "<Override PartName=\"/xl/drawings/drawing1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
        for index in 1...12 {
            out += "<Override PartName=\"/xl/charts/chart\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>"
        }
        out += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        out += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        out += "</Types>"
        return out
    }

    private static func stylesXML() -> String {
        header()
            + "<styleSheet xmlns=\"\(NS.main)\">"
            + "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font>"
            + "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill>"
            + "<fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"2\">"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
            + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
            + "</cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            + "</styleSheet>"
    }

    private static func coreXML() -> String {
        header()
            + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
            + "xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>Данные акселерометра</dc:title>"
            + "<dc:creator>AccelLogger</dc:creator>"
            + "<cp:lastModifiedBy>AccelLogger</cp:lastModifiedBy>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">2026-01-01T00:00:00Z</dcterms:created>"
            + "</cp:coreProperties>"
    }

    private static func appXML() -> String {
        header()
            + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
            + "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
            + "<Application>AccelLogger</Application></Properties>"
    }

    // MARK: - Ячейки и форматирование

    private static func header() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    }

    private static func numberCell(_ ref: String, _ value: Double) -> String {
        "<c r=\"\(ref)\"><v>\(number(value))</v></c>"
    }

    private static func stringCell(_ ref: String, _ text: String, style: Int = 1) -> String {
        "<c r=\"\(ref)\" t=\"inlineStr\" s=\"\(style)\"><is><t>\(escape(text))</t></is></c>"
    }

    /// Формат числа как в «сыром» виде: точка как разделитель, без хвостовых нулей.
    private static func number(_ value: Double, decimals: Int = 6) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(",") { text = text.replacingOccurrences(of: ",", with: ".") }
        while text.contains(".") && text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    private static func columnLetter(_ index: Int) -> String {
        var value = index
        var result = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            value = (value - 1) / 26
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - ZIP (метод store)

    private struct Entry {
        let name: String
        let data: Data
        init(_ name: String, _ string: String) {
            self.name = name
            self.data = Data(string.utf8)
        }
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var central = Data()
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x2821 // 2020-01-01

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            output.appendLE32(0x04034b50)
            output.appendLE16(20)        // версия
            output.appendLE16(0)         // флаги
            output.appendLE16(0)         // метод: store
            output.appendLE16(dosTime)
            output.appendLE16(dosDate)
            output.appendLE32(crc)
            output.appendLE32(size)
            output.appendLE32(size)
            output.appendLE16(UInt16(nameBytes.count))
            output.appendLE16(0)
            output.append(contentsOf: nameBytes)
            output.append(entry.data)

            central.appendLE32(0x02014b50)
            central.appendLE16(20)       // версия создателя
            central.appendLE16(20)       // нужная версия
            central.appendLE16(0)        // флаги
            central.appendLE16(0)        // метод
            central.appendLE16(dosTime)
            central.appendLE16(dosDate)
            central.appendLE32(crc)
            central.appendLE32(size)
            central.appendLE32(size)
            central.appendLE16(UInt16(nameBytes.count))
            central.appendLE16(0)        // extra
            central.appendLE16(0)        // комментарий
            central.appendLE16(0)        // номер диска
            central.appendLE16(0)        // внутр. атрибуты
            central.appendLE32(0)        // внеш. атрибуты
            central.appendLE32(offset)
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        let centralSize = UInt32(central.count)

        output.appendLE32(0x06054b50)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(UInt16(entries.count))
        output.appendLE16(UInt16(entries.count))
        output.appendLE32(centralSize)
        output.appendLE32(centralOffset)
        output.appendLE16(0)
        return output
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
