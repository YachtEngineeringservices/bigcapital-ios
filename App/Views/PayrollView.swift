import SwiftUI
import PDFKit

struct PayrollView: View {
    @State private var info: PayrollInfo?
    @State private var prepared: Prepared?
    @State private var error: String?
    @State private var toast: String?
    @State private var busy = false
    @State private var confirmApprove = false
    @State private var stub: StubRef?

    @State private var scheduling: Deposit?
    @State private var schedAmount = ""
    @State private var schedConfirmation = ""

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorBanner(message: error) }
                if let toast { SuccessBanner(message: toast) }
                if let info {
                    if let until = info.previewUntil {
                        Text("Preview until \(until): pay runs here are dry runs and can't be approved yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Next pay run") {
                        if let next = info.next {
                            LabeledContent("Pay date", value: next)
                            Button(busy ? "Working…" : "Prepare \(next)") { Task { await prepare(next) } }.disabled(busy)
                        }
                        if let p = prepared {
                            LabeledContent("Gross", value: p.totals.gross.money)
                            LabeledContent("Employee taxes", value: p.totals.employeeTaxes.money)
                            LabeledContent("Employer taxes", value: p.totals.employerTaxes.money)
                            LabeledContent("Net pay", value: p.totals.net.money).bold()
                            ForEach(p.paychecks) { pc in
                                if p.preview {
                                    LabeledContent(pc.name, value: "net \(pc.net.money)")
                                } else {
                                    Button { stub = StubRef(payDate: p.payDate, employeeId: pc.employeeId) } label: {
                                        LabeledContent(pc.name, value: "net \(pc.net.money) · stub")
                                    }
                                }
                            }
                            if p.preview {
                                Text("Dry run: nothing saved.").font(.footnote).foregroundStyle(.secondary)
                            } else if p.status == "draft" {
                                Button("Approve") { confirmApprove = true }
                                    .bold()
                                    .disabled(busy)
                            }
                        }
                    }
                    Section("Tax deposits") {
                        if info.deposits.isEmpty { Text("None due").foregroundStyle(.secondary) }
                        ForEach(info.deposits) { d in
                            DepositRow(d: d) { scheduling = d; schedAmount = d.amount; schedConfirmation = "" }
                        }
                    }
                    Section("Recent pay runs") {
                        if info.runs.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                        ForEach(info.runs) { r in
                            LabeledContent(r.payDate, value: "\(r.status)\(r.posted ? " · posted" : "") · net \(r.totals?.net.money ?? "–")")
                        }
                    }
                } else if error == nil {
                    ProgressView()
                }
            }
            .navigationTitle("Payroll")
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog("Approve the \(prepared?.payDate ?? "") pay run?", isPresented: $confirmApprove, titleVisibility: .visible) {
                Button("Approve") { Task { await approve() } }
            } message: {
                Text("This locks the pay run and stores the pay stubs. If the payroll server posts to Bigcapital, it does so now.")
            }
            .alert("Mark scheduled", isPresented: Binding(get: { scheduling != nil }, set: { if !$0 { scheduling = nil } })) {
                TextField("Amount", text: $schedAmount).keyboardType(.decimalPad)
                TextField("Confirmation number", text: $schedConfirmation)
                Button("Save") { if let d = scheduling { Task { await markScheduled(d) } } }
                Button("Cancel", role: .cancel) { scheduling = nil }
            } message: {
                Text("After you've scheduled the \(scheduling?.agency ?? "") payment.")
            }
            .sheet(item: $stub) { s in StubSheet(ref: s) }
        }
    }

    private func load() async {
        do {
            info = try await Payroll.info()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepare(_ date: String) async {
        busy = true
        defer { busy = false }
        do {
            prepared = try await Payroll.prepare(date)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approve() async {
        guard let p = prepared else { return }
        busy = true
        defer { busy = false }
        do {
            try await Payroll.approve(p.payDate)
            toast = "Pay run \(p.payDate) approved."
            prepared = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markScheduled(_ d: Deposit) async {
        do {
            try await Payroll.markScheduled(d.id, amount: schedAmount, confirmation: schedConfirmation)
            toast = "\(d.agency) \(d.kind) \(d.period) marked scheduled."
            scheduling = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct DepositRow: View {
    let d: Deposit
    let onSchedule: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(d.agency) \(d.kind) · \(d.period)")
                Text("Due \(d.dueDate)" + (d.projected == true ? " · projected" : "")).font(.caption).foregroundStyle(.secondary)
                if let s = d.scheduled {
                    Text("Scheduled \(s.amount.money)").font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(d.amount.money).monospacedDigit()
                if d.scheduled == nil { Button("Scheduled…", action: onSchedule).font(.caption).buttonStyle(.bordered) }
            }
        }
    }
}

struct StubRef: Identifiable {
    let payDate: String
    let employeeId: String
    var id: String { payDate + employeeId }
}

private struct StubSheet: View {
    let ref: StubRef
    @State private var data: Data?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data { PDFKitView(data: data) }
                else if let error { ErrorBanner(message: error).padding() }
                else { ProgressView() }
            }
            .navigationTitle("Pay stub \(ref.payDate)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do { data = try await Payroll.stub(ref.payDate, employeeId: ref.employeeId) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(data: data)
        return v
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
