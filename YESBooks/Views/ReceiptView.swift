import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Photo (or PDF) of a receipt -> pick the charge -> attached in the books.
struct ReceiptView: View {
    @State private var image: UIImage?
    @State private var pdf: Data?
    @State private var pdfName = ""
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?

    @State private var amount = ""
    @State private var candidates: [Candidate] = []
    @State private var searched = false
    @State private var chosen: Candidate?
    @State private var choices: WithdrawalChoices?
    @State private var accountId: Int?

    @State private var isMeal = false
    @State private var who = ""
    @State private var purpose = ""
    @State private var memo = ""

    @State private var busy = false
    @State private var error: String?
    @State private var done: String?

    private var hasFile: Bool { image != nil || pdf != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let done { Section { SuccessBanner(message: done) } }

                Section("1 · Receipt") {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    } else if pdf != nil {
                        Label(pdfName.isEmpty ? "PDF receipt" : pdfName, systemImage: "doc.richtext")
                    }
                    Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose photo", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("Choose PDF", systemImage: "doc") }
                }

                Section("2 · Which charge?") {
                    HStack {
                        TextField("Amount (optional)", text: $amount).keyboardType(.decimalPad)
                        Button("Find") { Task { await search() } }.disabled(busy)
                    }
                    if searched && candidates.isEmpty {
                        Text("No charges since the go-live yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { c in
                        Button { choose(c) } label: { CandidateRow(c: c, selected: chosen == c) }.tint(.primary)
                    }
                }

                if let c = chosen {
                    Section("3 · Details") {
                        if c.needsAccount == true {
                            Picker("For", selection: $accountId) {
                                Text("Choose…").tag(Int?.none)
                                if let t = choices?.travel { Text("Travel (reimbursable)").tag(Int?.some(t.id)) }
                                ForEach(choices?.expense ?? []) { a in Text(a.name).tag(Int?.some(a.id)) }
                            }
                        }
                        Toggle("Meal", isOn: $isMeal)
                        if isMeal {
                            TextField("Who (names, company)", text: $who)
                            TextField("Business purpose", text: $purpose)
                        }
                        TextField("Note (optional)", text: $memo)
                    }
                    Section {
                        Button(busy ? "Attaching…" : "Attach receipt") { Task { await attach(c) } }
                            .disabled(busy || !hasFile || (c.needsAccount == true && accountId == nil) || (isMeal && (who.isEmpty || purpose.isEmpty)))
                    } footer: {
                        Text("Meals need who and the business purpose (IRS substantiation).")
                    }
                }

                if let error { Section { ErrorBanner(message: error) } }
            }
            .navigationTitle("Receipt")
            .sheet(isPresented: $showCamera) { CameraPicker(image: $image).ignoresSafeArea() }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: url) { pdf = d; pdfName = url.lastPathComponent; image = nil }
                }
            }
            .onChange(of: photoItem) {
                Task {
                    if let data = try? await photoItem?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        image = img
                        pdf = nil
                    }
                }
            }
            .onChange(of: image) { if image != nil { pdf = nil; done = nil } }
            .task { if !searched { await search() } }
        }
    }

    private func choose(_ c: Candidate) {
        chosen = c
        accountId = nil
        if c.needsAccount == true && choices == nil {
            Task {
                do { choices = try await API.request("GET", "/choices?kind=withdrawal", as: WithdrawalChoices.self) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func search() async {
        busy = true
        defer { busy = false }
        let q = amount.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        do {
            candidates = try await API.request("GET", "/receipts/candidates" + (q.isEmpty ? "" : "?amount=\(q)"), as: [Candidate].self)
            searched = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private struct Meal: Encodable { let who: String; let purpose: String }
    private struct ReceiptPayload: Encodable {
        let target: Target
        let image: String
        let mime: String
        let accountId: Int?
        let meal: Meal?
        let memo: String
    }

    private func attach(_ c: Candidate) async {
        busy = true
        defer { busy = false }
        let file: Data?, mime: String
        if let pdf { file = pdf; mime = "application/pdf" } else { file = image?.jpegForUpload(); mime = "image/jpeg" }
        guard let file else { error = "Take or choose the receipt first."; return }
        do {
            let reply = try await API.request("POST", "/receipts", body: ReceiptPayload(
                target: c.target, image: file.base64EncodedString(), mime: mime, accountId: accountId,
                meal: isMeal ? Meal(who: who, purpose: purpose) : nil, memo: memo), as: Done.self)
            done = reply.text
            error = nil
            image = nil; pdf = nil; photoItem = nil; chosen = nil
            isMeal = false; who = ""; purpose = ""; memo = ""; amount = ""
            await search()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CandidateRow: View {
    let c: Candidate
    let selected: Bool
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.description ?? "Charge").lineLimit(1)
                Text("\(c.account) · \(c.date) · \(c.status)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text((-c.amount).money).monospacedDigit()
        }
    }
}
