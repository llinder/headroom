import CoreGraphics
import CoreText
import Foundation

/// Calm colors, with the one alarm red kept for limit lines and over-the-limit marks.
enum Palette {
    static var ink: CGColor { rgb(0x1F2328) }
    static var muted: CGColor { rgb(0x6E7781) }
    static var series: CGColor { rgb(0x3B6FD8) }
    static var seriesLight: CGColor { rgb(0x3B6FD8, alpha: 0.4) }
    static var alarm: CGColor { rgb(0xC62828) }
    static var grid: CGColor { rgb(0xE5E7EB) }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

struct TextStyle {
    var size: CGFloat
    var bold = false
    var color = Palette.ink

    static var small: TextStyle { TextStyle(size: 8, color: Palette.muted) }
}

/// CoreText drawing in an unflipped PDF context, so every word stays real text a reader can search and copy.
enum Typeset {
    static func attributed(_ text: String, _ style: TextStyle) -> NSAttributedString {
        let font =
            CTFontCreateUIFontForLanguage(style.bold ? .emphasizedSystem : .system, style.size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, style.size, nil)
        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color,
            ])
    }

    static func height(_ text: String, _ style: TextStyle, width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, style))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        // Rounding up keeps the last line from being dropped by a frame a fraction of a point too short.
        return size.height.rounded(.up) + 1
    }

    /// Wraps `text` into `width` below `top` and returns the height used.
    @discardableResult
    static func draw(_ text: String, _ style: TextStyle, ctx: CGContext, x: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
        let h = height(text, style, width: width)
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, style))
        let frame = CTFramesetterCreateFrame(
            setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: x, y: top - h, width: width, height: h), transform: nil),
            nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        return h
    }

    static func width(_ text: String, _ style: TextStyle) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text, style)), nil, nil, nil))
    }

    enum Align { case left, center, right }

    /// One unwrapped line whose baseline sits at `y`.
    static func line(_ text: String, _ style: TextStyle, ctx: CGContext, x: CGFloat, y: CGFloat, align: Align = .left) {
        let line = CTLineCreateWithAttributedString(attributed(text, style))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let start =
            switch align {
            case .left: x
            case .center: x - w / 2
            case .right: x - w
            }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: start, y: y)
        CTLineDraw(line, ctx)
    }
}

/// A daily series in display units, with every day of the range so missing days can be drawn as gaps.
struct LineSeries {
    var days: [String]
    var labels: [String]
    var stats: [DailyStat]
    var unit: String
}

/// A 0-based axis with a few round ticks, the top tick at or just above the largest value.
struct Axis {
    let step: Double
    let top: Double

    init(maximum: Double, ceiling: Double = .infinity) {
        // Non-finite, zero, negative or subnormal data would make a zero step and an endless stride, so it gets a unit span.
        let target = maximum.isNormal && maximum > 0 ? min(maximum, 1e300) * 1.05 : 1
        let raw = target / 4
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let fraction = raw / magnitude
        let nice: Double =
            if fraction <= 1 { 1 } else if fraction <= 2 { 2 } else if fraction <= 2.5 { 2.5 } else if fraction <= 5 { 5 } else { 10 }
        step = nice * magnitude
        top = min((target / step).rounded(.up) * step, max(ceiling, step))
    }

    var ticks: [Double] { stride(from: 0, through: top + step / 2, by: step).map { $0 } }
}

enum Charts {
    private static let axisWidth: CGFloat = 48
    private static let labelHeight: CGFloat = 14
    // Room above the top tick for its label and for a value printed over a full-height bar.
    private static let headroom: CGFloat = 12

    /// Daily max as a solid line and p95 as a lighter one, the machine's limit as a dashed red line, and tags as
    /// ticks along the bottom. `tags` positions are fractions of the range.
    static func dailyLine(ctx: CGContext, rect: CGRect, series: LineSeries, limit: Double, tags: [(Double, String)]) {
        let plot = CGRect(
            x: rect.minX + axisWidth, y: rect.minY + labelHeight, width: rect.width - axisWidth, height: rect.height - labelHeight - headroom)
        let axis = Axis(maximum: max(limit, series.stats.map(\.max).max() ?? 0))
        let y = { (v: Double) in plot.minY + CGFloat(min(max(v, 0), axis.top) / axis.top) * plot.height }
        let n = series.days.count
        let x = { (i: Int) in plot.minX + (CGFloat(i) + 0.5) / CGFloat(max(n, 1)) * plot.width }

        drawGrid(ctx: ctx, plot: plot, axis: axis, y: y) { "\(Wording.trimmed($0)) \(series.unit)" }

        for i in Set([0, n / 2, n - 1]).sorted() where i >= 0 && i < series.labels.count {
            Typeset.line(series.labels[i], .small, ctx: ctx, x: x(i), y: rect.minY + 3, align: .center)
        }

        let byDay = Dictionary(series.stats.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        stroke(ctx: ctx, days: series.days, byDay: byDay, x: x, y: y, color: Palette.seriesLight, width: 1.2, value: \.p95)
        stroke(ctx: ctx, days: series.days, byDay: byDay, x: x, y: y, color: Palette.series, width: 1.8, value: \.max)

        if limit > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(Palette.alarm)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y(limit)), CGPoint(x: plot.maxX, y: y(limit))])
            ctx.restoreGState()
        }

        var lastLabelEnd = -CGFloat.greatestFiniteMagnitude
        for (position, text) in tags {
            let tx = plot.minX + CGFloat(min(max(position, 0), 1)) * plot.width
            ctx.setStrokeColor(Palette.ink)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: tx, y: plot.minY), CGPoint(x: tx, y: plot.minY + 6)])
            // Labels that would overlap the previous one are left off; the tick still marks the moment.
            let label = text.count > 24 ? String(text.prefix(23)) + "…" : text
            guard tx >= lastLabelEnd + 4 else { continue }
            Typeset.line(label, TextStyle(size: 7, color: Palette.muted), ctx: ctx, x: tx + 2, y: plot.minY + 8)
            lastLabelEnd = tx + 2 + Typeset.width(label, TextStyle(size: 7))
        }
    }

    /// Share of time limited at each agent count, with the capacity threshold as a dashed red line.
    static func bars(ctx: CGContext, rect: CGRect, values: [(Int, Double)], threshold: Double) {
        guard !values.isEmpty else {
            Typeset.draw(
                "Not enough AI agent activity recorded yet.", TextStyle(size: 11, color: Palette.muted), ctx: ctx,
                x: rect.minX, top: rect.maxY, width: rect.width)
            return
        }
        let plot = CGRect(
            x: rect.minX + axisWidth, y: rect.minY + labelHeight, width: rect.width - axisWidth, height: rect.height - labelHeight - headroom)
        // A share can never pass 100%, so the axis stops there even when rounding up would go further.
        let axis = Axis(maximum: max(threshold * 2, values.map(\.1).max() ?? 0), ceiling: 1)
        let y = { (v: Double) in plot.minY + CGFloat(min(max(v, 0), axis.top) / axis.top) * plot.height }
        drawGrid(ctx: ctx, plot: plot, axis: axis, y: y) { Wording.percent($0) }

        let slot = plot.width / CGFloat(values.count)
        let barWidth = min(36, slot * 0.6)
        for (i, (agents, share)) in values.enumerated() {
            let center = plot.minX + (CGFloat(i) + 0.5) * slot
            ctx.setFillColor(Palette.series)
            ctx.fill(CGRect(x: center - barWidth / 2, y: plot.minY, width: barWidth, height: y(share) - plot.minY))
            Typeset.line(Wording.percent(share), TextStyle(size: 8), ctx: ctx, x: center, y: y(share) + 3, align: .center)
            Typeset.line(Wording.plural(agents, "agent"), .small, ctx: ctx, x: center, y: rect.minY + 3, align: .center)
        }

        ctx.saveGState()
        ctx.setStrokeColor(Palette.alarm)
        ctx.setLineWidth(1.2)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y(threshold)), CGPoint(x: plot.maxX, y: y(threshold))])
        ctx.restoreGState()
    }

    struct LegendItem {
        var label: String
        var color: CGColor
        var dashed = false
    }

    /// Right-aligned legend keys drawn as short strokes in each series' own color, with `y` as the baseline.
    static func legend(ctx: CGContext, right: CGFloat, y: CGFloat, items: [LegendItem]) {
        var x = right
        for item in items.reversed() {
            x -= Typeset.width(item.label, .small)
            Typeset.line(item.label, .small, ctx: ctx, x: x, y: y)
            ctx.saveGState()
            ctx.setStrokeColor(item.color)
            ctx.setLineWidth(1.6)
            if item.dashed { ctx.setLineDash(phase: 0, lengths: [3, 2]) }
            ctx.strokeLineSegments(between: [CGPoint(x: x - 18, y: y + 3), CGPoint(x: x - 4, y: y + 3)])
            ctx.restoreGState()
            x -= 30
        }
    }

    private static func drawGrid(
        ctx: CGContext, plot: CGRect, axis: Axis, y: (Double) -> CGFloat, label: (Double) -> String
    ) {
        ctx.setStrokeColor(Palette.grid)
        ctx.setLineWidth(0.6)
        for tick in axis.ticks {
            ctx.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y(tick)), CGPoint(x: plot.maxX, y: y(tick))])
            Typeset.line(label(tick), .small, ctx: ctx, x: plot.minX - 6, y: y(tick) - 3, align: .right)
        }
    }

    /// A day with no data ends the line, so a gap is never drawn as zero; a lone day is a dot.
    private static func stroke(
        ctx: CGContext, days: [String], byDay: [String: DailyStat], x: (Int) -> CGFloat, y: (Double) -> CGFloat,
        color: CGColor, width: CGFloat, value: KeyPath<DailyStat, Double>
    ) {
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        var run: [CGPoint] = []
        func flush() {
            if run.count == 1, let p = run.first {
                ctx.fillEllipse(in: CGRect(x: p.x - width, y: p.y - width, width: width * 2, height: width * 2))
            } else if run.count > 1 {
                ctx.addLines(between: run)
                ctx.strokePath()
            }
            run = []
        }
        for (i, day) in days.enumerated() {
            if let stat = byDay[day] { run.append(CGPoint(x: x(i), y: y(stat[keyPath: value]))) } else { flush() }
        }
        flush()
    }
}
