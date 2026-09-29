import Foundation

// What the screens show. Built by Books (Bigcapital) and Payroll (openpayroll).

struct Summary {
    let today: String
    let writeFrom: String?
    let balances: [Balance]
    let receivables: [Receivable]
    let owed: Double
    let needs: Int
}
struct Balance: Identifiable {
    let id: Int
    let name: String
    let books: Double?
    let bank: Double?
    let stale: Bool
    let hasFeed: Bool
}
struct Receivable: Identifiable {
    var id: String { number }
    let number: String
    let customer: String?
    let due: Double
    let dueDate: String
    let overdueDays: Int
}

struct NeedsList {
    let writeFrom: String?
    let preview: Bool
    let items: [NeedItem]
}
struct NeedItem: Identifiable, Hashable {
    let id: Int
    let account: Int
    let accountName: String
    let date: String
    let amount: Double
    let description: String
    let readOnly: Bool
    let suggestion: Suggestion?
    let invoices: [InvoiceRef]
}
struct Suggestion: Hashable {
    let accountId: Int?
    let type: String?
    let rule: String?
}
struct InvoiceRef: Identifiable, Hashable {
    let id: Int
    let number: String
    let customer: String?
    let due: Double
    let dueDate: String?
}
struct AccountRef: Identifiable, Hashable {
    let id: Int
    let name: String
}
struct WithdrawalChoices {
    let expense: [AccountRef]
    let reimbursable: AccountRef?
    let distribution: [AccountRef]
}
struct DepositChoices {
    let invoices: [InvoiceRef]
    let income: [AccountRef]
}

struct Target: Hashable {
    let kind: String      // row | categorized | expense | journal
    let id: Int
}
struct Candidate: Identifiable, Hashable {
    let target: Target
    let date: String
    let amount: Double
    let description: String?
    let account: String
    let status: String
    let needsAccount: Bool
    var id: String { "\(target.kind)-\(target.id)" }
}
