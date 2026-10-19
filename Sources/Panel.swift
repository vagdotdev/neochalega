import SwiftUI

struct Panel: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("NEOCHALEGA")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .tracking(1.6)
                Spacer()
                Text(engine.phase == .on ? "LIVE" : "IDLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(engine.phase == .on ? Color(red: 1, green: 0.42, blue: 0.16) : .white.opacity(0.45))
            }
            Text(engine.hostName)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 6)
            Text("\(engine.hostCores) cores · \(Engine.format(engine.hostMemory))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))

            ThrottleButton(phase: engine.phase, progress: engine.progress) {
                engine.toggle()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Text(engine.detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)

            HStack(spacing: 16) {
                Meter(label: "HELD", value: engine.phase == .on || engine.phase == .arming ? Engine.format(engine.heldBytes) : "0")
                Meter(label: "BURN", value: engine.phase == .on ? String(format: "%.1f cores", engine.burnCores) : "0")
            }
            .padding(.top, 14)

            Text("GPU cores and memory bandwidth stay as they are on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 300, alignment: .leading)
        .background(Color(red: 0.09, green: 0.086, blue: 0.08))
    }
}

private struct Meter: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThrottleButton: View {
    var phase: Engine.Phase
    var progress: Double
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    draw(context: context, size: size, time: t)
                }
                .frame(width: 168, height: 168)
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .releasing)
        .accessibilityLabel(phase == .on ? "Turn Neo throttle off" : "Turn Neo throttle on")
    }

    private func draw(context: GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let engaged = phase == .on || phase == .arming
        let spin = engaged ? time.truncatingRemainder(dividingBy: 8) / 8 : time.truncatingRemainder(dividingBy: 24) / 24
        let disc = Path(ellipseIn: CGRect(x: center.x - 78, y: center.y - 78, width: 156, height: 156))
        context.fill(disc, with: .color(Color(red: 0.11, green: 0.105, blue: 0.098)))

        let ticks = 36
        for i in 0..<ticks {
            let angle = (Double(i) / Double(ticks) + spin) * .pi * 2 - .pi / 2
            let hot = engaged && (phase == .on || Double(i) / Double(ticks) <= max(progress, 0.04))
            let inner: CGFloat = hot ? 58 : 62
            let outer: CGFloat = hot ? 74 : 70
            var tick = Path()
            tick.move(to: point(center, angle, inner))
            tick.addLine(to: point(center, angle, outer))
            let color = hot
                ? Color(red: 1, green: 0.42, blue: 0.16)
                : Color.white.opacity(0.28)
            context.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: hot ? 2.4 : 1.4, lineCap: .round))
        }

        let ringRadius: CGFloat = 46
        let ring = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        context.stroke(ring, with: .color(.white.opacity(engaged ? 0.14 : 0.08)), lineWidth: 1)

        if engaged {
            let trim = phase == .on ? 0.72 : max(0.08, progress * 0.72)
            var arc = Path()
            arc.addArc(center: center, radius: 46, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * trim), clockwise: false)
            context.stroke(
                arc,
                with: .color(Color(red: 1, green: 0.42, blue: 0.16)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }

        let title = phase == .on ? "ON" : (phase == .releasing ? "OFF" : (phase == .arming ? "…" : "GO"))
        context.draw(
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(.white),
            at: center
        )
        _ = disc
        _ = ring
    }

    private func point(_ center: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
    }
}
