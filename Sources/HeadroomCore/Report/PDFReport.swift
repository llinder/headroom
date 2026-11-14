import CoreGraphics
import CoreText
import Foundation

public enum PDFReportError: Error, Equatable {
    case cannotCreate(String)
}

/// The report as a US Letter PDF drawn with CoreGraphics and CoreText only.
public enum PDFReport {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54
    private static let gib = 1_073_741_824.0

    private static var title: TextStyle { TextStyle(size: 24, bold: true) }
    private static var heading: TextStyle { TextStyle(size: 14, bold: true) }
    private static var verdict: TextStyle { TextStyle(size: 14) }
    private static var body: TextStyle { TextStyle(size: 11) }
    private static var bodyBold: TextStyle { TextStyle(size: 11, bold: true) }
    private static var muted: TextStyle { TextStyle(size: 11, color: Palette.muted) }

    public static func render(_ m: ReportModel, to url: URL) throws(PDFReportError) {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
            let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw .cannotCreate(url.path) }

        var pages: [(inout Cursor, ReportModel) -> Void] = [summary, picture]
        if m.comparison != nil { pages.append(comparison) }
        pages.append(appendix)

        for (index, draw) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            var cursor = Cursor(ctx: ctx, top: pageSize.height - margin, left: margin, width: pageSize.width - 2 * margin)
            draw(&cursor, m)
            Typeset.line(m.footer, .small, ctx: ctx, x: margin, y: margin / 2)
            Typeset.line(
                "Page \(index + 1) of \(pages.count)", .small, ctx: ctx, x: pageSize.width - margin, y: margin / 2,
                align: .right)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Lays blocks out downward from the top margin.
    private struct Cursor {
        let ctx: CGContext
        var top: CGFloat
        let left: CGFloat
        let width: CGFloat

        mutating func text(_ s: String, _ style: TextStyle, after: CGFloat = 6, indent: CGFloat = 0) {
            top -= Typeset.draw(s, style, ctx: ctx, x: left + indent, top: top, width: width - indent) + after
        }

        mutating func space(_ points: CGFloat) { top -= points }

        mutating func block(height: CGFloat, after: CGFloat = 10) -> CGRect {
            let rect = CGRect(x: left, y: top - height, width: width, height: height)
            top -= height + after
            return rect
        }
    }

    // MARK: - Page 1: the decision

    private static func summary(_ c: inout Cursor, _ m: ReportModel) {
        c.text(m.title, title, after: 10)
        c.text(m.coverage, muted, after: 24)

        if m.verdicts.isEmpty {
            c.text("Not enough data in this range yet.", verdict, after: 14)
        }
        for v in m.verdicts {
            let markY = c.top - 9
            c.ctx.setFillColor(v.isProblem ? Palette.alarm : Palette.series)
            c.ctx.fillEllipse(in: CGRect(x: c.left, y: markY - 4, width: 8, height: 8))
            c.text(v.sentence, verdict, after: 12, indent: 18)
        }

        c.space(10)
        c.text("AI agents", bodyBold, after: 4)
        c.text(m.capacitySentence, verdict, after: 28)

        // A recommendation needs the same evidence as the verdicts; without a workday it would claim conclusions
        // ("8 cores are enough") the page just said it can't draw.
        guard !m.verdicts.isEmpty else { return }

        let padding: CGFloat = 16
        let inner = c.width - 2 * padding
        let reasonsHeight = m.spec.reasons.reduce(0) { $0 + Typeset.height($1, body, width: inner) + 6 }
        let height = padding * 2 + Typeset.height(m.spec.headline, heading, width: inner) + 8 + reasonsHeight
        let box = CGRect(x: c.left, y: c.top - height, width: c.width, height: height)
        c.ctx.setStrokeColor(Palette.series)
        c.ctx.setLineWidth(1.2)
        c.ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        c.ctx.strokePath()

        var inside = Cursor(ctx: c.ctx, top: box.maxY - padding, left: box.minX + padding, width: inner)
        inside.text(m.spec.headline, heading, after: 8)
        for reason in m.spec.reasons { inside.text(reason, body) }
        c.top = box.minY - 10
    }

    // MARK: - Page 2: the picture

    private static func picture(_ c: inout Cursor, _ m: ReportModel) {
        c.text("Day by day", heading, after: 10)
        let range = m.range.duration
        let tags = m.tags.map { (range > 0 ? $0.0.timeIntervalSince(m.range.start) / range : 0, $0.1) }
        let charts: [(String, [DailyStat], Double, Double, String)] = [
            ("Memory demand", m.dailyMemory, m.limits.memoryBytes, gib, "GB"),
            ("Processor: cores busy", m.dailyCPU, m.limits.cores, 1, "cores"),
            ("Disk used", m.dailyDiskUsed, m.limits.diskBytes, 1e9, "GB"),
        ]
        for (name, stats, limit, divisor, unit) in charts {
            chartHeading(
                &c, name,
                legend: [
                    .init(label: "daily max", color: Palette.series), .init(label: "daily p95", color: Palette.seriesLight),
                    .init(label: "limit", color: Palette.alarm, dashed: true),
                ])
            let scaled = stats.map {
                DailyStat(day: $0.day, avg: $0.avg / divisor, max: $0.max / divisor, p95: $0.p95 / divisor)
            }
            Charts.dailyLine(
                ctx: c.ctx, rect: c.block(height: 112, after: 14),
                series: LineSeries(days: m.days, labels: m.dayLabels, stats: scaled, unit: unit), limit: limit / divisor,
                tags: tags)
        }
        chartHeading(
            &c, "Time limited, by AI agents running at once",
            legend: [.init(label: "capacity threshold", color: Palette.alarm, dashed: true)])
        Charts.bars(ctx: c.ctx, rect: c.block(height: 104), values: m.capacityBars, threshold: m.capacityThreshold)
    }

    private static func chartHeading(_ c: inout Cursor, _ name: String, legend: [Charts.LegendItem]) {
        Charts.legend(ctx: c.ctx, right: c.left + c.width, y: c.top - 10, items: legend)
        c.text(name, bodyBold, after: 4)
    }

    // MARK: - Page 3: the comparison

    private static func comparison(_ c: inout Cursor, _ m: ReportModel) {
        guard let rows = m.comparison, let header = m.comparisonHeader else { return }
        c.text("Comparison", heading, after: 14)
        let hasPrevious = header.previousMachine != nil
        let labelWidth: CGFloat = 150
        let columns = CGFloat(hasPrevious ? 3 : 2)
        let columnWidth = (c.width - labelWidth) / columns

        func row(_ r: ComparisonRow, style: TextStyle) {
            let cells = [r.thisMachine, r.reference] + (hasPrevious ? [r.previousMachine ?? "—"] : [])
            let heights = [Typeset.height(r.label, style, width: labelWidth - 8)]
                + cells.map { Typeset.height($0, style, width: columnWidth - 8) }
            let height = (heights.max() ?? 0) + 8
            Typeset.draw(r.label, style, ctx: c.ctx, x: c.left, top: c.top - 4, width: labelWidth - 8)
            for (i, cell) in cells.enumerated() {
                Typeset.draw(
                    cell, style, ctx: c.ctx, x: c.left + labelWidth + CGFloat(i) * columnWidth, top: c.top - 4,
                    width: columnWidth - 8)
            }
            c.top -= height
            c.ctx.setStrokeColor(Palette.grid)
            c.ctx.setLineWidth(0.6)
            c.ctx.strokeLineSegments(between: [CGPoint(x: c.left, y: c.top), CGPoint(x: c.left + c.width, y: c.top)])
        }

        row(header, style: bodyBold)
        for r in rows { row(r, style: body) }
        c.space(14)
        c.text(
            "The reference column is a workload measured on another machine, described in baseline.json. "
                + "A dash means the figure wasn't recorded.", muted)
    }

    // MARK: - Appendix

    private static func appendix(_ c: inout Cursor, _ m: ReportModel) {
        let a = m.appendix
        c.text("Appendix", heading, after: 10)

        c.text("Workloads", bodyBold, after: 3)
        if a.groups.isEmpty {
            c.text("No workload samples in this range.", body)
        } else {
            for group in a.groups {
                c.text(
                    "\(group.0.displayName): \(Wording.decimal(group.cpuHours, places: 1)) CPU hours, "
                        + "up to \(Wording.decimal(group.peakMemoryGB, places: 1)) GB of memory.", body, after: 2)
            }
            c.space(4)
        }

        c.text("AI agents", bodyBold, after: 3)
        c.text(
            "\(Wording.plural(a.agentRunCount, "agent run")) started, using \(Wording.decimal(a.agentCPUHours, places: 1)) CPU hours in this range.",
            body)

        c.text("Drive writes", bodyBold, after: 3)
        if a.ssdDays >= Appendix.minProjectionDays {
            c.text("The drive took \(Wording.decimal(a.ssdWriteGBPerDay, places: 1)) GB of writes a day on average.", body, after: 2)
            c.text("At this rate the drive absorbs \(Wording.decimal(a.ssdWriteTBPerYear, places: 1)) TB of writes a year.", body)
        } else if a.ssdDays > 0 {
            c.text(
                "Drive writes were recorded on \(Wording.plural(a.ssdDays, "day")); a yearly projection needs at least \(Appendix.minProjectionDays).",
                body)
        } else {
            c.text("No drive writes were recorded in this range.", body)
        }

        c.text("Events", bodyBold, after: 3)
        c.text(
            "Thermal slowdowns (serious or worse): \(a.thermalSlowdowns). Apps closed by macOS to free memory: \(a.events["jetsam"] ?? 0). "
                + "Apps that stopped responding: \(a.events["hang"] ?? 0).", body)

        c.text("Method and thresholds", bodyBold, after: 3)
        for line in a.thresholds { c.text("• " + line, body, after: 2) }
        c.text(a.workdayDefinition, body, after: 2)
        c.space(4)

        c.text("The recorder", bodyBold, after: 3)
        c.text(
            "headroomd used \(Wording.decimal(a.recorderAvgCPUPercent, places: 2))% of one core and at most "
                + "\(Wording.decimal(a.recorderMaxFootprintMB, places: 1)) MB of memory.", body)

        c.text("Notes", bodyBold, after: 3)
        for note in a.notes { c.text(note, body, after: 2) }
    }
}
