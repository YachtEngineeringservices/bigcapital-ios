import SwiftUI

@main
struct YESBooksApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @AppStorage("server") private var server = ""

    var body: some View {
        TabView {
            GlanceView()
                .tabItem { Label("Glance", systemImage: "gauge.with.dots.needle.50percent") }
            NeedsView()
                .tabItem { Label("Needs you", systemImage: "tray.full") }
            ReceiptView()
                .tabItem { Label("Receipt", systemImage: "camera") }
            PayrollView()
                .tabItem { Label("Payroll", systemImage: "person.text.rectangle") }
        }
        // First launch: ask for the server address before anything else.
        .sheet(isPresented: Binding(get: { server.isEmpty }, set: { _ in })) {
            SettingsView(firstRun: true).interactiveDismissDisabled()
        }
    }
}
