import SwiftUI
import UniformTypeIdentifiers

struct BackupSheet: View {
    @EnvironmentObject private var saved: SavedStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportDocument: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var includeReceipts = true
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Export") {
                    Toggle("Include suggestion receipts", isOn: $includeReceipts)
                    Button {
                        do {
                            exportDocument = BackupDocument(data: try BackupCoordinator.export(includeReceipts: includeReceipts))
                            showExporter = true
                        } catch { show("Export failed: \(error.localizedDescription)", error: true) }
                    } label: { Label("Save backup to Files", systemImage: "square.and.arrow.down") }
                    Text("Includes saved places and notes, campsite, car pin, saved event views and tracked topics, plus appearance, map, conditions, event-filter, custom-category and planner settings and any unsent suggestion draft. Receipts are private: they let another device see replies to your suggestions, so include them only when the file stays with you.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("Restore") {
                    Button { showImporter = true } label: { Label("Import a backup", systemImage: "square.and.arrow.up") }
                    Text("The file is validated first. Saved places merge and the newer note wins; the newer car pin and campsite win; views, topics, categories and receipts fill gaps. Settings in the file replace this device's. Nothing is removed.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
                if let message {
                    Section { Text(message).font(.fieldCaption).foregroundStyle(messageIsError ? Palette.ember : Palette.meadow) }
                }
            }
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "enve-yosemite-backup-\(DateText.dayString(Date()))") { result in
                switch result {
                case .success: show("Backup saved.", error: false)
                case .failure(let error): show("Could not save: \(error.localizedDescription)", error: true)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
                switch result {
                case .success(let url):
                    let secured = url.startAccessingSecurityScopedResource()
                    defer { if secured { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let report = try BackupCoordinator.restore(try Data(contentsOf: url))
                        show(report.text, error: false)
                    } catch { show(error.localizedDescription, error: true) }
                case .failure(let error): show(error.localizedDescription, error: true)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func show(_ text: String, error: Bool) { message = text; messageIsError = error }
}

struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
