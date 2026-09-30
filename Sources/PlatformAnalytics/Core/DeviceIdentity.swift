import Foundation
import Security
import os

/// Identifiant anonyme de l'appareil (C05 §2.1) : UUID v4 stocké dans le Keychain, non synchronisé,
/// `AfterFirstUnlockThisDeviceOnly`. Thread-safe : la valeur est mise en cache sous verrou.
final class DeviceIdentity: Sendable {
    /// Stockage de la valeur ; `KeychainStore` en production, un stockage mémoire dans les tests.
    protocol Store: Sendable {
        func read() -> String?
        func write(_ value: String) -> Bool
    }

    private struct State {
        var id: String?
        var created = false
        var needsWrite = false
    }

    private let store: any Store
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(store: any Store = KeychainStore()) {
        self.store = store
    }

    /// L'identifiant courant, lu ou créé si besoin, et si il a été créé (au premier lancement ou par
    /// `rotate()`) depuis le dernier `load()`. Réservé à l'actor : c'est lui qui émet `$session_start.first`.
    func load() -> (id: String, created: Bool) {
        state.withLock { state in
            let id = resolve(&state)
            defer { state.created = false }
            return (id, state.created)
        }
    }

    /// L'identifiant courant (lu ou créé si besoin), sans consommer l'indicateur de création.
    var current: String { state.withLock { resolve(&$0) } }

    private func resolve(_ state: inout State) -> String {
        if let id = state.id { return id }
        if let stored = store.read(), UUID(uuidString: stored) != nil {
            state.id = stored
            return stored
        }
        let fresh = UUID().uuidString
        state.id = fresh
        state.created = true
        if !store.write(fresh) {
            Log.error("device_id could not be stored, it will change at next launch")
        }
        return fresh
    }

    /// Nouvel identifiant, en mémoire seulement (aucune I/O) ; `persist()` l'écrit.
    @discardableResult
    func rotate() -> String {
        let fresh = UUID().uuidString
        state.withLock { state in
            state.id = fresh
            state.created = true
            state.needsWrite = true
        }
        return fresh
    }

    /// Écrit l'identifiant issu d'un `rotate()` dans le stockage.
    func persist() {
        state.withLock { state in
            guard state.needsWrite, let id = state.id else { return }
            state.needsWrite = false
            if !store.write(id) {
                Log.error("new device_id could not be stored")
            }
        }
    }
}

/// Élément Keychain `kSecClassGenericPassword`, service `com.platform.analytics`, account `device_id`.
struct KeychainStore: DeviceIdentity.Store {
    var service = "com.platform.analytics"
    var account = "device_id"

    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        #if os(macOS)
            if status == errSecMissingEntitlement {  // app macOS non signée : trousseau classique
                query[kSecUseDataProtectionKeychain as String] = false
                status = SecItemCopyMatching(query as CFDictionary, &result)
            }
        #endif
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { Log.warning("keychain read failed (\(status))") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var query = baseQuery()
        var status = upsert(query: query, attributes: attributes)
        #if os(macOS)
            if status == errSecMissingEntitlement {
                query[kSecUseDataProtectionKeychain as String] = false
                status = upsert(query: query, attributes: attributes)
            }
        #endif
        if status != errSecSuccess { Log.warning("keychain write failed (\(status))") }
        return status == errSecSuccess
    }

    private func upsert(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
