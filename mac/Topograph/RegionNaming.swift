import Security
import SwiftUI
import TopographCore

/// Rename a region yourself, or ask Claude for a suggestion once you've turned that on.
struct RegionNaming: View {
    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme
    let region: Region
    @AppStorage("aiNamingEnabled") private var enabled = false
    @State private var editing = false
    @State private var draft = ""
    @State private var settingUp = false
    @State private var key = ""
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button("rename") {
                    draft = region.label
                    editing.toggle()
                }
                .buttonStyle(KeyStyle(theme: theme))
                Button(working ? "asking…" : "suggest a name") {
                    if enabled, APIKeyStore.read() != nil { suggest() } else { settingUp = true }
                }
                .buttonStyle(KeyStyle(theme: theme))
                .disabled(working)
            }
            if editing {
                nameField
            }
            if settingUp {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RegionNamer.disclosure)
                        .font(PlexSans.font(size: 12))
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("", text: $key, prompt: Text("your anthropic api key").foregroundStyle(theme.secondary.color))
                        .textFieldStyle(.plain)
                        .font(PlexMono.font(.regular, size: 11))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(theme.surface.color)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
                    HStack(spacing: 4) {
                        Button("turn on") {
                            if !key.isEmpty { APIKeyStore.save(key) }
                            key = ""
                            enabled = true
                            settingUp = false
                            suggest()
                        }
                        .buttonStyle(KeyStyle(theme: theme, on: true))
                        .disabled(key.isEmpty && APIKeyStore.read() == nil)
                        Button("not now") { settingUp = false }.buttonStyle(KeyStyle(theme: theme))
                    }
                }
            }
            if enabled, !settingUp {
                Button("turn off suggestions and forget my key") {
                    APIKeyStore.delete()
                    enabled = false
                }
                .buttonStyle(.plain)
                .font(PlexMono.font(.regular, size: 10))
                .foregroundStyle(theme.secondary.color)
            }
            if let note {
                Text(note).font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nameField: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(PlexMono.font(.regular, size: 11))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(theme.surface.color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
            Button("use this name") {
                let name = draft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.rename(region: region.id, to: name) }
                editing = false
                note = nil
            }
            .buttonStyle(KeyStyle(theme: theme))
        }
    }

    private func suggest() {
        guard let key = APIKeyStore.read() else { return }
        working = true
        note = nil
        let picks = Array(map.regions.members(of: region.id)
            .sorted { map.items[Int($0)].resonance > map.items[Int($1)].resonance }
            .filter { map.items[Int($0)].thumb != nil }
            .prefix(RegionNamer.sampleLimit))
        let samples = picks.map { index -> RegionNamer.Sample in
            let item = map.items[Int(index)]
            return RegionNamer.Sample(thumbnail: item.thumb.map(library.file), caption: item.text)
        }
        let siblingIDs = region.parent.flatMap { map.regions.regions[$0]?.children } ?? map.regions.roots
        let siblings = siblingIDs.filter { $0 != region.id }.compactMap { map.regions.regions[$0]?.label }
        Task {
            do {
                draft = try await RegionNamer(key: key).suggest(samples: samples, siblings: siblings)
                editing = true
            } catch {
                note = error.localizedDescription
            }
            working = false
        }
    }
}

/// Your API key, in the Keychain.
enum APIKeyStore {
    private static var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.jbobrow.Topograph.anthropic",
            kSecAttrAccount: "api-key",
        ]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var item = query
        item[kSecValueData] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
