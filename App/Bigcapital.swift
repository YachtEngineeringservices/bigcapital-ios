import Foundation

// Minimal client for the Bigcapital REST API (checked against v0.25.42): `Authorization: Bearer bc_...`,
// camelCase request bodies, snake_case responses.

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BC {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static func url(_ path: String) throws -> URL {
        guard !Config.server.isEmpty else { throw AppError(message: "Set your Bigcapital address in Settings.") }
        guard !Config.apiKey.isEmpty else { throw AppError(message: "Add a Bigcapital API key in Settings.") }
        guard let u = URL(string: Config.server + "/api" + path) else { throw AppError(message: "The Bigcapital address isn't a valid URL.") }
        return u
    }

    private static func run(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AppError(message: "Can't reach Bigcapital (\(error.localizedDescription)). If it's on a private network, is the VPN (e.g. Tailscale) on?") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AppError(message: "Bigcapital refused the API key (401). Check it in Settings.") }
        if status >= 300 { throw AppError(message: "Bigcapital: \(status) \(errorText(data))") }
        return data
    }

    /// Bigcapital error bodies vary: {message}, {errors:[{type}]}, or plain text.
    private static func errorText(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errs = o["errors"] as? [[String: Any]], let t = errs.first?["type"] ?? errs.first?["message"] { return "\(t)" }
            if let m = o["message"] { return "\(m)" }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    static func request(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.timeoutInterval = 90
        req.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await run(req)
    }

    static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await request("GET", path)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AppError(message: "Unexpected reply from Bigcapital for \(path) (\(error.localizedDescription)).") }
    }

    /// Every page of a list endpoint (the rows are under "data" or "transactions").
    static func list<T: Decodable>(_ path: String, as type: T.Type) async throws -> [T] {
        var out: [T] = []
        for page in 1...200 {
            let sep = path.contains("?") ? "&" : "?"
            let p = try await get("\(path)\(sep)page=\(page)&pageSize=200&page_size=200", as: Page<T>.self)
            out += p.rows
            if p.rows.isEmpty { break }
            if let total = p.pagination?.total { if out.count >= total { break } } else if p.rows.count < 200 { break }
        }
        return out
    }

    /// Id of a created record (Bigcapital returns {id} or {data:{id}}).
    static func createdId(_ data: Data) -> Int? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = o["id"] as? Int { return id }
        if let d = o["data"] as? [String: Any], let id = d["id"] as? Int { return id }
        return nil
    }

    /// Upload a file as a Bigcapital attachment; returns its key.
    static func upload(filename: String, mime: String, data file: Data) async throws -> String {
        var req = URLRequest(url: try url("/attachments"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "bcios-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let data = try await run(req)
        struct Reply: Decodable { struct Inner: Decodable { let key: String }; let data: Inner }
        guard let r = try? decoder.decode(Reply.self, from: data) else { throw AppError(message: "Receipt upload: unexpected reply.") }
        return r.data.key
    }
}

// MARK: - Bigcapital response shapes (only the fields used)

struct Page<T: Decodable>: Decodable {
    let data: [T]?
    let transactions: [T]?
    let pagination: Pagination?
    var rows: [T] { data ?? transactions ?? [] }
}
struct Pagination: Decodable { let total: Int? }

/// Bigcapital sends booleans as true/false or 1/0.
struct Flag: Decodable {
    let on: Bool
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { on = b }
        else if let i = try? c.decode(Int.self) { on = i != 0 }
        else { on = false }
    }
}
extension Optional where Wrapped == Flag { var on: Bool { self?.on ?? false } }

struct BCAccount: Decodable {
    let id: Int
    let name: String
    let accountType: String
    let active: Flag?
    let amount: Double?
    let bankBalance: Double?
    let lastFeedsUpdatedAt: String?
    let isFeedsActive: Flag?
    let children: [BCAccount]?
}

struct BCFeedRow: Decodable {
    let id: Int
    let date: String
    let amount: Double
    let description: String?
    let accountId: Int?
    let isPending: Flag?
    let pending: Flag?
    let isRecognized: Flag?
    let recognizedTransactionId: Int?
    let excludedAt: String?
    let isExcluded: Flag?
    let categorized: Flag?
    var day: String { String(date.prefix(10)) }
    var isPendingRow: Bool { isPending.on || pending.on }
    var isExcludedRow: Bool { excludedAt != nil || isExcluded.on }
}

struct BCAutofill: Decodable {
    let creditAccountId: Int?
    let transactionType: String?
    let recognizedByRuleName: String?
}

struct BCInvoice: Decodable {
    struct Customer: Decodable { let displayName: String? }
    let id: Int
    let invoiceNo: String?
    let dueAmount: Double
    let isDelivered: Flag?
    let isFullyPaid: Flag?
    let dueDate: String?
    let overdueDays: Int?
    let customer: Customer?
}

struct BCRegisterEntry: Decodable {
    let date: String
    let withdrawal: Double?
    let deposit: Double?
    let referenceType: String?
    let referenceId: Int?
    let uncategorizedTransactionId: Int?
    let transactionNumber: String?
    let referenceNumber: String?
    let formattedTransactionType: String?
}

struct BCCashflowTx: Decodable {
    let creditAccountId: Int?
    let transactionType: String?
}
