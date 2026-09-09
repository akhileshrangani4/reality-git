import RealityGitCore
import SwiftUI

struct CaptureSettings: View {
    @ObservedObject var assistant: AssistantCoordinator
    @Binding var previewReference: Bool
    let hasReference: Bool
    let canReset: Bool
    let initialLink: String
    let reset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var confirmsDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                if assistant.connectionHost == nil || !link.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "macbook.and.iphone").font(.largeTitle).accessibilityHidden(true)
                            Text("Connect to Codex").font(.title2.bold())
                            Text("Scan with your ChatGPT plan.")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }.listRowBackground(Color.clear)
                    Section {
                        TextField("Connection link", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).lineLimit(1...3).privacySensitive()
                        Button {
                            Task {
                                if await assistant.connect(link: link) { link = ""; reset() }
                            }
                        } label: {
                            HStack { Text("Connect"); Spacer(); if assistant.isConnecting { ProgressView() } }
                        }
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isConnecting)
                    } footer: {
                        Text("Scan the code on your Mac with the iPhone Camera, or paste its connection link. Keep both devices on the same trusted Wi-Fi.")
                    }
                } else {
                    Section {
                        HStack {
                            Text("ChatGPT")
                            Spacer()
                            Label(assistant.signedIn ? "Signed in" : "Sign in", systemImage: assistant.signedIn ? "checkmark.circle.fill" : "person.crop.circle")
                                .foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                        if !assistant.signedIn {
                            if let login = assistant.login {
                                CodexLoginView(assistant: assistant, login: login)
                            } else {
                                Button {
                                    Task { await assistant.beginLogin() }
                                } label: {
                                    HStack { Text("Sign in with ChatGPT"); Spacer(); if assistant.isConnecting { ProgressView() } }
                                }.disabled(assistant.isConnecting)
                            }
                        }
                    } header: { Text("Account") } footer: {
                        Text("Scans use your Codex allowance. Your ChatGPT sign-in stays on your Mac.")
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
                    Section("Companion") {
                        LabeledContent("Mac", value: assistant.connectionHost ?? "")
                        Button {
                            Task { await assistant.refreshAccount() }
                        } label: {
                            HStack { Text("Reconnect"); Spacer(); if assistant.isConnecting { ProgressView() } }
                        }.disabled(assistant.isConnecting)
                        Button("Disconnect this iPhone", role: .destructive) { confirmsDisconnect = true }
                    }
                }
                if let message = assistant.connectionMessage {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                }
                if hasReference || canReset {
                    Section("Scan") {
                        if hasReference { Toggle("Show remembered shape", isOn: $previewReference) }
                        Button("Start over") { reset(); dismiss() }
                    }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { if assistant.disconnect() { reset() } }
            } message: { Text("Your Mac will stay signed in to ChatGPT. You can pair this iPhone again at any time.") }
        }
        .tint(.primary)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { link = initialLink }
        .onChange(of: initialLink) { _, value in link = value }
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
    @State private var expired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(expired ? "Request a new sign-in code." : "Enter this code on the ChatGPT sign-in page.")
                .foregroundStyle(.secondary)
            if !expired {
                Text(login.userCode).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                    .privacySensitive().accessibilityLabel("Sign-in code, \(login.userCode)")
                Button(copied ? "Code copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: login.userCode]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                    copied = true
                }.buttonStyle(.bordered)
                Link("Continue to ChatGPT", destination: login.verificationURL).buttonStyle(.borderedProminent)
                    .tint(.primary).foregroundStyle(Color(uiColor: .systemBackground))
                HStack { ProgressView(); Text("Waiting for sign-in…").font(.footnote).foregroundStyle(.secondary) }
            }
            Button(expired ? "Try again" : "Cancel sign-in", role: .cancel) {
                Task {
                    await assistant.cancelLogin()
                    if expired { await assistant.beginLogin() }
                }
            }.disabled(assistant.isConnecting)
        }
        .padding(.vertical, 8)
        .task(id: login.loginID) {
            expired = false; copied = false
            let deadline = Date().addingTimeInterval(600)
            while !Task.isCancelled, assistant.login?.loginID == login.loginID, Date() < deadline {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                await assistant.refreshAccount()
            }
            if !Task.isCancelled, !assistant.signedIn { expired = true }
        }
    }
}
