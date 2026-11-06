import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum ImportKind: String, Identifiable, Sendable {
    case base, keys, update, dlc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .base: return "Base game NSP"
        case .keys: return "prod.keys"
        case .update: return "Game update NSP"
        case .dlc: return "DLC NSP files"
        }
    }
    var prefix: String {
        switch self {
        case .base: return "base"
        case .keys: return "prod-keys"
        case .update: return "update"
        case .dlc: return "dlc"
        }
    }
    var extensions: [String] { self == .keys ? ["keys"] : ["nsp"] }
    var allowsMultiple: Bool { self == .dlc }
}

private struct ImportedGameFile: Codable, Identifiable, Equatable {
    let displayName: String
    let storedName: String
    var id: String { storedName }
}

private struct ImportPickerRequest: Identifiable {
    let kind: ImportKind
    var id: String { kind.id }
}

private struct ImportDocumentPicker: UIViewControllerRepresentable {
    let extensions: [String]
    let allowsMultiple: Bool
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types.isEmpty ? [.data] : types,
            asCopy: false
        )
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.isEmpty ? onCancel() : onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct ImportScreenView: View {
    @State private var base: ImportedGameFile?
    @State private var keys: ImportedGameFile?
    @State private var update: ImportedGameFile?
    @State private var dlc: [ImportedGameFile] = []
    @State private var picker: ImportPickerRequest?
    @State private var importing = false
    @State private var status = ""

    private let defaults = UserDefaults.standard

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prepare a game")
                            .font(.largeTitle.bold())
                        Text("Choose your own game files. Everything you import is copied into this app's private storage.")
                            .foregroundStyle(.secondary)
                    }

                    fileSection(
                        title: "Required files",
                        subtitle: "Both are needed before game preparation can begin."
                    ) {
                        fileRow(
                            title: "Base game NSP",
                            detail: base?.displayName ?? "Not selected",
                            selected: base != nil
                        ) { picker = ImportPickerRequest(kind: .base) }

                        fileRow(
                            title: "prod.keys",
                            detail: keys?.displayName ?? "Not selected",
                            selected: keys != nil
                        ) { picker = ImportPickerRequest(kind: .keys) }
                    }

                    fileSection(
                        title: "Optional content",
                        subtitle: "You can add these now or leave them out."
                    ) {
                        fileRow(
                            title: "Game update",
                            detail: update?.displayName ?? "No update selected",
                            selected: update != nil
                        ) { picker = ImportPickerRequest(kind: .update) }

                        fileRow(
                            title: "Add DLC",
                            detail: dlc.isEmpty ? "No DLC selected" : "\(dlc.count) DLC file(s) imported",
                            selected: !dlc.isEmpty
                        ) { picker = ImportPickerRequest(kind: .dlc) }

                        if !dlc.isEmpty {
                            ForEach(dlc) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text(item.displayName).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Button(role: .destructive) { removeDLC(item) } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .font(.footnote)
                            }
                        }
                    }

                    if importing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Copying selected file(s)…").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(status.hasPrefix("Import failed") ? .red : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            base != nil && keys != nil ? "Required files imported" : "Waiting for required files",
                            systemImage: base != nil && keys != nil ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.headline)
                        .foregroundStyle(base != nil && keys != nil ? .green : .primary)

                        Text("The on-device extraction and IPA packaging engine is the next development step. This screen currently imports and stores your files; it does not build or launch a game yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear all", role: .destructive, action: clearAll)
                        .disabled(base == nil && keys == nil && update == nil && dlc.isEmpty)
                }
            }
            .sheet(item: $picker) { request in
                ImportDocumentPicker(
                    extensions: request.kind.extensions,
                    allowsMultiple: request.kind.allowsMultiple,
                    onPick: { urls in
                        picker = nil
                        Task { await importFiles(urls, kind: request.kind) }
                    },
                    onCancel: { picker = nil }
                )
                .ignoresSafeArea()
            }
            .onAppear(perform: loadSavedFiles)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func fileSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func fileRow(
        title: String,
        detail: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "doc.badge.plus")
                    .font(.title2)
                    .foregroundStyle(selected ? .green : .tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importing)
    }

    @MainActor
    private func importFiles(_ urls: [URL], kind: ImportKind) async {
        guard !urls.isEmpty else { return }
        importing = true
        status = "Importing \(urls.count) file(s)…"
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try urls.map { try Self.copyIntoAppStorage($0, prefix: kind.prefix) }
            }.value

            switch kind {
            case .base:
                base = imported.first
                defaults.set(base?.storedName, forKey: "nxn.import.base")
            case .keys:
                keys = imported.first
                defaults.set(keys?.storedName, forKey: "nxn.import.keys")
            case .update:
                update = imported.first
                defaults.set(update?.storedName, forKey: "nxn.import.update")
            case .dlc:
                dlc.append(contentsOf: imported)
                saveDLC()
            }
            let count = imported.count
            status = "Imported \(count) file(s) successfully."
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
        importing = false
    }

    private static func copyIntoAppStorage(_ source: URL, prefix: String) throws -> ImportedGameFile {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let storedName = "\(prefix)-\(UUID().uuidString).\(ext)"
        let destination = folder.appendingPathComponent(storedName)
        try FileManager.default.copyItem(at: source, to: destination)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)

        return ImportedGameFile(displayName: source.lastPathComponent, storedName: storedName)
    }

    private func loadSavedFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Imports", isDirectory: true)
        func existing(_ key: String) -> ImportedGameFile? {
            guard let name = defaults.string(forKey: key),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { return nil }
            return ImportedGameFile(displayName: name, storedName: name)
        }
        base = existing("nxn.import.base")
        keys = existing("nxn.import.keys")
        update = existing("nxn.import.update")
        if let data = defaults.data(forKey: "nxn.import.dlc"),
           let saved = try? JSONDecoder().decode([ImportedGameFile].self, from: data) {
            dlc = saved.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.storedName).path) }
        }
    }

    private func saveDLC() {
        if let data = try? JSONEncoder().encode(dlc) {
            defaults.set(data, forKey: "nxn.import.dlc")
        }
    }

    private func removeDLC(_ item: ImportedGameFile) {
        deleteStoredFile(item)
        dlc.removeAll { $0.id == item.id }
        saveDLC()
    }

    private func clearAll() {
        [base, keys, update].compactMap { $0 }.forEach(deleteStoredFile)
        dlc.forEach(deleteStoredFile)
        base = nil; keys = nil; update = nil; dlc = []
        ["nxn.import.base", "nxn.import.keys", "nxn.import.update", "nxn.import.dlc"].forEach(defaults.removeObject(forKey:))
        status = "Imported file selections cleared."
    }

    private func deleteStoredFile(_ item: ImportedGameFile) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Imports", isDirectory: true).appendingPathComponent(item.storedName)
        try? FileManager.default.removeItem(at: url)
    }
}

@_cdecl("dm_show_import_screen")
public func dmShowImportScreen(_ viewController: UnsafeMutableRawPointer) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let host = DmHostingController(rootView: ImportScreenView())
    host.modalPresentationStyle = .fullScreen
    parent.present(host, animated: false)
}
