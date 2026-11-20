import Foundation

/// Read-only evidence from the installed bundle. This does not authorize entitlements,
/// validate a CMS signature, or establish that FaceTime works. iOS owns code-signing enforcement.
enum SharePlaySigningCheck {
    static let entitlement = "com.apple.developer.group-session"

    static func permitsLaunch(signature: Bool?, profile: Bool?) -> Bool {
        signature == true && profile == true
    }

    static func unavailableReason(signature: Bool?, profile: Bool?) -> String? {
        guard !permitsLaunch(signature: signature, profile: profile) else { return nil }
        func state(_ value: Bool?) -> String {
            switch value { case true: "present"; case false: "missing"; case nil: "unreadable or unavailable" }
        }
        return "SharePlay requires Apple-authorized Group Activities signing. Signature: \(state(signature)); provisioning profile: \(state(profile)). A free Apple ID, including free SideStore signing, cannot grant this capability. Use an eligible paid Apple Developer Program team with Group Activities enabled and an authorized profile, installed as a development/ad-hoc build through Xcode or Apple-supported device installation. Re-signing must preserve that authorization; a setting cannot add it. Unreadable evidence is not proof that an entitlement is missing."
    }

    static var installedAppUnavailableReason: String? {
        #if os(iOS)
            #if targetEnvironment(simulator)
                return "SharePlay requires signed physical iPhones. This simulator cannot verify Group Activities signing."
            #else
                let bundle = Bundle.main
                let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
                    .flatMap { try? Data(contentsOf: $0) }.flatMap(profileEntitlement)
                let signature = bundle.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
                    .flatMap(signedEntitlement)
                return unavailableReason(signature: signature, profile: profile)
            #endif
        #else
            return nil
        #endif
    }

    static func profileEntitlement(_ data: Data) -> Bool? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound ..< data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound ..< end.upperBound), format: nil,
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements[entitlement] as? Bool ?? false
    }

    /// Installed iPhone executables are thin little-endian Mach-O 64-bit images.
    /// Unsupported/DER-only/malformed signatures fail closed, without using private APIs.
    static func signedEntitlement(_ data: Data) -> Bool? {
        func word(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = Array(data[offset ..< offset + 4])
            return bigEndian
                ? bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                : bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard word(0) == 0xFEED_FACF, let count = word(16), let size = word(20),
              Int(size) <= data.count - 32, count <= size / 8 else { return nil }
        var command = 32
        let commandsEnd = 32 + Int(size)
        for _ in 0 ..< count {
            guard command <= commandsEnd - 8, let kind = word(command), let length = word(command + 4),
                  length >= 8, Int(length) <= commandsEnd - command else { return nil }
            defer { command += Int(length) }
            guard kind == 0x1D else { continue } // LC_CODE_SIGNATURE
            guard length >= 16, let offset = word(command + 8), let length = word(command + 12) else { return nil }
            let base = Int(offset), end = base + Int(length)
            guard end <= data.count, length >= 12,
                  word(base, bigEndian: true) == 0xFADE_0CC0,
                  let blobSize = word(base + 4, bigEndian: true), blobSize <= length, blobSize >= 12,
                  let entries = word(base + 8, bigEndian: true), entries <= (blobSize - 12) / 8 else { return nil }
            let blobEnd = base + Int(blobSize)
            for index in 0 ..< Int(entries) {
                let entry = base + 12 + index * 8
                guard word(entry, bigEndian: true) == 5 else { continue } // XML entitlements slot
                guard let relative = word(entry + 4, bigEndian: true),
                      relative >= 12 + entries * 8 else { return nil }
                let start = base + Int(relative)
                guard start <= blobEnd - 8, word(start, bigEndian: true) == 0xFADE_7171,
                      let size = word(start + 4, bigEndian: true), size >= 8,
                      Int(size) <= blobEnd - start,
                      let plist = try? PropertyListSerialization.propertyList(
                          from: data.subdata(in: start + 8 ..< start + Int(size)), format: nil,
                      ) as? [String: Any] else { return nil }
                return plist[entitlement] as? Bool ?? false
            }
            return nil
        }
        return nil
    }
}
