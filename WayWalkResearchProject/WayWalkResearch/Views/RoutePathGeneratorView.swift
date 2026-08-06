import SwiftUI

/// Authoring tool, run once per route by a researcher on wifi — not part of
/// the experiment flow.
///
/// It asks Apple for a walking route between each consecutive pair of
/// waypoints, stitches the legs into one path, and hands back a JSON file.
/// That file gets AirDropped to the Mac, dropped into
/// `WayWalkResearch/Data/`, added to the app target, and committed — after
/// which every build draws pavements instead of straight lines, offline and
/// identically for every participant.
struct RoutePathGeneratorView: View {
    let walk: Walk

    @Environment(\.dismiss) private var dismiss
    @StateObject private var builder = RoutePathBuilder()

    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var failedLegs: [Int] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Route", value: walk.displayName)
                    LabeledContent("Waypoints", value: "\(walk.waypoints.count)")
                    LabeledContent("Legs to route", value: "\(max(walk.waypoints.count - 1, 0))")
                } header: {
                    Text("Source")
                } footer: {
                    Text("Requests are sent one leg at a time with a short pause, because Apple throttles bursts of directions requests. Expect this to take around a minute and to need a network connection.")
                }

                if builder.isBuilding {
                    Section {
                        ProgressView(
                            value: Double(builder.completedLegs),
                            total: Double(max(builder.totalLegs, 1))
                        ) {
                            Text("Routing leg \(builder.completedLegs + 1) of \(builder.totalLegs)")
                        }
                    }
                }

                if let exportedURL {
                    Section("Result") {
                        if failedLegs.isEmpty {
                            Label("All legs routed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(
                                "Legs \(failedLegs.map(String.init).joined(separator: ", ")) could not be routed and fell back to straight lines.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }

                        ShareLink(item: exportedURL) {
                            Label("Share \(exportedURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }

                    Section("Next steps") {
                        Text("""
                        1. Share the file to your Mac.
                        2. Put it in WayWalkResearch/Data/.
                        3. Add it to the app target in Xcode (Copy Bundle Resources).
                        4. Rebuild, then check the drawn line on this screen \
                        before committing — Apple's pedestrian data does not \
                        always include garden paths and internal campus routes.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task { await generate() }
                    } label: {
                        Text(exportedURL == nil ? "Generate routed path" : "Generate again")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(builder.isBuilding)
                }
            }
            .navigationTitle("Routed Path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(builder.isBuilding)
                }
            }
        }
        .interactiveDismissDisabled(builder.isBuilding)
    }

    private func generate() async {
        errorMessage = nil
        exportedURL = nil
        do {
            let path = try await builder.build(for: walk)
            failedLegs = builder.failedLegs
            exportedURL = try RoutePathBuilder.export(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
