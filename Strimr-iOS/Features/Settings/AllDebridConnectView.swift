import SwiftUI

@MainActor
struct AllDebridConnectView: View {
    private let onConnected: () -> Void
    @State private var isConnected = false
    @State private var isChecking = true
    @State private var isConnecting = false
    @State private var pin: AllDebridPIN?
    @State private var errorMessage: String?
    @State private var authorizationTask: Task<Void, Never>?

    init(onConnected: @escaping () -> Void = {}) {
        self.onConnected = onConnected
    }

    var body: some View {
        Form {
            Section("Account") {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(isConnected ? Color.green : Color.gray)

                if isConnected {
                    Button("Disconnect", role: .destructive, action: disconnect)
                }
            }

            if !isConnected {
                Section("Connect") {
                    Text("Authorize Strimr with an AllDebrid PIN. Your API key is stored securely in Keychain.")

                    if let pin {
                        Text(pin.pin)
                            .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("AllDebrid PIN: \(pin.pin)")

                        Link("Open AllDebrid PIN page", destination: pin.userURL)
                        Text("Keep this screen open while Strimr checks the PIN.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if isConnecting {
                        ProgressView("Waiting for authorization…")
                        Button("Cancel", role: .cancel) {
                            authorizationTask?.cancel()
                        }
                    } else {
                        Button("Connect AllDebrid", action: beginAuthorization)
                            .disabled(isChecking)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Connect AllDebrid")
        .task {
            await refreshConnectionStatus()
        }
        .onDisappear {
            authorizationTask?.cancel()
        }
    }

    private var statusTitle: String {
        if isChecking {
            return "Checking connection…"
        }
        return isConnected ? "Connected" : "Disconnected"
    }

    private var statusSymbol: String {
        if isChecking {
            return "ellipsis.circle"
        }
        return isConnected ? "checkmark.circle.fill" : "xmark.circle"
    }

    private func refreshConnectionStatus() async {
        isChecking = true
        defer { isChecking = false }
        do {
            guard let apiKey = try AllDebridCredentialStore().load() else {
                isConnected = false
                return
            }
            let client = try AllDebridAPIClient(apiKey: apiKey)
            _ = try await client.verifyConnection()
            isConnected = true
            errorMessage = nil
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    private func beginAuthorization() {
        guard authorizationTask == nil else { return }
        errorMessage = nil
        pin = nil
        isConnecting = true
        authorizationTask = Task {
            defer {
                authorizationTask = nil
                isConnecting = false
            }
            await authorize()
        }
    }

    private func authorize() async {
        do {
            let client = AllDebridAPIClient()
            let pin = try await client.requestPIN()
            self.pin = pin
            var expiresIn = pin.expiresIn

            while expiresIn > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(expiresIn, 5)) * 1_000_000_000)
                try Task.checkCancellation()

                let result = try await client.checkPIN(pin: pin.pin, check: pin.check)
                expiresIn = result.expiresIn
                guard result.activated else { continue }
                guard let apiKey = result.apiKey else {
                    throw AllDebridAPIClient.APIError.invalidResponse
                }

                let authenticatedClient = try AllDebridAPIClient(apiKey: apiKey)
                _ = try await authenticatedClient.verifyConnection()
                try AllDebridCredentialStore().save(apiKey)
                isConnected = true
                self.pin = nil
                errorMessage = nil
                onConnected()
                return
            }
            throw AllDebridAPIClient.APIError.pinExpired
        } catch is CancellationError {
            pin = nil
        } catch {
            pin = nil
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() {
        do {
            try AllDebridCredentialStore().delete()
            isConnected = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
