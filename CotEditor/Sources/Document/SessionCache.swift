//
//  SessionCache.swift
//  CotEditor
//
//  Licensed under the Apache License, Version 2.0.
//

import Foundation
import Darwin

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


    /// Reopens every cached local document in one tab group, preserving tab order and selection.
    func mergingWindows() -> Self {

        var identifiers: Set<String> = []
        let tabs = self.windows.flatMap(\.tabs).filter { identifiers.insert($0.id).inserted }
        guard let first = tabs.first else { return Self() }
        let selectedID = self.windows.lazy.compactMap(\.selectedTabID)
            .first(where: identifiers.contains) ?? first.id
        return Self(windows: [Window(tabs: tabs, selectedTabID: selectedID)])
    }
}


/// Stores drafts independently of their display names and the encoding selected for an eventual Save As.
struct SessionCache {
    
    let directoryURL: URL
    
    static var defaultDirectoryURL: URL {
        
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["COTEDITOR_SESSION_CACHE_DIRECTORY"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        
        // Foundation home-directory APIs return the application container under App Sandbox.
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: URL = buffer.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &entry, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let directory = entry.pw_dir
            else { return FileManager.default.homeDirectoryForCurrentUser }
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return home.appending(path: "Documents/cot-editor-cache", directoryHint: .isDirectory)
    }
    
    static var legacyDirectoryURL: URL? {
        
        #if DEBUG
        guard ProcessInfo.processInfo.environment["COTEDITOR_SESSION_CACHE_DIRECTORY"] == nil else { return nil }
        #endif
        
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/cot-editor-cache", directoryHint: .isDirectory)
    }
    
    private var manifestURL: URL { self.directoryURL.appending(path: "session.json") }

    /// Records control flow only for an explicitly isolated debug UI test.
    static func recordTestEvent(_ message: String) {

        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["COTEDITOR_SESSION_CACHE_DIRECTORY"] else { return }
        let url = URL(filePath: path).appending(path: "test-events.txt")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = (try? Data(contentsOf: url)) ?? Data()
            data.append(contentsOf: (message + "\n").utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Session UI test event could not be written: \(error)")
        }
        #endif
    }
    
    
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
    
    
    /// Imports the previous container-based session once, preserving both copies of every draft.
    func importLegacySession(from directoryURL: URL) throws {
        
        let markerURL = self.directoryURL.appending(path: ".legacy-session-imported")
        guard directoryURL.standardizedFileURL != self.directoryURL.standardizedFileURL,
              !FileManager.default.fileExists(atPath: markerURL.path)
        else { return }
        
        let legacy = SessionCache(directoryURL: directoryURL)
        guard let previous = try legacy.load() else { return }
        var session = try self.load() ?? CachedSession()
        var identifiers = Set(session.windows.flatMap(\.tabs).map(\.id))
        
        for window in previous.windows {
            var tabs: [CachedSession.Tab] = []
            for tab in window.tabs where identifiers.insert(tab.id).inserted {
                if case .draft(let draft) = tab.content {
                    let destination = self.draftURL(for: draft.id)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try self.prepareDirectory()
                        try FileManager.default.copyItem(at: legacy.draftURL(for: draft.id), to: destination)
                    }
                }
                tabs.append(tab)
            }
            if !tabs.isEmpty {
                let selectedID = tabs.contains(where: { $0.id == window.selectedTabID }) ? window.selectedTabID : tabs.first?.id
                session.windows.append(CachedSession.Window(tabs: tabs, selectedTabID: selectedID))
            }
        }
        try self.save(session)
        try Data().write(to: markerURL, options: .atomic)
    }
    
    
    private func prepareDirectory() throws {
        
        try FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
