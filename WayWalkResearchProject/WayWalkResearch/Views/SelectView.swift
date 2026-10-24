import SwiftUI

/// Owns setup navigation. Destinations are injected so the role chooser does
/// not create either role's location/audio session until that role is opened.
struct SelectView<Researcher: View, Participant: View>: View {
    @ViewBuilder var researcher: () -> Researcher
    @ViewBuilder var participant: () -> Participant

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    NavigationLink(destination: researcher()) {
                        roleLabel("Researcher", description: "Set up and manage study walks")
                    }
                    .accessibilityIdentifier("role.researcher")

                    NavigationLink(destination: participant()) {
                        roleLabel("Participant", description: "Choose and start your walk")
                    }
                    .accessibilityIdentifier("role.participant")
                }
                .buttonStyle(.bordered)
                .padding()
            }
            .navigationTitle("Choose your role")
        }
    }

    private func roleLabel(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            Text(description).font(.body)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(.vertical, 12)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SelectView {
        Text("Researcher setup")
    } participant: {
        Text("Participant setup")
    }
}
