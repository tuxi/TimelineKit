import Foundation

/// Where the editor writes its timeline when the editor closes.
///
/// `.draftStore` is the legacy behavior: write a DraftStore JSON and, when a
/// library project is active, also write the project. `.library` makes the
/// active `.tlkproj` the only timeline source; it never writes DraftStore.
public enum EditorPersistenceMode: Sendable, Equatable {
    case draftStore
    case library
}
