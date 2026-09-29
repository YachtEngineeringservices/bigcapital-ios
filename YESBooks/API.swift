import Foundation

// Talks only to the yes-books phone API (tailnet-only; the Tailscale app must be on). The server address and the
// optional app token are entered once in Settings; nothing about the books is stored on the phone.

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Config {
    static var server: String {
        (UserDefaults.standard.string(forKey: "server") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var token: String { UserDefaults.standard.string(forKey: "token") ?? "" }
}

private struct ErrorBody: Decodable { let error: String }
private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

enum API {
    private static func makeRequest(_ method: String, _ path: String, body: (any Encodable)?) throws -> URLRequest {
        guard !Config.server.isEmpty, let url = URL(string: Config.server + "/api" + path) else {
            throw APIError(message: "Set the server address in Settings.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            req.setValue("1", forHTTPHeaderField: "X-YB")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !Config.token.isEmpty { req.setValue("Bearer \(Config.token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONEncoder().encode(AnyEncodable(value: body)) }
        return req
    }

    static func data(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> Data {
        let req = try makeRequest(method, path, body: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw APIError(message: "Can't reach the books server. Is Tailscale on? (\(error.localizedDescription))") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 300 {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Server error \(status)"
            throw APIError(message: msg)
        }
        return data
    }

    static func request<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, as type: T.Type) async throws -> T {
        let d = try await data(method, path, body: body)
        do { return try JSONDecoder().decode(T.self, from: d) }
        catch { throw APIError(message: "Unexpected reply from the server (\(error.localizedDescription)).") }
    }
}

// MARK: - Models (mirror mobile/lib/core.js in the yes-books repo)

struct Health: Decodable { let ok: Bool }
struct Done: Decodable { let text: String }

struct Summary: Decodable {
    let today: String
    let cutover: String
    let booksLive: Bool
    let balances: [Balance]
    let receivables: [Receivable]
    let owed: Double
    let needs: Int
    let payroll: PayGlance?
}
struct Balance: Decodable, Identifiable {
    let id: Int
    let name: String
    let books: Double?
    let bank: Double?
    let updated: String?
    let stale: Bool
    let consentRenewBy: String?
}
struct Receivable: Decodable, Identifiable {
    var id: String { number }
    let number: String
    let customer: String?
    let due: Double
    let dueDate: String
    let overdueDays: Int
}
struct PayGlance: Decodable {
    let next: String?
    let preview: Bool
    let deposits: [Deposit]
}
struct Deposit: Decodable, Identifiable {
    let id: String
    let agency: String
    let kind: String
    let period: String
    let amount: String
    let dueDate: String
    let scheduleBy: String?
    let projected: Bool?
    let note: String?
    let scheduled: ScheduledMark?
}
struct ScheduledMark: Decodable {
    let amount: String
    let confirmation: String?
    let at: String?
}

struct NeedsList: Decodable {
    let cutover: String
    let preview: Bool
    let items: [NeedItem]
}
struct NeedItem: Decodable, Identifiable {
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
struct Suggestion: Decodable {
    let accountId: Int?
    let type: String?
    let rule: String?
}
struct InvoiceRef: Decodable, Identifiable {
    let id: Int
    let number: String
    let customer: String?
    let due: Double
    let dueDate: String?
}
struct AccountRef: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
}
struct WithdrawalChoices: Decodable {
    let expense: [AccountRef]
    let travel: AccountRef
    let distribution: [AccountRef]
}
struct DepositChoices: Decodable {
    let invoices: [InvoiceRef]
    let income: [AccountRef]
}

struct Target: Codable, Hashable {
    let kind: String
    let id: Int
}
struct Candidate: Decodable, Identifiable, Hashable {
    let target: Target
    let date: String
    let amount: Double
    let description: String?
    let account: String
    let status: String
    let needsAccount: Bool?
    let pending: Bool?
    var id: String { "\(target.kind)-\(target.id)" }
}

struct PayrollInfo: Decodable {
    let payrollFrom: String
    let preview: Bool
    let next: String?
    let runs: [RunRow]
    let deposits: [Deposit]
}
struct Totals: Decodable {
    let gross: String
    let employeeTaxes: String
    let employerTaxes: String
    let net: String
}
struct RunRow: Decodable, Identifiable {
    var id: String { payDate }
    let payDate: String
    let status: String
    let totals: Totals?
    let posted: Bool?
}
struct Prepared: Decodable {
    let preview: Bool
    let payDate: String
    let status: String
    let totals: Totals
    let paychecks: [PaycheckRow]
}
struct PaycheckRow: Decodable, Identifiable {
    var id: String { employeeId }
    let employeeId: String
    let name: String
    let gross: String
    let net: String
}
struct Approved: Decodable { let approved: String? }
struct ScheduledReply: Decodable { let scheduled: String? }
