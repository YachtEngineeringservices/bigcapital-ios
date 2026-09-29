import SwiftUI

struct GlanceView: View {
    @State private var summary: Summary?
    @State private var error: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Section { ErrorBanner(message: error) } }
                if let s = summary {
                    if !s.booksLive {
                        Section {
                            Label("Preview: the books move here on \(s.cutover). Until then QuickBooks is the book of record.", systemImage: "info.circle")
                                .font(.footnote)
                        }
                    }
                    Section("Bank & card") {
                        ForEach(s.balances) { b in BalanceRow(b: b) }
                    }
                    Section("Owed to you · \(s.owed.money)") {
                        if s.receivables.isEmpty { Text("Nothing outstanding").foregroundStyle(.secondary) }
                        ForEach(s.receivables) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.customer ?? "Invoice \(r.number)").lineLimit(1)
                                    Text(r.overdueDays > 0 ? "#\(r.number) · \(r.overdueDays) days overdue" : "#\(r.number) · due \(r.dueDate)")
                                        .font(.caption)
                                        .foregroundStyle(r.overdueDays > 0 ? .red : .secondary)
                                }
                                Spacer()
                                Text(r.due.money).monospacedDigit()
                            }
                        }
                    }
                    Section("Coming up") {
                        LabeledContent("Needs you", value: "\(s.needs)")
                        if let p = s.payroll {
                            if let next = p.next { LabeledContent("Next payday", value: next) }
                            ForEach(p.deposits) { d in
                                LabeledContent("\(d.agency) \(d.kind) · due \(d.dueDate)", value: d.amount.money)
                            }
                        }
                    }
                } else if error == nil {
                    Section { ProgressView() }
                }
            }
            .navigationTitle("YES Books")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView(firstRun: false) }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            summary = try await API.request("GET", "/summary", as: Summary.self)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BalanceRow: View {
    let b: Balance
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(b.name).lineLimit(1)
                Spacer()
                Text((b.bank ?? b.books ?? 0).money).bold().monospacedDigit()
            }
            if let books = b.books, let bank = b.bank, abs(books - bank) >= 0.01 {
                Text("Books \(books.money) · bank \(bank.money)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if b.stale {
                Label("No update from the bank recently", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
