import SwiftUI

struct SettingsView: View {
    var firstRun: Bool
    @AppStorage("server") private var server = ""
    @AppStorage("token") private var token = ""
    @Environment(\.dismiss) private var dismiss
    @State private var draftServer = ""
    @State private var draftToken = ""
    @State private var status: String?
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://books.<tailnet>.ts.net:8446", text: $draftServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Books server")
                } footer: {
                    Text("The yes-books phone API. It is only reachable over Tailscale, so keep the Tailscale app connected.")
                }
                Section {
                    SecureField("Optional", text: $draftToken)
                } header: {
                    Text("App token")
                } footer: {
                    Text("Only if APP_TOKEN is set on the server.")
                }
                Section {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(testing || draftServer.isEmpty)
                    if let status { SuccessBanner(message: status) }
                    if let error { ErrorBanner(message: error) }
                }
            }
            .navigationTitle(firstRun ? "Welcome" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !firstRun {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); if !firstRun { dismiss() } }
                        .disabled(draftServer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { draftServer = server; draftToken = token }
        }
    }

    private func save() {
        server = draftServer.trimmingCharacters(in: .whitespacesAndNewlines)
        token = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let oldServer = server, oldToken = token
        save()
        do {
            _ = try await API.request("GET", "/health", as: Health.self)
            status = "Connected."
            error = nil
        } catch {
            self.error = error.localizedDescription
            status = nil
            if firstRun { server = oldServer; token = oldToken }   // keep the welcome sheet up until it works or is saved
        }
    }
}
