import SwiftUI
import PDFKit

struct DocumentsScreen: View {
    @EnvironmentObject private var content: ContentStore

    var body: some View {
        if let c = content.content {
            FieldScroll {
                Text("Official PDFs bundled with the app. They open offline; links go to the publisher's page.").font(.fieldCaption).foregroundStyle(.secondary)
                ForEach(c.documents) { doc in
                    NavigationLink(value: Route.document(doc.id)) {
                        FieldCard {
                            HStack(alignment: .top) {
                                Image(systemName: "doc.richtext").font(.title2).foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(doc.title).font(.fieldHeading)
                                    Text(doc.edition).font(.fieldCaption).foregroundStyle(.secondary)
                                    Text(doc.description).font(.fieldCaption).lineLimit(3)
                                    Text("\(doc.category) · \(doc.pages) pages · \(ByteCountFormatter.string(fromByteCount: Int64(doc.bytes), countStyle: .file)) · included offline").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .fieldNavigationTitle("Documents")
        }
    }
}

struct DocumentDetailView: View {
    let documentId: String
    @EnvironmentObject private var content: ContentStore
    @State private var showReader = false

    var body: some View {
        if let c = content.content, let doc = c.document(documentId) {
            let fileURL = BundleContent.resourceURL(doc.bundledFile, subdirectory: "Documents")
            FieldScroll {
                FieldCard {
                    Text(doc.category).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(doc.description).font(.fieldBody)
                    LabeledContent("Edition", value: doc.edition)
                    if let v = doc.validThrough { LabeledContent("Valid through", value: DateText.long(v)) }
                    LabeledContent("Publisher", value: doc.publisher)
                    LabeledContent("Pages", value: "\(doc.pages)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(doc.bytes), countStyle: .file))
                    LabeledContent("File date", value: doc.lastModified)
                    LabeledContent("Reviewed", value: DateText.long(doc.reviewed))
                    LabeledContent("Offline", value: fileURL != nil ? "Included in the app" : "Missing from this build")
                    Text(doc.note).font(.fieldCaption).foregroundStyle(.secondary)
                }
                .font(.fieldCaption)
                HStack {
                    Button { showReader = true } label: { Label("Open PDF", systemImage: "doc.text.magnifyingglass") }.buttonStyle(.borderedProminent).disabled(fileURL == nil)
                    if let fileURL { ShareLink(item: fileURL, preview: SharePreview(doc.title)) { Label("Share / save to Files", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered) }
                }
                .font(.fieldCaption)
                FieldCard(eyebrow: "Official links") {
                    if let url = URL(string: doc.url) { ExternalLinkRow(label: "Original PDF on the publisher's site", url: url) }
                    if let url = URL(string: doc.sourcePage) { ExternalLinkRow(label: "Publisher's page for this document", url: url) }
                    Text("SHA-256 \(doc.sha256.prefix(16))… verified when the pack was built.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .fieldNavigationTitle(doc.title)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showReader) {
                if let fileURL { PDFReaderView(title: doc.title, url: fileURL) }
            }
        } else {
            EmptyStateView(symbol: "doc", title: "Document not found", message: "This link points to a document that is not bundled.")
        }
    }
}

struct PDFReaderView: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0
    @State private var pageCount = 1
    @State private var document: PDFDocument?

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFKitView(document: document, pageIndex: $pageIndex, pageCount: $pageCount)
                } else {
                    ProgressView("Opening…")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { pageIndex = max(0, pageIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(pageIndex == 0)
                    Spacer()
                    Text("Page \(pageIndex + 1) of \(pageCount)").font(.fieldCaption)
                    Spacer()
                    Button { pageIndex = min(pageCount - 1, pageIndex + 1) } label: { Image(systemName: "chevron.right") }.disabled(pageIndex >= pageCount - 1)
                    ShareLink(item: url, preview: SharePreview(title)) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .task { document = PDFDocument(url: url) }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int
    @Binding var pageCount: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.minScaleFactor = 0.5
        view.maxScaleFactor = 6
        view.usePageViewController(false)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        DispatchQueue.main.async { pageCount = document.pageCount }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if let current = view.currentPage, document.index(for: current) != pageIndex, let page = document.page(at: pageIndex) {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pageIndex: $pageIndex) }

    @MainActor
    final class Coordinator: NSObject {
        private let pageIndex: Binding<Int>
        init(pageIndex: Binding<Int>) { self.pageIndex = pageIndex }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            pageIndex.wrappedValue = document.index(for: page)
        }
    }
}
