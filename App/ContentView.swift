import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Subscriptions",
                systemImage: "dot.radiowaves.up.forward",
                description: Text("Feeds you add will appear here.")
            )
            .navigationTitle("Srssly")
        }
    }
}

#Preview {
    ContentView()
}
