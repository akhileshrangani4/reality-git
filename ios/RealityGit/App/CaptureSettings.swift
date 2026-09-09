import RealityGitCore
import SwiftUI

struct CaptureSettings: View {
    @ObservedObject var assistant: AssistantCoordinator
    @Binding var previewReference: Bool
    let hasReference: Bool
    let canReset: Bool
    let reset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmsSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if !assistant.signedIn {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "viewfinder").font(.largeTitle).accessibilityHidden(true)
                            Text("Scan with ChatGPT").font(.title2.bold())
                            Text("Sign in once. Scan from your iPhone.").foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }.listRowBackground(Color.clear)
                }
                Section {
                    if assistant.signedIn {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout())
                        layout {
                            Text("ChatGPT")
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    } else if let login = assistant.login {
                        CodexLoginView(assistant: assistant, login: login)
                    } else {
                        Button {
                            Task { await assistant.beginLogin() }
                        } label: {
                            HStack {
                                Text("Sign in with ChatGPT")
                                Spacer()
                                if assistant.isConnecting { ProgressView() }
                            }
                        }.disabled(assistant.isConnecting)
                    }
                } header: { Text("Account") } footer: {
                    Text("Scans use your Codex allowance. Your sign-in is saved securely on this iPhone.")
                }.id(assistant.signedIn)

                if assistant.signedIn {
                    Section {
                        NavigationLink {
                            ScanModelPicker(assistant: assistant, reset: reset)
                        } label: {
                            LabeledContent("Model", value: assistant.modelName)
                        }
                    }
                }
                if let message = assistant.connectionMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        if assistant.signedIn {
                            Button("Try again") { Task { await assistant.refreshAccount() } }
                                .disabled(assistant.isConnecting)
                        }
                    }
                }
                if hasReference || canReset {
                    Section("Scan") {
                        if hasReference { Toggle("Show remembered shape", isOn: $previewReference) }
                        Button("Start over") { reset(); dismiss() }
                    }
                }
                if assistant.signedIn {
                    Section {
                        Button("Sign out", role: .destructive) { confirmsSignOut = true }
                    }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of ChatGPT?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { if await assistant.disconnect() { reset() } }
                }
            } message: { Text("This removes your sign-in from this iPhone.") }
        }
        .tint(.primary)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct ScanModelPicker: View {
    @ObservedObject var assistant: AssistantCoordinator
    let reset: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if assistant.models.isEmpty {
                ContentUnavailableView("No compatible models", systemImage: "camera",
                    description: Text("Refresh your account to find models that can understand camera images."))
            } else {
                Section {
                    ForEach(assistant.models) { model in
                        Button {
                            if assistant.modelID != model.id { assistant.chooseModel(model.id); reset() }
                            dismiss()
                        } label: {
                            HStack {
                                Text(model.name).foregroundStyle(.primary)
                                Spacer()
                                if assistant.modelID == model.id { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }.frame(minHeight: 32).contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(assistant.modelID == model.id ? .isSelected : [])
                    }
                } footer: {
                    Text("Available through your Codex account. Every model uses low effort. Changing models starts a new scan.")
                }
            }
            if let message = assistant.connectionMessage { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await assistant.refreshAccount() } } label: {
                    if assistant.isConnecting { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }.disabled(assistant.isConnecting).accessibilityLabel("Refresh models")
            }
        }
    }
}

private struct CodexLoginView: View {
    @ObservedObject var assistant: AssistantCoordinator
    let login: CodexLogin
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy this code, then enter it on OpenAI’s sign-in page.").foregroundStyle(.secondary)
            Text(login.userCode).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                .privacySensitive().accessibilityLabel("Sign-in code, \(login.userCode)")
            Button(copied ? "Code copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: login.userCode]],
                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(900)])
                copied = true
            }.buttonStyle(.bordered)
            Link("Continue to ChatGPT", destination: login.verificationURL).buttonStyle(.borderedProminent)
                .tint(.primary).foregroundStyle(Color(uiColor: .systemBackground))
            HStack { ProgressView(); Text("Waiting for sign-in…").font(.footnote).foregroundStyle(.secondary) }
            Button("Cancel sign-in", role: .cancel) { Task { await assistant.cancelLogin() } }
        }
        .padding(.vertical, 8)
        .onChange(of: login.loginID) { _, _ in copied = false }
    }
}
