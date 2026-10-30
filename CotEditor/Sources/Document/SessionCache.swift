//
//  SessionCache.swift
//  CotEditor
//
//  Licensed under the Apache License, Version 2.0.
//

import Foundation

/// The ordered windows and tabs to reopen, with draft contents stored separately as UTF-8 text.
struct CachedSession: Codable, Equatable {
    
    struct Draft: Codable, Equatable {
        
        var id: UUID
        var title: String
        var encoding: UInt
        var withUTF8BOM: Bool
        var lineEnding: String
        var syntaxName: String
        var isVerticalText: Bool
    }
    
    struct Tab: Codable, Equatable, Identifiable {
        
        enum Content: Codable, Equatable {
            case draft(Draft)
            case file(url: URL, bookmark: Data?)
        }
        
        var content: Content
        
        var id: String {
            switch self.content {
                case .draft(let draft): draft.id.uuidString
                case .file(let url, _): url.standardizedFileURL.absoluteString
            }
        }
    }
    
    struct Window: Codable, Equatable {
        
        var tabs: [Tab]
        var selectedTabID: String?
    }
    
    var windows: [Window] = []
}


/// Stores drafts independently of their display names and the encoding selected for an eventual Save As.
struct SessionCache {
    
    let directoryURL: URL
    
    static var defaultDirectoryURL: URL {
        
        // Naming the user explicitly obtains the real home directory in a sandboxed application.
        let home = FileManager.default.homeDirectory(forUser: NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Documents/cot-editor-cache", directoryHint: .isDirectory)
    }
    
    private var manifestURL: URL { self.directoryURL.appending(path: "session.json") }
    
    
    func draftURL(for id: UUID) -> URL {
        
        self.directoryURL.appending(path: id.uuidString + ".txt")
    }
    
    
    func saveDraft(_ text: String, id: UUID) throws {
        
        try self.prepareDirectory()
        try Data(text.utf8).write(to: self.draftURL(for: id), options: .atomic)
    }
    
    
    func loadDraft(id: UUID) throws -> String {
        
        try String(contentsOf: self.draftURL(for: id), encoding: .utf8)
    }
    
    
    func save(_ session: CachedSession) throws {
        
        try self.prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: self.manifestURL, options: .atomic)
    }
    
    
    func load() throws -> CachedSession? {
        
        do {
            return try JSONDecoder().decode(CachedSession.self, from: Data(contentsOf: self.manifestURL))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
    
    
    private func prepareDirectory() throws {
        
        try FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
