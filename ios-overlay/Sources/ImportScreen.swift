import SwiftUI
import UIKit
import UniformTypeIdentifiers

import Darwin

private struct NSPContentRecord: Sendable {
    let type: String
    let titleID: String
    let version: String
}

private enum MetadataProbe {
    typealias InspectFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32
    ) -> Int32

    private static let lock = NSLock()
    private static var frameworkHandle: UnsafeMutableRawPointer?
    private static var inspectFunction: InspectFunction?

    static func inspect(keysURL: URL, nspURL: URL) throws -> [NSPContentRecord] {
        lock.lock()
        defer { lock.unlock() }

        if inspectFunction == nil {
            let binary = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks/NxNativeMetadataProbe.framework/NxNativeMetadataProbe")
            guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
                throw ImportValidationError.metadata("Could not load the LibHac metadata engine: \(detail)")
            }
            guard let symbol = dlsym(handle, "nxn_inspect_nsp") else {
                let detail = dlerror().map { String(cString: $0) } ?? "symbol not found"
                dlclose(handle)
                throw ImportValidationError.metadata("The metadata engine is missing its inspection function: \(detail)")
            }
            frameworkHandle = handle
            inspectFunction = unsafeBitCast(symbol, to: InspectFunction.self)
        }

        guard let inspect = inspectFunction else {
            throw ImportValidationError.metadata("The metadata engine could not be initialized.")
        }

        var output = [CChar](repeating: 0, count: 64 * 1024)
        let result = keysURL.path.withCString { keyPath in
            nspURL.path.withCString { packagePath in
                output.withUnsafeMutableBufferPointer { buffer in
                    inspect(keyPath, packagePath, buffer.baseAddress!, Int32(buffer.count))
                }
            }
        }
        guard result >= 0 else {
            throw ImportValidationError.metadata(result == -2
                ? "The package metadata output exceeded the safety limit."
                : "The metadata engine rejected the input paths (code \(result)).")
        }

        let response = output.withUnsafeBufferPointer { buffer in String(cString: buffer.baseAddress!) }
        if response.hasPrefix("error|") {
            throw ImportValidationError.metadata(String(response.dropFirst(6)))
        }

        let records = response.split(separator: "\n").compactMap { line -> NSPContentRecord? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == "content" else { return nil }
            return NSPContentRecord(type: String(fields[1]), titleID: String(fields[2]).uppercased(), version: String(fields[3]))
        }
        guard !records.isEmpty else {
            throw ImportValidationError.metadata("No recognized game content metadata was returned.")
        }
        return records
    }
}

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

private struct ImportedGameFile: Codable, Identifiable, Equatable, Sendable {
    let displayName: String
    let storedName: String
    var validationStatus: String?
    var id: String { storedName }
}

private enum ImportValidationError: LocalizedError {
    case unreadable
    case invalidKeys(String)
    case missingKey(String)
    case invalidContainer(String)
    case noNCA
    case wrongContentType(expected: String, found: String)
    case metadata(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The selected file could not be read."
        case .invalidKeys(let reason):
            return "Invalid prod.keys file: \(reason)"
        case .missingKey(let key):
            return "The keys file is missing a required key: \(key)."
        case .invalidContainer(let reason):
            return "Invalid NSP container: \(reason)"
        case .noNCA:
            return "The NSP contains no NCA content files."
        case .wrongContentType(let expected, let found):
            return "Wrong NSP content type. Expected \(expected), but found \(found)."
        case .metadata(let reason):
            return "Metadata check failed: \(reason)"
        }
    }
}

private enum ImportFileStorage {
    static func validate(_ source: URL, kind: ImportKind) throws {
        let expectedExtension = kind == .keys ? "keys" : "nsp"
        guard source.pathExtension.lowercased() == expectedExtension else {
            throw ImportValidationError.invalidContainer("expected a .\(expectedExtension) file.")
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        switch kind {
        case .keys:
            try validateKeys(source)
        case .base, .update, .dlc:
            try validateNSP(source)
        }
    }

    private static func validateKeys(_ source: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw ImportValidationError.unreadable }
        guard data.count > 0, data.count <= 16 * 1024 * 1024,
              let decoded = String(data: data, encoding: .utf8) else {
            throw ImportValidationError.invalidKeys("file is empty, too large, or not UTF-8 text.")
        }
        // Some editors prepend a UTF-8 byte-order mark; it is not part of the
        // first key name and must be removed before parsing.
        let text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded

        var parsed: [String: String] = [:]
        for (lineNumber, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw ImportValidationError.invalidKeys("line \(lineNumber + 1) is not a key=value entry.")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) }) else {
                throw ImportValidationError.invalidKeys("line \(lineNumber + 1) has an invalid key name.")
            }
            guard !value.isEmpty, value.count.isMultiple(of: 2),
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
                throw ImportValidationError.invalidKeys("line \(lineNumber + 1) has a non-hexadecimal or incomplete value.")
            }
            parsed[name.lowercased()] = value
        }

        // header_key is used later to decrypt NCA headers, but some otherwise
        // usable prod.keys dumps omit it. Do not reject the whole key file at
        // import time solely because this optional entry is absent.
        if let headerKey = parsed["header_key"], headerKey.count != 64 {
            throw ImportValidationError.invalidKeys("header_key must be a 32-byte (64 hex character) value when present.")
        }

        // Switch master_key values are 128-bit AES keys (16 bytes = 32 hex
        // characters), not 32-byte values. Match the standard prod.keys names
        // case-insensitively; values are normalized above.
        let hasMasterKey = parsed.contains { entry in
            entry.key.range(of: #"^master_key_[0-9a-f]{2}$"#, options: .regularExpression) != nil
                && entry.value.count == 32
        }
        guard hasMasterKey else {
            throw ImportValidationError.missingKey("at least one 16-byte master_key_XX entry (32 hexadecimal characters)")
        }
    }

    private static func validateNSP(_ source: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: source.path) }
        catch { throw ImportValidationError.unreadable }
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value, fileSize >= 16 else {
            throw ImportValidationError.invalidContainer("file is too small to contain a PFS0 header.")
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: source) }
        catch { throw ImportValidationError.unreadable }
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 16) ?? Data()
        guard header.count == 16, String(data: header.prefix(4), encoding: .ascii) == "PFS0" else {
            throw ImportValidationError.invalidContainer("missing PFS0 package signature.")
        }

        let count = UInt64(readLE32(header, 4))
        let stringSize = UInt64(readLE32(header, 8))
        guard count > 0, count <= 100_000 else {
            throw ImportValidationError.invalidContainer("file-entry count is invalid.")
        }
        let entriesSize = count * 0x18
        let metadataSize = 16 + entriesSize + stringSize
        guard metadataSize <= fileSize, metadataSize <= 64 * 1024 * 1024 else {
            throw ImportValidationError.invalidContainer("file table exceeds the package bounds.")
        }

        let remainder = try handle.read(upToCount: Int(metadataSize - 16)) ?? Data()
        guard remainder.count == Int(metadataSize - 16) else {
            throw ImportValidationError.invalidContainer("file table is truncated.")
        }
        var table = header
        table.append(remainder)

        let stringsStart = 16 + Int(entriesSize)
        let stringsEnd = stringsStart + Int(stringSize)
        var ncaCount = 0
        for index in 0..<Int(count) {
            let entry = 16 + index * 0x18
            let offset = readLE64(table, entry)
            let size = readLE64(table, entry + 8)
            let nameOffset = UInt64(readLE32(table, entry + 16))
            guard size > 0, offset <= fileSize, size <= fileSize,
                  metadataSize <= fileSize, offset <= fileSize - metadataSize,
                  size <= fileSize - metadataSize - offset,
                  nameOffset < stringSize else {
                throw ImportValidationError.invalidContainer("an entry has an invalid size, offset, or name.")
            }
            let nameStart = stringsStart + Int(nameOffset)
            guard nameStart < stringsEnd,
                  let terminator = table[nameStart..<stringsEnd].firstIndex(of: 0),
                  terminator > nameStart,
                  let name = String(data: table[nameStart..<terminator], encoding: .utf8) else {
                throw ImportValidationError.invalidContainer("an entry has an invalid filename.")
            }
            if name.lowercased().hasSuffix(".nca") {
                // NCA headers are encrypted with the console's header key.
                // Their plaintext magic is therefore not visible by simply
                // reading offset 0x200 from the NSP. Full NCA validation must
                // wait for the LibHac metadata/key inspection stage.
                ncaCount += 1
            }
        }
        guard ncaCount > 0 else { throw ImportValidationError.noNCA }
    }

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (UInt32($1) * 8)) }
    }

    private static func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << (UInt64($1) * 8)) }
    }

    static func inspectContent(_ source: URL, keysURL: URL, kind: ImportKind) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let records = try MetadataProbe.inspect(keysURL: keysURL, nspURL: source)
        let expected: String
        switch kind {
        case .base: expected = "Application"
        case .update: expected = "Patch"
        case .dlc: expected = "AddOnContent"
        case .keys: return "Keys syntax checked"
        }
        let matching = records.filter { $0.type == expected }
        guard let record = matching.first else {
            let found = Array(Set(records.map(\.type))).sorted().joined(separator: ", ")
            throw ImportValidationError.wrongContentType(expected: expected, found: found.isEmpty ? "unknown" : found)
        }
        let label: String
        switch kind {
        case .base: label = "Verified base game"
        case .update: label = "Verified update"
        case .dlc: label = "Verified DLC"
        case .keys: label = "Keys syntax checked"
        }
        let extra = records.count > 1 ? " · package has \(records.count) metadata records" : ""
        return "\(label) · \(record.titleID) · v\(record.version)\(extra)"
    }

    static func copyIntoAppStorage(_ source: URL, prefix: String, validationStatus: String) throws -> ImportedGameFile {
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

        return ImportedGameFile(displayName: source.lastPathComponent, storedName: storedName, validationStatus: validationStatus)
    }
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
                            detail: base.map { "\($0.displayName) · \($0.validationStatus ?? "Imported")" } ?? "Not selected",
                            selected: base != nil
                        ) { picker = ImportPickerRequest(kind: .base) }

                        fileRow(
                            title: "prod.keys",
                            detail: keys.map { "\($0.displayName) · \($0.validationStatus ?? "Imported")" } ?? "Not selected",
                            selected: keys != nil
                        ) { picker = ImportPickerRequest(kind: .keys) }
                    }

                    fileSection(
                        title: "Optional content",
                        subtitle: "Optional content is checked against encrypted CNMT metadata when prod.keys is available."
                    ) {
                        fileRow(
                            title: "Game update",
                            detail: update.map { "\($0.displayName) · \($0.validationStatus ?? "Imported")" } ?? "No update selected",
                            selected: update != nil
                        ) { picker = ImportPickerRequest(kind: .update) }

                        fileRow(
                            title: "Add DLC",
                            detail: dlc.isEmpty ? "No DLC selected" : "\(dlc.count) NSP file(s) imported",
                            selected: !dlc.isEmpty
                        ) { picker = ImportPickerRequest(kind: .dlc) }

                        if !dlc.isEmpty {
                            ForEach(dlc) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.displayName).lineLimit(1)
                                        Text(item.validationStatus ?? "Imported").font(.caption2).foregroundStyle(.secondary)
                                    }
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
                            .foregroundColor(status.hasPrefix("Import failed") ? .red : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            base?.validationStatus?.hasPrefix("Verified base game") == true && keys != nil ? "Required files verified" : "Waiting for verified required files",
                            systemImage: base?.validationStatus?.hasPrefix("Verified base game") == true && keys != nil ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.headline)
                        .foregroundStyle(base?.validationStatus?.hasPrefix("Verified base game") == true && keys != nil ? .green : .primary)

                        Text("With prod.keys selected, the app reads encrypted CNMT metadata to distinguish base games, updates, and DLC. The on-device extraction and IPA packaging engine is still under development.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
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
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
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
                    .foregroundColor(selected ? .green : .accentColor)
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
            let existingKeysURL = keys.map { storedURL(for: $0) }
            let imported = try await Task.detached(priority: .userInitiated) {
                // Validate every selection before copying any of them. A bad item
                // must not partially replace a previously valid selection.
                try urls.forEach { try ImportFileStorage.validate($0, kind: kind) }
                return try urls.map { source in
                    let level: String
                    if kind == .keys {
                        level = "Keys syntax checked"
                    } else if let existingKeysURL {
                        level = try ImportFileStorage.inspectContent(source, keysURL: existingKeysURL, kind: kind)
                    } else {
                        level = "Container checked · waiting for prod.keys"
                    }
                    return try ImportFileStorage.copyIntoAppStorage(source, prefix: kind.prefix, validationStatus: level)
                }
            }.value

            switch kind {
            case .base:
                if let previous = base { deleteStoredFile(previous) }
                base = imported.first
                defaults.set(base.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.base")
            case .keys:
                if let previous = keys { deleteStoredFile(previous) }
                keys = imported.first
                defaults.set(keys.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.keys")
            case .update:
                if let previous = update { deleteStoredFile(previous) }
                update = imported.first
                defaults.set(update.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.update")
            case .dlc:
                dlc.append(contentsOf: imported)
                saveDLC()
            }
            let count = imported.count
            status = "Imported \(count) file(s)."
            if kind == .keys { await verifySavedContent() }
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
        importing = false
    }


    private func loadSavedFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Imports", isDirectory: true)
        func existing(_ key: String, kind: ImportKind) -> ImportedGameFile? {
            guard let data = defaults.data(forKey: key),
                  let item = try? JSONDecoder().decode(ImportedGameFile.self, from: data) else { return nil }
            let url = folder.appendingPathComponent(item.storedName)
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? ImportFileStorage.validate(url, kind: kind)) != nil else {
                try? FileManager.default.removeItem(at: url)
                defaults.removeObject(forKey: key)
                return nil
            }
            return item
        }
        base = existing("nxn.import.base", kind: .base)
        keys = existing("nxn.import.keys", kind: .keys)
        update = existing("nxn.import.update", kind: .update)
        if let data = defaults.data(forKey: "nxn.import.dlc"),
           let saved = try? JSONDecoder().decode([ImportedGameFile].self, from: data) {
            dlc = saved.filter { item in
                let url = folder.appendingPathComponent(item.storedName)
                guard FileManager.default.fileExists(atPath: url.path),
                      (try? ImportFileStorage.validate(url, kind: .dlc)) != nil else {
                    try? FileManager.default.removeItem(at: url)
                    return false
                }
                return true
            }
            saveDLC()
        }
        if keys != nil { Task { await verifySavedContent() } }
    }

    private func storedURL(for item: ImportedGameFile) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(item.storedName)
    }

    @MainActor
    private func verifySavedContent() async {
        guard let keys else { return }
        importing = true
        status = "Reading encrypted content metadata…"
        let keyURL = storedURL(for: keys)
        let baseSnapshot = base
        let updateSnapshot = update
        let dlcSnapshot = dlc
        let baseURL = baseSnapshot.map { storedURL(for: $0) }
        let updateURL = updateSnapshot.map { storedURL(for: $0) }
        let dlcURLs = dlcSnapshot.map { storedURL(for: $0) }
        let checked = await Task.detached(priority: .userInitiated) {
            func checkedFile(_ item: ImportedGameFile?, url: URL?, kind: ImportKind) -> ImportedGameFile? {
                guard var item, let url else { return nil }
                do {
                    item.validationStatus = try ImportFileStorage.inspectContent(url, keysURL: keyURL, kind: kind)
                } catch {
                    item.validationStatus = error.localizedDescription
                }
                return item
            }
            let checkedBase = checkedFile(baseSnapshot, url: baseURL, kind: .base)
            let checkedUpdate = checkedFile(updateSnapshot, url: updateURL, kind: .update)
            let checkedDLC = dlcSnapshot.enumerated().map { index, item -> ImportedGameFile in
                checkedFile(item, url: dlcURLs[index], kind: .dlc) ?? item
            }
            return (checkedBase, checkedUpdate, checkedDLC)
        }.value
        base = checked.0
        update = checked.1
        dlc = checked.2
        defaults.set(base.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.base")
        defaults.set(update.flatMap { try? JSONEncoder().encode($0) }, forKey: "nxn.import.update")
        saveDLC()
        importing = false
        status = "Metadata checks finished. Review each file's status above."
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
