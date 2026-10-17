import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Formwerk design: a package with design.json and imported bodies.
    static let formwerkDesign = UTType(exportedAs: "com.yvesf.formwerk.design", conformingTo: .package)
    /// STEP files (whatever type the system knows for .step/.stp).
    static var stepFiles: [UTType] {
        ["step", "stp"].compactMap { UTType(filenameExtension: $0) }
    }
}

/// The document. Every change goes through `apply`, which registers undo
/// (that is also how the system knows to save).
final class FormwerkDocument: ReferenceFileDocument {
    struct Snapshot {
        var design: Design
        var thumbnail: Data?
    }

    @Published var design: Design
    /// The last rendered preview (PNG), saved into the package for Files/Finder.
    var thumbnail: Data?

    static var readableContentTypes: [UTType] { [.formwerkDesign] }

    init(design: Design = Design()) {
        self.design = design
    }

    required init(configuration: ReadConfiguration) throws {
        let wrapper = configuration.file
        guard let files = wrapper.fileWrappers, let json = files["design.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var d = try JSONDecoder().decode(Design.self, from: json)
        if let imports = files["imports"]?.fileWrappers {
            for (name, file) in imports {
                if let data = file.regularFileContents { d.importedShapes[(name as NSString).deletingPathExtension] = data }
            }
        }
        design = d
    }

    func snapshot(contentType: UTType) throws -> Snapshot { Snapshot(design: design, thumbnail: thumbnail) }

    func fileWrapper(snapshot full: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let snapshot = full.design
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files: [String: FileWrapper] = [
            "design.json": FileWrapper(regularFileWithContents: try encoder.encode(snapshot)),
        ]
        if !snapshot.importedShapes.isEmpty {
            var imports: [String: FileWrapper] = [:]
            for (key, data) in snapshot.importedShapes { imports["\(key).brep"] = FileWrapper(regularFileWithContents: data) }
            files["imports"] = FileWrapper(directoryWithFileWrappers: imports)
        }
        if let thumb = full.thumbnail {
            files["thumbnail.png"] = FileWrapper(regularFileWithContents: thumb)
        }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// Replaces the design and registers undo/redo.
    func apply(_ new: Design, actionName: String, undoManager: UndoManager?) {
        let old = design
        guard old != new else { return }
        design = new
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.apply(old, actionName: actionName, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
    }
}

