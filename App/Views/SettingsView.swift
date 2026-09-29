import SwiftUI

struct SettingsView: View {
    var firstRun: Bool
    @AppStorage("server") private var server = ""
    @AppStorage("writeFrom") private var writeFrom = ""
    @AppStorage("reimbursableAccountId") private var reimbursableAccountId = 0
    @AppStorage("payrollServer") private var payrollServer = ""
    @AppStorage("payrollFrom") private var payrollFrom = ""
    @Environment(\.dismiss) private var dismiss

    @State private var draftServer = ""
    @State private var draftKey = ""
    @State private var hasKey = false
    @State private var assetAccounts: [AccountRef] = []
    @State private var status: String?
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://books.example.com", text: $draftServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(hasKey ? "API key saved (enter to replace)" : "API key (bc_…)", text: $draftKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(testing ? "Connecting…" : "Connect") { Task { await connect() } }
                        .disabled(testing || draftServer.trimmingCharacters(in: .whitespaces).isEmpty || (!hasKey && draftKey.isEmpty))
                    if let status { SuccessBanner(message: status) }
                    if let error { ErrorBanner(message: error) }
                } header: {
                    Text("Bigcapital")
                } footer: {
                    Text("Your Bigcapital address and an API key (Bigcapital → Preferences → API keys). The key is stored in the iPhone Keychain. If Bigcapital is on a private network, turn on its VPN (e.g. Tailscale).")
                }

                if !firstRun {
                    Section {
                        TextField("YYYY-MM-DD (optional)", text: $writeFrom)
                            .keyboardType(.numbersAndPunctuation)
                    } header: {
                        Text("Don't write anything dated before")
                    } footer: {
                        Text("For a migration: the old system still owns earlier periods, so they show read-only here.")
                    }
                    Section {
                        Picker("Account", selection: $reimbursableAccountId) {
                            Text("None").tag(0)
                            ForEach(assetAccounts) { a in Text(a.name).tag(a.id) }
                        }
                    } header: {
                        Text("Reimbursable expenses")
                    } footer: {
                        Text("An asset account for costs you re-bill to clients (e.g. travel). Bigcapital can't categorize a bank transaction to an asset, so these are booked with a manual journal and the bank line is excluded.")
                    }
                    Section {
                        TextField("https://payroll.example.com (optional)", text: $payrollServer)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Live from YYYY-MM-DD (optional)", text: $payrollFrom)
                            .keyboardType(.numbersAndPunctuation)
                    } header: {
                        Text("Payroll (openpayroll)")
                    } footer: {
                        Text("Shows the Payroll tab. Before the live-from date pay runs are previews only.")
                    }
                }
            }
            .navigationTitle(firstRun ? "Connect to Bigcapital" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !firstRun {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .onAppear {
                draftServer = server
                hasKey = !Config.apiKey.isEmpty
            }
            .task { if !firstRun { await loadAssetAccounts() } }
        }
    }

    /// Save the address and key, then prove they work. On the first run the sheet closes once it succeeds.
    private func connect() async {
        testing = true
        defer { testing = false }
        let oldKey = Config.apiKey
        if !draftKey.isEmpty { Config.setAPIKey(draftKey) }
        let candidate = draftServer.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.pendingServer = candidate                             // test it before saving it
        defer { Config.pendingServer = nil }
        do {
            let accounts = try await Books.accounts()
            status = "Connected: \(accounts.count) accounts."
            error = nil
            draftKey = ""
            hasKey = true
            server = candidate
            await loadAssetAccounts()
        } catch {
            self.error = error.localizedDescription
            status = nil
            if !draftKey.isEmpty { Config.setAPIKey(oldKey) }
        }
    }

    private func loadAssetAccounts() async {
        guard let all = try? await Books.accounts() else { return }
        assetAccounts = all.filter { ["other-current-asset", "current-asset", "non-current-asset"].contains($0.accountType) && $0.active.on }
            .map { AccountRef(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }
}
