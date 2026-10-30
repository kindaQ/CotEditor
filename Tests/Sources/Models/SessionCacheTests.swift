//
//  SessionCacheTests.swift
//  CotEditor
//
//  Licensed under the Apache License, Version 2.0.
//

import Foundation
import Testing
#if canImport(CotEditor)
@testable import CotEditor
#endif

struct SessionCacheTests {
    
    @Test func createsCacheDirectoryAndRestoresUnicodeExactly() throws {
        
        try self.withCache { cache in
            let id = UUID()
            let text = "中文🙂\r\nかな\n\u{FEFF}\u{0000}  trailing spaces  \r"
            try cache.saveDraft(text, id: id)
            #expect(try cache.loadDraft(id: id) == text)
            #expect(try Data(contentsOf: cache.draftURL(for: id)) == Data(text.utf8))
        }
    }
    
    
    @Test func identicalTitlesHaveIndependentFiles() throws {
        
        try self.withCache { cache in
            let first = self.draft(title: "未命名")
            let second = self.draft(title: "未命名")
            try cache.saveDraft("First", id: first.id)
            try cache.saveDraft("Second", id: second.id)
            let session = CachedSession(windows: [.init(tabs: [.init(content: .draft(first)), .init(content: .draft(second))], selectedTabID: second.id.uuidString)])
            try cache.save(session)
            
            #expect(cache.draftURL(for: first.id) != cache.draftURL(for: second.id))
            #expect(try cache.loadDraft(id: first.id) == "First")
            #expect(try cache.loadDraft(id: second.id) == "Second")
            #expect(try cache.load() == session)
        }
    }
    
    
    @Test func updatingDraftPreservesOtherDrafts() throws {
        
        try self.withCache { cache in
            let first = UUID()
            let second = UUID()
            try cache.saveDraft("Original", id: first)
            try cache.saveDraft("Other", id: second)
            try cache.saveDraft("Updated", id: first)
            #expect(try cache.loadDraft(id: first) == "Updated")
            #expect(try cache.loadDraft(id: second) == "Other")
        }
    }
    
    
    @Test func preservesWindowsSelectionFilePathsAndDraftMetadata() throws {
        
        try self.withCache { cache in
            let draft = self.draft(title: "notes/../../example.txt")
            let file = CachedSession.Tab(content: .file(url: URL(filePath: "/tmp/中文 folder/existing.txt"), bookmark: Data([1, 2, 3])))
            let session = CachedSession(windows: [
                .init(tabs: [file, .init(content: .draft(draft))], selectedTabID: draft.id.uuidString),
                .init(tabs: [file], selectedTabID: file.id),
            ])
            try cache.saveDraft("🙂 cannot fit ASCII", id: draft.id)
            try cache.save(session)
            #expect(try cache.load() == session)
            #expect(cache.draftURL(for: draft.id).deletingLastPathComponent().standardizedFileURL == cache.directoryURL.standardizedFileURL)
            #expect(try cache.loadDraft(id: draft.id) == "🙂 cannot fit ASCII")
        }
    }
    
    
    @Test func emptyDraftsAndEmptySessionsRoundTrip() throws {
        
        try self.withCache { cache in
            let id = UUID()
            try cache.saveDraft("", id: id)
            try cache.save(CachedSession())
            #expect(try cache.loadDraft(id: id).isEmpty)
            #expect(try cache.load() == CachedSession())
        }
    }
    
    
    @Test func absentSessionDoesNotCreateDirectory() throws {
        
        try self.withCache { cache in
            let session = try cache.load()
            #expect(session == nil)
            #expect(!FileManager.default.fileExists(atPath: cache.directoryURL.path))
        }
    }
    
    
    @Test func corruptManifestIsReportedAndPreserved() throws {
        
        try self.withCache { cache in
            try FileManager.default.createDirectory(at: cache.directoryURL, withIntermediateDirectories: true)
            let url = cache.directoryURL.appending(path: "session.json")
            let data = Data("incomplete JSON".utf8)
            try data.write(to: url)
            #expect(throws: (any Error).self) { try cache.load() }
            #expect(try Data(contentsOf: url) == data)
        }
    }
    
    
    @Test func failedDraftWritePreservesPreviousSession() throws {
        
        try self.withCache { cache in
            let draft = self.draft(title: "Existing")
            let session = CachedSession(windows: [.init(tabs: [.init(content: .draft(draft))], selectedTabID: draft.id.uuidString)])
            try cache.saveDraft("Keep this text", id: draft.id)
            try cache.save(session)
            let blockedID = UUID()
            try FileManager.default.createDirectory(at: cache.draftURL(for: blockedID), withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try cache.saveDraft("New text", id: blockedID) }
            #expect(try cache.load() == session)
            #expect(try cache.loadDraft(id: draft.id) == "Keep this text")
        }
    }
    
    
    @Test func failedManifestWriteLeavesDraftAvailable() throws {
        
        try self.withCache { cache in
            let id = UUID()
            try cache.saveDraft("Recoverable text", id: id)
            try FileManager.default.createDirectory(at: cache.directoryURL.appending(path: "session.json"), withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try cache.save(CachedSession()) }
            #expect(try cache.loadDraft(id: id) == "Recoverable text")
        }
    }
    
    
    private func draft(title: String) -> CachedSession.Draft {
        
        .init(id: UUID(), title: title, encoding: String.Encoding.ascii.rawValue,
              withUTF8BOM: false, lineEnding: "\r\n", syntaxName: "Markdown", isVerticalText: true)
    }
    
    
    private func withCache(_ body: (SessionCache) throws -> Void) throws {
        
        let directory = FileManager.default.temporaryDirectory.appending(path: "SessionCacheTests-" + UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SessionCache(directoryURL: directory.appending(path: "nested/cache", directoryHint: .isDirectory)))
    }
}
