//
//  AboutView.swift
//  jiminy-snippet
//

import SwiftUI

/// The "About Jiminy Snippet" panel — a small, non-resizable window with the
/// app icon, version, and tagline. Replaces the default SwiftUI About panel
/// so the app can present its own copy and visual identity without dragging
/// in a separate scene framework.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            appIcon
            appNameAndVersion
            tagline
            Spacer(minLength: 0)
            copyrightLine
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 360, height: 320)
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [.accentColor.opacity(0.85), .accentColor.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white)
        }
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private var appNameAndVersion: some View {
        VStack(spacing: 4) {
            Text("Jiminy Snippet")
                .font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var tagline: some View {
        Text("A modern screenshot tool for macOS — capture, annotate, share.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var copyrightLine: some View {
        Text("© 2026 Tom Lee")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    AboutView()
}
