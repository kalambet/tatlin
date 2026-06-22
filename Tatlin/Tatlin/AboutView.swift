import SwiftUI
import TatlinKit

/// Attribution & licenses screen (M3.8). Surfaces:
///   • app identity + version,
///   • the on-device model licenses (CC-BY models legally require attribution —
///     pyannote / WeSpeaker via FluidInference, Parakeet, Qwen3), sourced from the
///     same `ModelManifest.default` the downloader/Models tab use, and
///   • the principal open-source frameworks Tatlin is built on.
struct AboutView: View {
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image("MenuBarTower")
                        .renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tatlin").font(.headline)
                        Text(appVersion).font(.caption).foregroundStyle(.secondary)
                        Text("On-device meeting notes. © 2026 Peter Kalambet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(ModelManifest.default, id: \.key) { spec in
                    LicenseRow(title: spec.displayName,
                               subtitle: "\(spec.kind.rawValue.uppercased()) · \(spec.license)",
                               url: huggingFaceURL(for: spec.displayName))
                }
            } header: {
                Text("On-device models")
            } footer: {
                Text("CC-BY-4.0 models require attribution. Speaker diarization derives from "
                     + "pyannote (Hervé Bredin et al.) and WeSpeaker, packaged as CoreML by "
                     + "FluidInference. Model cards are linked above.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Open-source software") {
                ForEach(Self.frameworks) { fw in
                    LicenseRow(title: fw.name, subtitle: fw.license, url: URL(string: fw.urlString))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Best-effort `https://huggingface.co/<repo>` from a `displayName` that starts with the repo id.
    private func huggingFaceURL(for displayName: String) -> URL? {
        guard let repo = displayName.split(separator: " ").first, repo.contains("/") else { return nil }
        return URL(string: "https://huggingface.co/\(repo)")
    }

    // Principal dependencies (the user-facing ones); the full transitive set is in
    // Package.resolved. Licenses verified against each project's repository.
    struct Framework: Identifiable {
        let name: String, license: String, urlString: String
        var id: String { name }
    }
    static let frameworks: [Framework] = [
        .init(name: "FluidAudio", license: "Apache-2.0",
              urlString: "https://github.com/FluidInference/FluidAudio"),
        .init(name: "WhisperKit (argmax-oss-swift)", license: "MIT",
              urlString: "https://github.com/argmaxinc/WhisperKit"),
        .init(name: "MLX Swift", license: "MIT",
              urlString: "https://github.com/ml-explore/mlx-swift"),
        .init(name: "mlx-audio-swift (MLXAudio)", license: "MIT",
              urlString: "https://github.com/Blaizzy/mlx-audio-swift"),
        .init(name: "swift-transformers", license: "Apache-2.0",
              urlString: "https://github.com/huggingface/swift-transformers"),
        .init(name: "swift-huggingface", license: "Apache-2.0",
              urlString: "https://github.com/huggingface/swift-huggingface"),
        .init(name: "swift-jinja", license: "Apache-2.0",
              urlString: "https://github.com/huggingface/swift-jinja"),
        .init(name: "swift-argument-parser", license: "Apache-2.0",
              urlString: "https://github.com/apple/swift-argument-parser"),
    ]
}

/// One attribution row: title + license/meta line, with an optional external link.
private struct LicenseRow: View {
    let title: String
    let subtitle: String
    let url: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help(url.absoluteString)
            }
        }
    }
}
