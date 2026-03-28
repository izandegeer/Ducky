import SwiftUI

enum DuckyMood: Equatable {
    case sleeping    // No sessions or all idle
    case chillin     // Sessions exist, all idle
    case working     // Claude is working
    case celebrating // Task just completed
    case alert       // Needs attention/permission
}

struct DuckyAvatar: View {
    let mood: DuckyMood
    let size: CGFloat

    @State private var bobOffset: CGFloat = 0
    @State private var wobble: Double = 0
    @State private var jumpOffset: CGFloat = 0
    @State private var wingAngle: Double = 0
    @State private var zzzOpacity: Double = 0
    @State private var eyeBlink: Bool = false

    var body: some View {
        ZStack {
            // Zzz for sleeping
            if mood == .sleeping {
                Text("z")
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(zzzOpacity * 0.6))
                    .offset(x: size * 0.3, y: -size * 0.35)
                Text("z")
                    .font(.system(size: size * 0.18, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(zzzOpacity * 0.4))
                    .offset(x: size * 0.42, y: -size * 0.5)
            }

            // Duck body
            duckShape
                .offset(y: bobOffset + jumpOffset)
                .rotationEffect(.degrees(wobble), anchor: .bottom)
        }
        .frame(width: size, height: size)
        .onAppear { startAnimations() }
        .onChange(of: mood) { startAnimations() }
    }

    private var duckShape: some View {
        ZStack {
            // Body
            Ellipse()
                .fill(Color.yellow)
                .frame(width: size * 0.6, height: size * 0.4)
                .offset(y: size * 0.1)

            // Wing
            Ellipse()
                .fill(Color.yellow.opacity(0.7))
                .frame(width: size * 0.25, height: size * 0.2)
                .rotationEffect(.degrees(wingAngle), anchor: .leading)
                .offset(x: -size * 0.05, y: size * 0.08)

            // Head
            Circle()
                .fill(Color.yellow)
                .frame(width: size * 0.35, height: size * 0.35)
                .offset(x: size * 0.1, y: -size * 0.12)

            // Eye
            Group {
                if mood == .sleeping || eyeBlink {
                    // Closed eye — horizontal line
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.black)
                        .frame(width: size * 0.08, height: size * 0.02)
                        .offset(x: size * 0.16, y: -size * 0.15)
                } else {
                    // Open eye
                    Circle()
                        .fill(Color.black)
                        .frame(width: size * 0.06, height: size * 0.06)
                        .offset(x: size * 0.16, y: -size * 0.15)
                }
            }

            // Beak
            Triangle()
                .fill(Color.orange)
                .frame(width: size * 0.12, height: size * 0.08)
                .offset(x: size * 0.3, y: -size * 0.08)

            // Alert exclamation
            if mood == .alert {
                Text("!")
                    .font(.system(size: size * 0.2, weight: .black, design: .rounded))
                    .foregroundColor(.red)
                    .offset(x: size * 0.3, y: -size * 0.35)
            }

            // Celebrating stars
            if mood == .celebrating {
                Text("✨")
                    .font(.system(size: size * 0.15))
                    .offset(x: -size * 0.3, y: -size * 0.3)
                Text("✨")
                    .font(.system(size: size * 0.12))
                    .offset(x: size * 0.35, y: -size * 0.25)
            }
        }
    }

    private func startAnimations() {
        // Reset
        bobOffset = 0
        wobble = 0
        jumpOffset = 0
        wingAngle = 0
        zzzOpacity = 0

        switch mood {
        case .sleeping:
            // Gentle breathing + Zzz
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                bobOffset = 2
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                zzzOpacity = 1
            }

        case .chillin:
            // Gentle bob + occasional blink
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                bobOffset = -1.5
            }
            startBlinking()

        case .working:
            // Side to side wobble (busy)
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                wobble = 5
            }
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                wingAngle = -15
            }
            startBlinking()

        case .celebrating:
            // Jump up and down
            withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                jumpOffset = -4
            }
            withAnimation(.easeInOut(duration: 0.2).repeatForever(autoreverses: true)) {
                wingAngle = -25
            }

        case .alert:
            // Quick wobble (urgent)
            withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                wobble = 8
            }
            withAnimation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true)) {
                wingAngle = -20
            }
        }
    }

    private func startBlinking() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            eyeBlink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                eyeBlink = false
            }
        }
    }
}

// Simple triangle shape for the beak
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
