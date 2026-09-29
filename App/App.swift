import SwiftUI

@main
struct BigcapitalIOSApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @AppStorage("server") private var server = ""
    @AppStorage("payrollServer") private var payrollServer = ""

    var body: some View {
        TabView {
            GlanceView()
                .tabItem { Label("Glance", systemImage: "gauge.with.dots.needle.50percent") }
            NeedsView()
                .tabItem { Label("Needs you", systemImage: "tray.full") }
            ReceiptView()
                .tabItem { Label("Receipt", systemImage: "camera") }
            if !payrollServer.trimmingCharacters(in: .whitespaces).isEmpty {
                PayrollView()
                    .tabItem { Label("Payroll", systemImage: "person.text.rectangle") }
            }
        }
        // First launch: connect to Bigcapital before anything else.
        .sheet(isPresented: Binding(get: { server.isEmpty }, set: { _ in })) {
            SettingsView(firstRun: true).interactiveDismissDisabled()
        }
    }
}
