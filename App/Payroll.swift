import Foundation

// Optional: openpayroll (open-source payroll engine) for the Payroll tab. Only used when a payroll server is set in
// Settings. openpayroll has no login of its own (keep it on a private network); POSTs need X-OpenPayroll: 1.

struct PayrollInfo {
    let next: String?
    let runs: [RunRow]
    let deposits: [Deposit]
    let previewUntil: String?
}
struct Totals: Decodable {
    let gross: String
    let employeeTaxes: String
    let employerTaxes: String
    let net: String
}
struct RunRow: Decodable, Identifiable {
    struct Posting: Decodable { struct State: Decodable { let status: String? }; let accrual: State? }
    var id: String { payDate }
    let payDate: String
    let status: String
    let totals: Totals?
    let bigcapital: Posting?
    var posted: Bool { bigcapital?.accrual?.status == "posted" }
}
struct Deposit: Decodable, Identifiable {
    let id: String
    let agency: String
    let kind: String
    let period: String
    let amount: String
    let dueDate: String
    let projected: Bool?
    let note: String?
    var scheduled: ScheduledMark?
}
struct ScheduledMark: Decodable {
    let amount: String
    let confirmation: String?
}
struct PaycheckRow: Identifiable {
    var id: String { employeeId }
    let employeeId: String
    let name: String
    let gross: String
    let net: String
}
struct Prepared {
    let preview: Bool
    let payDate: String
    let status: String
    let totals: Totals
    let paychecks: [PaycheckRow]
}

enum Payroll {
    static var enabled: Bool { !Config.payrollServer.isEmpty }

    private static func call(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: Config.payrollServer + path) else { throw AppError(message: "The payroll server address isn't a valid URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" { req.setValue("1", forHTTPHeaderField: "X-OpenPayroll") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AppError(message: "Can't reach the payroll server (\(error.localizedDescription)).") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 300 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AppError(message: msg ?? "Payroll server error \(status)")
        }
        return data
    }

    static func info() async throws -> PayrollInfo {
        struct Next: Decodable { let payDate: String? }
        struct Deps: Decodable {
            struct State: Decodable { let scheduled: [String: ScheduledMark]? }
            let configured: Bool?
            let deposits: [Deposit]?
            let state: State?
        }
        let dec = JSONDecoder()
        let next = try dec.decode(Next.self, from: try await call("GET", "/api/payruns/next"))
        let runs = try dec.decode([RunRow].self, from: try await call("GET", "/api/payruns"))
        let deps = try dec.decode(Deps.self, from: try await call("GET", "/api/deposits"))
        let today = todayISO()
        let upcoming: [Deposit] = (deps.deposits ?? []).filter { $0.dueDate >= today }.prefix(8).map { d in
            var d = d
            d.scheduled = deps.state?.scheduled?[d.id]
            return d
        }
        let preview = Config.payrollFrom.flatMap { today < $0 ? $0 : nil }
        return PayrollInfo(next: next.payDate, runs: Array(runs.suffix(6).reversed()), deposits: upcoming, previewUntil: preview)
    }

    /// Before the "payroll live from" date this is a dry run: nothing is saved.
    static func prepare(_ payDate: String) async throws -> Prepared {
        struct Result: Decodable { let gross: String; let netPay: String }
        struct Check: Decodable { let employeeId: String; let name: String; let result: Result }
        struct Run: Decodable { let status: String; let totals: Totals; let paychecks: [Check] }
        struct Reply: Decodable { let run: Run }
        let dry = Config.payrollFrom.map { payDate < $0 } ?? false
        let r = try JSONDecoder().decode(Reply.self, from: try await call("POST", "/api/payruns", json: ["payDate": payDate, "dryRun": dry]))
        return Prepared(preview: dry, payDate: payDate, status: dry ? "preview" : r.run.status, totals: r.run.totals,
                        paychecks: r.run.paychecks.map { PaycheckRow(employeeId: $0.employeeId, name: $0.name, gross: $0.result.gross, net: $0.result.netPay) })
    }

    static func approve(_ payDate: String) async throws {
        if let from = Config.payrollFrom, payDate < from { throw AppError(message: "Payroll here starts \(from).") }
        _ = try await call("POST", "/api/payruns/\(payDate)/approve", json: [:])
    }

    static func markScheduled(_ id: String, amount: String, confirmation: String) async throws {
        let amt = amount.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard amt.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil else { throw AppError(message: "Amount like 1502.16") }
        let path = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? id
        _ = try await call("POST", "/api/deposits/\(path)/scheduled", json: ["amount": amt, "confirmation": confirmation])
    }

    static func stub(_ payDate: String, employeeId: String) async throws -> Data {
        let emp = employeeId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? employeeId
        return try await call("GET", "/api/payruns/\(payDate)/stubs/\(emp).pdf")
    }
}
