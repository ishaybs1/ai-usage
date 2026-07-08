import SwiftUI

/// Settings for the source of recent Cursor usage (local files no longer carry token counts).
///
/// By default the app reads usage via your **Cursor login on this Mac** — the same backend the
/// Cursor CLI's `/usage` uses, authenticated with your stored session token. No setup needed.
/// A **Team Admin API key** (Enterprise) is offered as an advanced alternative, and a manual
/// month figure as a last-resort fallback.
struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel

    @State private var email: String = CursorConfig.load().email
    @State private var apiKey: String = ""
    @State private var hasStoredKey: Bool = !(CursorConfig.load().apiKey.isEmpty)
    @State private var testResult: String?
    @State private var testOK = false
    @State private var busy = false

    // Personal-token "Test" state (separate from the Admin-key test).
    @State private var personalResult: String?
    @State private var personalOK = false
    @State private var personalBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cursor usage source")
                .font(.headline)

            Text("Recent Cursor usage isn't stored on your Mac anymore. By default the app reads it using your **Cursor login on this Mac** (the same data as the CLI's `/usage`) — no setup needed if you're signed into Cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Live source indicator — always shows which source produced the current numbers.
            HStack(spacing: 6) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(sourceColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Active source: \(viewModel.cursorSourceInUse.label)")
                        .font(.caption.weight(.medium))
                    if let status = viewModel.cursorApiStatus {
                        Text(status).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sourceColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            Toggle("Use my Cursor session token automatically", isOn: $viewModel.usePersonalToken)
                .font(.callout)
            Text("Uses your local Cursor login to fetch real per-session tokens and cost. Turn off to fall back to the Admin API key or manual entry below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Test session token") { Task { await testPersonal() } }
                    .disabled(personalBusy || !viewModel.usePersonalToken)
                if let personalResult {
                    Label(personalResult, systemImage: personalOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(personalOK ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Advanced: the original Team Admin API key path, collapsed by default.
            DisclosureGroup("Advanced — Team Admin API key (Enterprise)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Needs a Cursor **Team** with the Admin API and a team Admin API key from cursor.com/dashboard → API Keys. Used only when the session token above is off or unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Form {
                        TextField("Your Cursor email", text: $email, prompt: Text("you@company.com"))
                            .textFieldStyle(.roundedBorder)
                        SecureField(hasStoredKey ? "•••••••• (stored — leave blank to keep)" : "Admin API key",
                                    text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(testOK ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button("Test connection") { Task { await test() } }
                            .disabled(busy || email.isEmpty || (apiKey.isEmpty && !hasStoredKey))
                        Spacer()
                        Button("Save") { Task { await save() } }
                            .disabled(busy || email.isEmpty)
                    }
                }
                .padding(.top, 6)
            }
            .font(.subheadline)

            Divider()

            Text("Manual fallback")
                .font(.subheadline.weight(.semibold))
            Text("Read your Cursor spend for this month from cursor.com → Settings → Usage and enter it here. Used only when no server source is providing data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Cursor spend this month ($)")
                Spacer()
                TextField("0.00", value: $viewModel.manualCursorMonth, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 440, height: 560)
    }

    // MARK: Source indicator styling

    private var sourceIcon: String {
        switch viewModel.cursorSourceInUse {
        case .personalToken: return "person.badge.key.fill"
        case .adminAPI: return "key.fill"
        case .localFiles: return "externaldrive.badge.questionmark"
        }
    }

    private var sourceColor: Color {
        viewModel.cursorRecentUnavailable ? .orange : .green
    }

    // MARK: Actions

    /// Effective Admin config from the current fields, keeping the stored key when the field is blank.
    private func effectiveConfig() -> CursorConfig {
        let key = apiKey.isEmpty ? CursorConfig.load().apiKey : apiKey
        return CursorConfig(apiKey: key, email: email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func testPersonal() async {
        personalBusy = true; defer { personalBusy = false }
        personalResult = "Testing…"; personalOK = false
        do {
            personalResult = try await CursorPersonalAPI().verify()
            personalOK = true
        } catch {
            personalResult = "No Cursor session found — sign into the Cursor app/CLI. (\(error.localizedDescription))"
            personalOK = false
        }
    }

    private func test() async {
        busy = true; defer { busy = false }
        testResult = "Testing…"; testOK = false
        let api = CursorAdminAPI(config: effectiveConfig())
        do {
            testResult = try await api.verify()
            testOK = true
        } catch {
            testResult = error.localizedDescription
            testOK = false
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        let cfg = effectiveConfig()
        CursorConfig.save(apiKey: cfg.apiKey, email: cfg.email)
        hasStoredKey = !cfg.apiKey.isEmpty
        apiKey = ""
        await viewModel.applyCursorConfig(CursorConfig.load())
        testResult = "Saved. Reloading usage…"
        testOK = true
    }
}
