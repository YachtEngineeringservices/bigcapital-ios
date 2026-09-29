import Foundation

// The bookkeeping the app does, directly against the Bigcapital API.
//
// Bigcapital (v0.25.42) behaviours this is built around:
// - A bank-feed row can only be categorized to an expense, income, equity or bank/card account. An asset (e.g. a
//   reimbursable-expenses account) needs a manual journal, and the feed row is then excluded as handled by it.
// - Receipts attach to Expenses and Manual Journals, not to a categorized bank transaction. So an expense is booked
//   as an Expense matched to the feed row, and a charge already categorized is converted when a receipt arrives.
// - Matching a feed row to an Expense works; matching to a Manual Journal never does (its matched amount is 0).
// - Files are attached by key: POST /attachments/<key>/link {modelRef, modelId}.

enum Books {
    private static let expenseTypes: Set<String> = ["expense", "other-expense"]
    private static let incomeTypes: Set<String> = ["income", "other-income"]
    private static let cashTypes: Set<String> = ["bank", "credit-card"]

    // MARK: lookups

    static func accounts() async throws -> [BCAccount] {
        // v0.25.42 returns {"accounts": [...], "filter_meta": {...}}; accept a bare array or {"data": [...]} too.
        struct Wrapped: Decodable { let accounts: [BCAccount]?; let data: [BCAccount]? }
        let raw = try await BC.request("GET", "/accounts")
        let top: [BCAccount]
        if let list = try? BC.decoder.decode([BCAccount].self, from: raw) {
            top = list
        } else {
            do {
                let w = try BC.decoder.decode(Wrapped.self, from: raw)
                top = w.accounts ?? w.data ?? []
            } catch {
                throw AppError(message: "Unexpected reply from Bigcapital for /accounts (\(error.localizedDescription)).")
            }
        }
        var flat: [BCAccount] = []
        func walk(_ xs: [BCAccount]) { for x in xs { flat.append(x); walk(x.children ?? []) } }
        walk(top)
        return flat
    }

    /// Bank and card accounts; the ones with a live bank feed are what "Needs you" and receipts work on.
    static func cashAccounts() async throws -> [BCAccount] {
        try await accounts().filter { cashTypes.contains($0.accountType) && $0.active.on }
    }
    static func feedAccounts() async throws -> [BCAccount] {
        try await cashAccounts().filter { $0.isFeedsActive.on }
    }

    static func openInvoices() async throws -> [BCInvoice] {
        try await BC.list("/sale-invoices", as: BCInvoice.self).filter { $0.isDelivered.on && !$0.isFullyPaid.on && $0.dueAmount > 0 }
    }

    private static func fetchRow(_ id: Int) async throws -> BCFeedRow {
        try await BC.get("/banking/uncategorized/\(id)", as: BCFeedRow.self)
    }

    private static func assertWritable(_ date: String) throws {
        if let from = Config.writeFrom, date < from {
            throw AppError(message: "Dated \(date): before \(from) is read-only (Settings → Don't write before).")
        }
    }

    private static func money(_ x: Double) -> String { x.money }

    // MARK: Needs you

    static func needs() async throws -> NeedsList {
        let today = todayISO()
        let preview = Config.writeFrom.map { today < $0 } ?? false
        let feeds = try await feedAccounts()
        var items: [NeedItem] = []
        var invoices: [BCInvoice]? = nil
        for acct in feeds {
            var rows = try await BC.list("/banking/uncategorized/accounts/\(acct.id)", as: BCFeedRow.self).filter { !$0.isPendingRow }
            if preview { rows += try await BC.list("/banking/exclude?accountId=\(acct.id)", as: BCFeedRow.self) }
            var seen = Set<Int>()
            for r in rows {
                guard seen.insert(r.id).inserted else { continue }
                let before = Config.writeFrom.map { r.day < $0 } ?? false
                if before && !preview { continue }
                if before && r.day < isoDaysAgo(31) { continue }
                var suggestion: Suggestion? = nil
                if r.isRecognized.on || r.recognizedTransactionId != nil,
                   let f = try? await BC.get("/banking/uncategorized/autofill?uncategorizedTransactionIds[]=\(r.id)", as: BCAutofill.self) {
                    suggestion = Suggestion(accountId: f.creditAccountId, type: f.transactionType, rule: f.recognizedByRuleName)
                }
                var matches: [InvoiceRef] = []
                if r.amount > 0 {
                    if invoices == nil { invoices = try await openInvoices() }
                    matches = (invoices ?? []).filter { abs($0.dueAmount - r.amount) < 0.005 }.map(ref)
                }
                items.append(NeedItem(id: r.id, account: acct.id, accountName: acct.name, date: r.day, amount: r.amount,
                                      description: r.description ?? "", readOnly: before, suggestion: suggestion, invoices: matches))
            }
        }
        items.sort { $0.date > $1.date }
        return NeedsList(writeFrom: Config.writeFrom, preview: preview, items: items)
    }

    private static func ref(_ i: BCInvoice) -> InvoiceRef {
        InvoiceRef(id: i.id, number: i.invoiceNo ?? "\(i.id)", customer: i.customer?.displayName, due: i.dueAmount, dueDate: i.dueDate.map { String($0.prefix(10)) })
    }

    static func withdrawalChoices() async throws -> WithdrawalChoices {
        let accts = try await accounts().filter { $0.active.on }
        let equity = accts.filter { $0.accountType == "equity" }
        let draws = equity.filter { $0.name.range(of: "draw|distribution", options: [.regularExpression, .caseInsensitive]) != nil }
        let reimb = Config.reimbursableAccountId.flatMap { id in accts.first { $0.id == id } }
        return WithdrawalChoices(
            expense: accts.filter { expenseTypes.contains($0.accountType) }.map { AccountRef(id: $0.id, name: $0.name) }.sorted { $0.name < $1.name },
            reimbursable: reimb.map { AccountRef(id: $0.id, name: $0.name) },
            distribution: (draws.isEmpty ? equity : draws).map { AccountRef(id: $0.id, name: $0.name) })
    }

    static func depositChoices() async throws -> DepositChoices {
        let accts = try await accounts().filter { $0.active.on }
        return DepositChoices(invoices: try await openInvoices().map(ref),
                              income: accts.filter { incomeTypes.contains($0.accountType) }.map { AccountRef(id: $0.id, name: $0.name) })
    }

    // MARK: booking

    /// An Expense (with any receipts) on the bank/card account, matched to the feed row. Rolled back if the match fails.
    @discardableResult
    static func expenseAndMatch(_ r: BCFeedRow, accountId: Int, memo: String, keys: [String] = []) async throws -> String {
        guard r.amount < 0 else { throw AppError(message: "Only money going out can be an expense.") }
        guard let acct = try await accounts().first(where: { $0.id == accountId }), expenseTypes.contains(acct.accountType) else {
            throw AppError(message: "Pick an expense account.")
        }
        guard let bank = r.accountId else { throw AppError(message: "The transaction has no bank account.") }
        let amount = (-r.amount * 100).rounded() / 100
        let description = String((memo.isEmpty ? (r.description ?? "") : memo).prefix(255))
        let created = try await BC.request("POST", "/expenses", json: [
            "paymentDate": r.day, "paymentAccountId": bank, "referenceNo": "feed #\(r.id)", "description": description,
            "currencyCode": "USD", "exchangeRate": 1, "publish": true,
            "categories": [["index": 1, "expenseAccountId": accountId, "amount": amount, "description": description] as [String: Any]],
            "attachments": keys.map { ["key": $0] },
        ])
        guard let expenseId = BC.createdId(created) else { throw AppError(message: "Bigcapital didn't return the new expense.") }
        do {
            _ = try await BC.request("POST", "/banking/matching/match", json: [
                "uncategorizedTransactions": [r.id],
                "matchedTransactions": [["referenceType": "Expense", "referenceId": expenseId] as [String: Any]],
            ])
        } catch {
            _ = try? await BC.request("DELETE", "/expenses/\(expenseId)")      // nothing booked twice
            throw error
        }
        return "\(money(amount)) booked to \(acct.name)"
    }

    /// Reimbursable (asset) account: manual journal BF-<feed id>, then the feed row is excluded as handled.
    @discardableResult
    static func reimbursableJournal(_ r: BCFeedRow, keys: [String] = []) async throws -> String {
        guard let to = Config.reimbursableAccountId, let bank = r.accountId else { throw AppError(message: "Set the reimbursable account in Settings.") }
        let amt = (abs(r.amount) * 100).rounded() / 100
        let note = r.description ?? ""
        let entries: [[String: Any]] = r.amount < 0
            ? [["index": 1, "accountId": to, "debit": amt, "credit": 0, "note": note], ["index": 2, "accountId": bank, "debit": 0, "credit": amt, "note": note]]
            : [["index": 1, "accountId": bank, "debit": amt, "credit": 0, "note": note], ["index": 2, "accountId": to, "debit": 0, "credit": amt, "note": note]]
        _ = try await BC.request("POST", "/manual-journals", json: [
            "date": r.day, "journalNumber": "BF-\(r.id)", "reference": "Bank feed #\(r.id)", "currencyCode": "USD", "publish": true,
            "description": String("Reimbursable: \(note)".prefix(255)), "entries": entries, "attachments": keys.map { ["key": $0] },
        ])
        _ = try await BC.request("PUT", "/banking/exclude/\(r.id)")
        return "\(money(amt)) to reimbursable (journal BF-\(r.id))"
    }

    enum Action {
        case expense(accountId: Int)
        case reimbursable
        case distribution(accountId: Int)
        case income(accountId: Int)
        case invoice(invoiceId: Int)
        case exclude
    }

    static func book(_ id: Int, _ action: Action, memo: String) async throws -> String {
        let r = try await fetchRow(id)
        try assertWritable(r.day)
        if r.isExcludedRow { throw AppError(message: "Already handled (excluded).") }
        if r.categorized.on { throw AppError(message: "Already categorized.") }
        switch action {
        case .expense(let accountId):
            return try await expenseAndMatch(r, accountId: accountId, memo: memo)
        case .reimbursable:
            return try await reimbursableJournal(r)
        case .distribution(let accountId), .income(let accountId):
            let deposit = r.amount > 0
            if case .distribution = action, deposit { throw AppError(message: "A distribution is money going out.") }
            if case .income = action, !deposit { throw AppError(message: "Income is money coming in.") }
            _ = try await BC.request("POST", "/banking/categorize", json: [
                "date": r.day, "creditAccountId": accountId, "transactionType": deposit ? "other_income" : "owner_drawing",
                "uncategorizedTransactionIds": [r.id], "description": String((memo.isEmpty ? (r.description ?? "") : memo).prefix(255)),
            ])
            return "Categorized."
        case .invoice(let invoiceId):
            guard let inv = try await openInvoices().first(where: { $0.id == invoiceId }) else { throw AppError(message: "That invoice isn't open.") }
            guard abs(inv.dueAmount - r.amount) < 0.005 else {
                throw AppError(message: "Invoice \(inv.invoiceNo ?? "") is due \(money(inv.dueAmount)); the deposit is \(money(r.amount)).")
            }
            _ = try await BC.request("POST", "/banking/matching/match", json: [
                "uncategorizedTransactions": [r.id], "matchedTransactions": [["referenceType": "SaleInvoice", "referenceId": inv.id] as [String: Any]],
            ])
            return "Payment of invoice \(inv.invoiceNo ?? "") recorded."
        case .exclude:
            guard memo.trimmingCharacters(in: .whitespaces).count >= 3 else { throw AppError(message: "Say why (personal charge, duplicate…).") }
            _ = try await BC.request("PUT", "/banking/exclude/\(r.id)")
            return "Excluded."
        }
    }

    // MARK: receipts

    static func receiptCandidates(amount: Double?) async throws -> [Candidate] {
        var from = isoDaysAgo(60)
        if let w = Config.writeFrom, w > from { from = w }
        var out: [Candidate] = []
        for acct in try await feedAccounts() {
            for r in try await BC.list("/banking/uncategorized/accounts/\(acct.id)", as: BCFeedRow.self) where r.amount < 0 && r.day >= from {
                out.append(Candidate(target: Target(kind: "row", id: r.id), date: r.day, amount: r.amount, description: r.description,
                                     account: acct.name, status: "needs a category", needsAccount: true))
            }
            for e in try await BC.list("/banking/transactions?accountId=\(acct.id)", as: BCRegisterEntry.self) {
                guard let w = e.withdrawal, w > 0, String(e.date.prefix(10)) >= from, let refId = e.referenceId else { continue }
                let kind: String
                switch e.referenceType {
                case "Expense": kind = "expense"
                case "Journal", "ManualJournal": kind = "journal"
                case "CashflowTransaction" where e.uncategorizedTransactionId != nil: kind = "categorized"
                default: continue
                }
                out.append(Candidate(target: Target(kind: kind, id: kind == "categorized" ? e.uncategorizedTransactionId! : refId),
                                     date: String(e.date.prefix(10)), amount: -w,
                                     description: e.referenceNumber ?? e.transactionNumber ?? e.formattedTransactionType,
                                     account: acct.name,
                                     status: kind == "categorized" ? "categorized (becomes an expense with the receipt)" : "booked (\(e.formattedTransactionType ?? kind))",
                                     needsAccount: false))
            }
        }
        if let a = amount, a > 0 {
            out.sort { abs(-$0.amount - a) != abs(-$1.amount - a) ? abs(-$0.amount - a) < abs(-$1.amount - a) : $0.date > $1.date }
        } else {
            out.sort { $0.date > $1.date }
        }
        return Array(out.prefix(40))
    }

    private static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .,&()'_$-"))
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
        return String(cleaned.split(separator: " ").joined(separator: " ").prefix(140))
    }

    /// Attach a receipt to a charge, booking it first if needed. `accountId` is required for an uncategorized charge
    /// (an expense account, or the reimbursable account).
    static func attachReceipt(target: Target, file: Data, mime: String, accountId: Int?, mealWho: String, mealPurpose: String, memo: String) async throws -> String {
        let meal = (mealWho.isEmpty && mealPurpose.isEmpty) ? "" : "Meal with \(mealWho): \(mealPurpose)"
        let note = [meal, memo.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: ". ")
        let ext = mime == "application/pdf" ? "pdf" : "jpg"

        var r: BCFeedRow? = nil
        if target.kind == "row" || target.kind == "categorized" {
            let row = try await fetchRow(target.id)
            try assertWritable(row.day)
            r = row
        }
        let label = r.map { "Receipt \($0.day) \(money(-$0.amount)) \($0.description ?? "") \(note)" } ?? "Receipt \(todayISO()) \(note)"
        let key = try await BC.upload(filename: safeName(label) + "." + ext, mime: mime, data: file)

        switch target.kind {
        case "expense", "journal":
            _ = try await BC.request("POST", "/attachments/\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)/link",
                                     json: ["modelRef": target.kind == "expense" ? "Expense" : "ManualJournal", "modelId": target.id])
            return "Receipt attached."
        case "categorized":
            // Categorized bank transactions can't hold files: undo the categorization and book it as an Expense (same
            // account) carrying the receipt. If that fails, put the categorization back.
            guard let row = r, let bank = row.accountId else { throw AppError(message: "Transaction not found.") }
            let register = try await BC.list("/banking/transactions?accountId=\(bank)", as: BCRegisterEntry.self)
            guard let entry = register.first(where: { $0.uncategorizedTransactionId == row.id && $0.referenceType == "CashflowTransaction" }),
                  let txId = entry.referenceId else { throw AppError(message: "Couldn't find how this charge was categorized.") }
            let raw = try await BC.request("GET", "/banking/transactions/\(txId)")
            struct Wrapped: Decodable { let data: BCCashflowTx? }
            let direct = try? BC.decoder.decode(BCCashflowTx.self, from: raw)
            let tx = (direct?.creditAccountId != nil ? direct : (try? BC.decoder.decode(Wrapped.self, from: raw))?.data)
            guard let was = tx?.creditAccountId, (tx?.transactionType ?? "").range(of: "expense", options: .caseInsensitive) != nil else {
                throw AppError(message: "That one isn't an expense (a transfer, distribution or income), so it can't take a receipt.")
            }
            _ = try await BC.request("DELETE", "/banking/categorize/\(row.id)")
            do {
                let text = try await expenseAndMatch(row, accountId: accountId ?? was, memo: note, keys: [key])
                return "Receipt attached; \(text)."
            } catch {
                _ = try? await BC.request("POST", "/banking/categorize", json: [
                    "date": row.day, "creditAccountId": was, "transactionType": "other_expense", "uncategorizedTransactionIds": [row.id],
                    "description": String((row.description ?? "").prefix(255)),
                ])
                throw error
            }
        default:
            guard let row = r else { throw AppError(message: "Transaction not found.") }
            if row.isExcludedRow { throw AppError(message: "Already handled (excluded).") }
            guard let accountId else { throw AppError(message: "Pick what it was for.") }
            if accountId == Config.reimbursableAccountId {
                let text = try await reimbursableJournal(row, keys: [key])
                return "Receipt attached; \(text)."
            }
            let text = try await expenseAndMatch(row, accountId: accountId, memo: note, keys: [key])
            return "Receipt attached; \(text)."
        }
    }

    // MARK: glance

    static func summary() async throws -> Summary {
        let today = todayISO()
        async let cash = cashAccounts()
        async let invs = openInvoices()
        let needCount = (try? await needs().items.filter { !$0.readOnly }.count) ?? 0
        let cashList = try await cash
        let invList = try await invs
        let balances = cashList.map { a -> Balance in
            let updated = a.lastFeedsUpdatedAt.map { String($0.prefix(10)) }
            let stale = a.isFeedsActive.on && (updated.map { $0 < isoDaysAgo(4) } ?? true)
            return Balance(id: a.id, name: a.name, books: a.amount, bank: a.isFeedsActive.on ? a.bankBalance : nil, stale: stale, hasFeed: a.isFeedsActive.on)
        }.filter { $0.hasFeed || ($0.books ?? 0) != 0 }
        let receivables = invList.map {
            Receivable(number: $0.invoiceNo ?? "\($0.id)", customer: $0.customer?.displayName, due: $0.dueAmount,
                       dueDate: String(($0.dueDate ?? "").prefix(10)), overdueDays: $0.overdueDays ?? 0)
        }.sorted { $0.dueDate < $1.dueDate }
        return Summary(today: today, writeFrom: Config.writeFrom, balances: balances, receivables: receivables,
                       owed: receivables.reduce(0) { $0 + $1.due }, needs: needCount)
    }
}
