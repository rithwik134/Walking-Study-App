import SwiftUI

/// Floating status pill shown under the header on the walk screens.
///
/// Only appears for the two states worth interrupting for — a prompt being
/// spoken, or the walk being over. The rest of the time it is absent, which is
/// the point: a permanent status line that almost always reads "Waiting to
/// arrive at 12" stops being read, so the one moment it says something
/// important goes unnoticed too.
struct WalkStatusBanner: View {
    let banner: WalkBanner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private var text: String {
        switch banner {
        case .playing(let waypointName): return "Playing: \(waypointName)"
        case .ended: return "Walk ended"
        }
    }

    private var symbol: String {
        switch banner {
        case .playing: return "speaker.wave.2.fill"
        case .ended: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch banner {
        // Green would collide with the cue button's "ready" state, and orange
        // with test mode, so speech gets its own colour.
        case .playing: return .blue
        case .ended: return Color(.darkGray)
        }
    }
}

extension View {
    /// Floats a `WalkStatusBanner` just under the header, animating in and out.
    func walkStatusBanner(_ banner: WalkBanner?) -> some View {
        overlay(alignment: .top) {
            if let banner {
                WalkStatusBanner(banner: banner)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: banner)
    }
}
