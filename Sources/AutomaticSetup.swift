import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

// This file contains NO per-user secrets. Each user's credentials are entered
// locally and written to that user's login Keychain only.
private enum SetupError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private enum CredentialKeychain {
    static func save(_ value: String, service: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrService as String: service
        ]
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = lookup
            add[kSecValueData as String] = Data(value.utf8)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SetupError.message("Unable to store \(service) in macOS Keychain (\(status)).")
        }
    }

    static func delete(_ service: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrService as String: service
        ]
        let result = SecItemDelete(lookup as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw SetupError.message("Could not delete local credential (\(result)).")
        }
    }
}

private enum LocalTOTP {
    // Accept an unpadded Base32 seed OR a standard otpauth:// URL exported by
    // the user's own MFA provider. Reject malformed input before Keychain save.
    static func normalizedSeed(_ input: String) throws -> String {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var seed = original
        if original.lowercased().hasPrefix("otpauth://") {
            guard let components = URLComponents(string: original),
                  components.scheme?.lowercased() == "otpauth",
                  components.host?.lowercased() == "totp",
                  let extracted = components.queryItems?.first(where: {
                      $0.name.lowercased() == "secret"
                  })?.value else {
                throw SetupError.message("That is not a valid TOTP enrollment URL.")
            }
            seed = extracted
        }
        seed = seed.uppercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
        guard seed.count >= 16 else {
            throw SetupError.message("The TOTP seed looks too short. Paste the secret key, not a six-digit code.")
        }
        _ = try decodeBase32(seed)
        return seed
    }

    static func decodeBase32(_ value: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var accumulator: UInt32 = 0
        var bits = 0
        var bytes = Data()
        for character in value {
            guard let digit = alphabet.firstIndex(of: character) else {
                throw SetupError.message("The key is not valid Base32. Use the secret from Microsoft Security Info.")
            }
            accumulator = (accumulator << 5) | UInt32(digit)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xff))
            }
            accumulator &= bits == 0 ? 0 : (1 << bits) - 1
        }
        guard bytes.count >= 10, bits == 0 || accumulator == 0 else {
            throw SetupError.message("Invalid Base32 padding or incomplete TOTP secret.")
        }
        return bytes
    }

    static func code(_ original: String, at time: Date = Date()) throws -> String {
        let seed = try normalizedSeed(original)
        let key = SymmetricKey(data: try decodeBase32(seed))
        var step = UInt64(time.timeIntervalSince1970 / 30).bigEndian
        let data = withUnsafeBytes(of: &step) { Data($0) }
        let hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        let offset = Int(hash[hash.count - 1] & 0x0f)
        let value = (UInt32(hash[offset] & 0x7f) << 24) |
            (UInt32(hash[offset + 1]) << 16) |
            (UInt32(hash[offset + 2]) << 8) |
            UInt32(hash[offset + 3])
        return String(format: "%06d", value % 1_000_000)
    }
}

@MainActor
private final class SetupWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AutomaticSetupWindow.window = nil
    }
}

@MainActor
enum AutomaticSetupWindow {
    static var window: NSWindow?
    private static let delegate = SetupWindowDelegate()

    static func show(model: VPNModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let setup = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 610),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        setup.title = "ULiège VPN · Automatic Sign-In"
        setup.isReleasedWhenClosed = false
        setup.delegate = delegate
        setup.contentViewController = NSHostingController(
            rootView: AutomaticSetupView(model: model, onClose: { window?.close() })
        )
        setup.center()
        window = setup
        setup.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
struct AutomaticSetupView: View {
    @ObservedObject var model: VPNModel
    let onClose: () -> Void
    @State private var email = ""
    @State private var identifier = ""
    @State private var universityPassword = ""
    @State private var seedInput = ""
    @State private var result = ""
    @State private var preview = ""
    @State private var isError = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic sign-in").font(.title3.bold())
                    Text("Optional · This Mac only").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onClose() }
            }
            Text("Register a separate TOTP method for your own university account in Microsoft Security Info, then paste its secret key below. Never share your key with colleagues.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Microsoft Security Info ↗") {
                NSWorkspace.shared.open(URL(string: "https://mysignins.microsoft.com/security-info")!)
            }
            .buttonStyle(.link)

            VStack(alignment: .leading, spacing: 10) {
                TextField("University Microsoft email", text: $email)
                TextField("ULiège identifier (e.g. s123456)", text: $identifier)
                SecureField("University password", text: $universityPassword)
                SecureField("TOTP secret key or otpauth:// URL", text: $seedInput)
                HStack {
                    Button("Preview current six-digit code") {
                        do {
                            preview = try LocalTOTP.code(seedInput)
                            result = "Use this code on Microsoft's enrollment page to verify your new TOTP method."
                            isError = false
                        } catch {
                            preview = ""
                            result = error.localizedDescription
                            isError = true
                        }
                    }
                    Spacer()
                    if !preview.isEmpty {
                        Text(preview).font(.system(.body, design: .monospaced).bold())
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("These credentials are saved in your login Keychain. This unattended method stores both password and MFA seed on the same Mac; browser sign-in is safer if you don't want that trade-off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !result.isEmpty {
                Text(result).font(.caption).foregroundStyle(isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Remove saved automatic credentials", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .font(.caption)
                Spacer()
                Button("Save securely") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 470)
        .confirmationDialog(
            "Remove saved automatic credentials from this Mac?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove local password and TOTP", role: .destructive) {
                do {
                    try CredentialKeychain.delete("uliege-vpn-password")
                    try CredentialKeychain.delete("uliege-mfa-totp")
                    result = "Local automatic credentials deleted. Your Microsoft MFA enrollment remains active."
                    isError = false
                } catch { result = error.localizedDescription; isError = true }
            }
        }
        .onAppear {
            email = model.universityEmail
            identifier = model.universityUsername
        }
    }

    private func save() {
        do {
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedEmail.contains("@") && !trimmedID.isEmpty else {
                throw SetupError.message("Please enter your university email and ULiège identifier.")
            }
            guard !universityPassword.isEmpty else {
                throw SetupError.message("Please enter the password used for the ULiège login page.")
            }
            let seed = try LocalTOTP.normalizedSeed(seedInput)
            try CredentialKeychain.save(universityPassword, service: "uliege-vpn-password")
            try CredentialKeychain.save(seed, service: "uliege-mfa-totp")
            model.universityEmail = trimmedEmail
            model.universityUsername = trimmedID
            model.preferInteractiveLogin = false
            universityPassword = ""
            seedInput = ""
            preview = ""
            isError = false
            result = "Saved in Keychain. Confirm your MFA enrollment with Microsoft before connecting."
        } catch {
            result = error.localizedDescription
            isError = true
        }
    }
}
