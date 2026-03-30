import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    private let steps: [(icon: String, title: String, body: String)] = [
        (
            "waveform.circle",
            "Welcome to OpenOats",
            "A real-time meeting copilot that detects your meetings, transcribes conversations, and generates smart talking points — all running locally on your Mac."
        ),
        (
            "text.quote",
            "Live Transcript",
            "Your conversation is transcribed in real time. \"You\" captures your mic, \"Them\" captures system audio from the other side. Expand the transcript panel to follow along."
        ),
        (
            "lightbulb",
            "AI Suggestions",
            "As the conversation progresses, OpenOats pulls relevant context from your knowledge base and suggests talking points. The best suggestions surface automatically."
        ),
        (
            "rectangle.on.rectangle",
            "Floating Overlay",
            "Use the overlay button to pop out a compact floating panel — it stays on top of your meeting app so you can glance at suggestions without switching windows."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            Image(systemName: steps[currentStep].icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentTeal)
                .frame(height: 52)
                .id(currentStep) // force transition on change

            Spacer().frame(height: 20)

            // Title
            Text(steps[currentStep].title)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 10)

            // Body
            Text(steps[currentStep].body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Dots
            HStack(spacing: 8) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentTeal : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 20)

            // Buttons
            HStack {
                Button("Skip") {
                    finish()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if currentStep < steps.count - 1 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep += 1
                        }
                    } else {
                        finish()
                    }
                } label: {
                    Text(currentStep < steps.count - 1 ? "Next" : "Get Started")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.accentTeal, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
    }
}
