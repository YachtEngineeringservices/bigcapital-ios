import SwiftUI

struct NeedsView: View {
    @State private var list: NeedsList?
    @State private var error: String?
    @State private var selected: NeedItem?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorBanner(message: error) }
                if let toast { SuccessBanner(message: toast) }
                if let list {
                    if list.preview {
                        Text("Preview until \(list.cutover): last month's transactions, read-only.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if list.items.isEmpty {
                        ContentUnavailableView("Nothing needs you", systemImage: "checkmark.seal")
                    }
                    ForEach(list.items) { item in
                        Button { selected = item } label: { NeedRow(item: item) }
                            .tint(.primary)
                    }
                } else if error == nil {
                    ProgressView()
                }
            }
            .navigationTitle("Needs you")
            .sheet(item: $selected) { item in
                BookSheet(item: item) { message in
                    toast = message
                    Task { await load() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            list = try await API.request("GET", "/needs", as: NeedsList.self)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NeedRow: View {
    let item: NeedItem
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description).lineLimit(2)
                Text("\(item.accountName) · \(item.date)").font(.caption).foregroundStyle(.secondary)
                if let rule = item.suggestion?.rule {
                    Text(rule.replacingOccurrences(of: "yb: ", with: "Suggested: "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            Spacer()
            Text(item.amount.money)
                .monospacedDigit()
                .foregroundStyle(item.amount > 0 ? .green : .primary)
        }
        .opacity(item.readOnly ? 0.6 : 1)
    }
}

/// How to book one bank-feed transaction.
struct BookSheet: View {
    let item: NeedItem
    let done: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var withdrawal: WithdrawalChoices?
    @State private var deposit: DepositChoices?
    @State private var mode = ""
    @State private var expenseId: Int?
    @State private var distributionId: Int?
    @State private var incomeId: Int?
    @State private var invoiceId: Int?
    @State private var memo = ""
    @State private var busy = false
    @State private var error: String?

    private var isDeposit: Bool { item.amount > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.description).font(.headline)
                        Text("\(item.accountName) · \(item.date)").font(.caption).foregroundStyle(.secondary)
                        Text(item.amount.money).font(.title2).bold().monospacedDigit()
                    }
                    if let rule = item.suggestion?.rule {
                        Label("Rule suggests: \(rule.replacingOccurrences(of: "yb: ", with: ""))", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                }
                if item.readOnly {
                    Section { Text("Before the go-live this is read-only: QuickBooks has it.").font(.footnote) }
                }
                Section("Book as") {
                    Picker("Type", selection: $mode) {
                        if isDeposit {
                            Text("Invoice payment").tag("invoice")
                            Text("Other income").tag("income")
                        } else {
                            Text("Expense").tag("expense")
                            Text("Travel (reimbursable)").tag("travel")
                            Text("Distribution").tag("distribution")
                        }
                        Text("Exclude").tag("exclude")
                    }
                    switch mode {
                    case "expense":
                        Picker("Account", selection: $expenseId) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(withdrawal?.expense ?? []) { a in Text(a.name).tag(Int?.some(a.id)) }
                        }
                    case "distribution":
                        Picker("Account", selection: $distributionId) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(withdrawal?.distribution ?? []) { a in Text(a.name).tag(Int?.some(a.id)) }
                        }
                    case "income":
                        Picker("Account", selection: $incomeId) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(deposit?.income ?? []) { a in Text(a.name).tag(Int?.some(a.id)) }
                        }
                    case "invoice":
                        Picker("Invoice", selection: $invoiceId) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(deposit?.invoices ?? []) { i in
                                Text("#\(i.number) \(i.customer ?? "") \(i.due.money)").tag(Int?.some(i.id))
                            }
                        }
                    case "travel":
                        Text("Goes to Reimbursable – unassigned; assign it to a client when invoicing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                    TextField(mode == "exclude" ? "Why? (personal, duplicate…)" : "Note (optional)", text: $memo)
                }
                if let error { Section { ErrorBanner(message: error) } }
            }
            .navigationTitle("Book it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(busy || item.readOnly || !valid)
                }
            }
            .task { await loadChoices() }
        }
    }

    private var chosenAccount: Int? {
        switch mode {
        case "expense": return expenseId
        case "distribution": return distributionId
        case "income": return incomeId
        default: return nil
        }
    }

    private var valid: Bool {
        switch mode {
        case "expense", "distribution", "income": return chosenAccount != nil
        case "invoice": return invoiceId != nil
        case "exclude": return memo.trimmingCharacters(in: .whitespaces).count >= 3
        case "travel": return true
        default: return false
        }
    }

    private func loadChoices() async {
        do {
            if isDeposit {
                let d = try await API.request("GET", "/choices?kind=deposit", as: DepositChoices.self)
                deposit = d
                mode = "invoice"
                if item.invoices.count == 1 { invoiceId = item.invoices[0].id }
                if item.suggestion?.type == "other_income" { mode = "income"; incomeId = item.suggestion?.accountId }
            } else {
                let w = try await API.request("GET", "/choices?kind=withdrawal", as: WithdrawalChoices.self)
                withdrawal = w
                if w.distribution.count == 1 { distributionId = w.distribution[0].id }
                switch item.suggestion?.type {
                case "owner_drawing": mode = "distribution"; distributionId = item.suggestion?.accountId ?? distributionId
                default: mode = "expense"; expenseId = item.suggestion?.accountId
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private struct BookPayload: Encodable {
        let kind: String
        let accountId: Int?
        let invoiceId: Int?
        let memo: String
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let reply = try await API.request("POST", "/needs/\(item.id)",
                                              body: BookPayload(kind: mode, accountId: chosenAccount, invoiceId: invoiceId, memo: memo),
                                              as: Done.self)
            done(reply.text)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
