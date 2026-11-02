//
//  SessionController.swift
//  CotEditor
//
//  Licensed under the Apache License, Version 2.0.
//

import AppKit

/// Owns local document sessions, including windows closed while the application remains running.
@MainActor final class SessionController {
    
    static let shared = SessionController(cache: SessionCache(directoryURL: SessionCache.defaultDirectoryURL),
                                          legacyDirectoryURL: SessionCache.legacyDirectoryURL)
    
    let cache: SessionCache
    private(set) var isClosing = false
    private(set) var isRestoring = false
    private var hasAttemptedRestoration = false
    private var retainedWindows: [CachedSession.Window] = []
    private var securityScopedURLs: [URL] = []
    private let legacyDirectoryURL: URL?
    
    
    init(cache: SessionCache, legacyDirectoryURL: URL? = nil) {
        
        self.cache = cache
        self.legacyDirectoryURL = legacyDirectoryURL
    }
    
    
    /// Starts restoration once, before the normal launch action can create a blank document.
    @discardableResult func restoreOnLaunchIfNeeded() -> Bool {
        
        guard !self.hasAttemptedRestoration else { return self.isRestoring }
        self.hasAttemptedRestoration = true
        
        do {
            if let legacyDirectoryURL = self.legacyDirectoryURL {
                try self.cache.importLegacySession(from: legacyDirectoryURL)
            }
            guard let session = try self.cache.load(), !session.windows.isEmpty else { return false }
            self.isRestoring = true
            Task { await self.restore(session) }
            return true
        } catch {
            NSApp.presentError(error)
            return false
        }
    }
    
    
    /// Restores windows closed earlier in this process when the application is opened again.
    @discardableResult func restoreClosedWindowsIfNeeded() -> Bool {
        
        guard !self.isRestoring, !self.isClosing else { return true }
        guard !self.retainedWindows.isEmpty else { return false }
        let session = CachedSession(windows: self.retainedWindows)
        self.retainedWindows.removeAll()
        self.isRestoring = true
        Task { await self.restore(session) }
        return true
    }
    
    
    /// Saves every draft before committing the list of windows to reopen.
    func persistCurrentSession(allowEmpty: Bool = false) throws {
        
        guard !self.isRestoring else { throw CocoaError(.userCancelled) }
        let windows = try self.captureWindows()
        guard allowEmpty || !windows.isEmpty else { return }
        try self.cache.save(CachedSession(windows: windows))
    }
    
    
    func cacheDraft(_ document: TextDocument) throws {
        
        try self.cache.saveDraft(document.textStorage.string, id: document.sessionDraftID)
    }
    
    
    /// Closes a whole window, preserving its tab order even when other windows remain open.
    func closeWindow(_ window: NSWindow) async {
        
        let documents = (window.tabGroup?.windows ?? [window])
            .compactMap { $0.windowController?.document as? NSDocument }
        SessionCache.recordTestEvent("close window; documents=\(documents.count)")
        _ = await self.close(documents)
    }
    
    
    /// Validates all documents before closing any of them, so cancellation leaves the tabs open.
    func close(_ documents: [NSDocument]) async -> Bool {
        
        SessionCache.recordTestEvent("close session; closing=\(self.isClosing); restoring=\(self.isRestoring)")
        guard !self.isClosing, !self.isRestoring else { return false }
        self.isClosing = true
        defer { self.isClosing = false }
        
        do {
            try self.persistCurrentSession()
            SessionCache.recordTestEvent("session persisted")
            
            for document in documents {
                let canClose: Bool
                if let controller = document.windowControllers.first {
                    canClose = await document.canClose(windowController: controller)
                } else {
                    canClose = await document.canClose()
                }
                SessionCache.recordTestEvent("document approved=\(canClose)")
                guard canClose else { return false }
            }
            
            // A Save As in a confirmation sheet may have changed a draft into a named file.
            let windows = try self.captureWindows()
            try self.cache.save(CachedSession(windows: windows))
            let closingIDs = Set(documents.compactMap { ($0 as? TextDocument)?.sessionTabID })
            self.retainedWindows = windows.compactMap { group in
                let tabs = group.tabs.filter { closingIDs.contains($0.id) || self.isRetained($0.id) }
                return tabs.isEmpty ? nil : CachedSession.Window(tabs: tabs, selectedTabID: group.selectedTabID)
            }
            
            for document in documents {
                document.close()
            }
            SessionCache.recordTestEvent("documents closed")
            return true
        } catch {
            SessionCache.recordTestEvent("close failed: \(error)")
            NSApp.presentError(error)
            return false
        }
    }
    
    
    /// A tab closed explicitly is removed from the next session; its text backup remains available.
    func documentDidClose() {
        
        guard self.hasAttemptedRestoration, !self.isClosing, !self.isRestoring else { return }
        do {
            try self.persistCurrentSession(allowEmpty: true)
        } catch {
            NSApp.presentError(error)
        }
    }
    
    
    private func isRetained(_ id: String) -> Bool {
        
        self.retainedWindows.contains { $0.tabs.contains { $0.id == id } }
    }
    
    
    private func captureWindows() throws -> [CachedSession.Window] {
        
        let documents = NSDocumentController.shared.documents
            .compactMap { $0 as? TextDocument }
            .filter(\.usesSessionCache)
        let windows = NSApp.orderedWindows + documents.flatMap { $0.windowControllers.compactMap(\.window) }
        var seen: Set<ObjectIdentifier> = []
        var groups: [CachedSession.Window] = []
        
        for window in windows {
            guard !seen.contains(ObjectIdentifier(window)) else { continue }
            let groupWindows = window.tabGroup?.windows ?? [window]
            seen.formUnion(groupWindows.map(ObjectIdentifier.init))
            let groupDocuments = groupWindows.compactMap { $0.windowController?.document as? TextDocument }
                .filter { $0.usesSessionCache && documents.contains($0) }
            guard !groupDocuments.isEmpty else { continue }
            
            let tabs = try groupDocuments.map { document in
                if document.isSessionDraft {
                    try self.cacheDraft(document)
                }
                return try document.makeSessionTab()
            }
            let selectedDocument = (window.tabGroup?.selectedWindow ?? window).windowController?.document as? TextDocument
            groups.append(CachedSession.Window(tabs: tabs, selectedTabID: selectedDocument?.sessionTabID))
        }
        
        let activeIDs = Set(groups.flatMap(\.tabs).map(\.id))
        for group in self.retainedWindows {
            let tabs = group.tabs.filter { !activeIDs.contains($0.id) }
            if !tabs.isEmpty {
                groups.append(CachedSession.Window(tabs: tabs, selectedTabID: group.selectedTabID))
            }
        }
        return groups
    }
    
    
    private func restore(_ session: CachedSession) async {
        
        let controller = NSDocumentController.shared as! DocumentController
        var errors: [any Error] = []
        var frontWindow: NSWindow?
        
        for group in session.mergingWindows().windows {
            var restoredWindows: [(String, NSWindow)] = []
            var failedTabs: [CachedSession.Tab] = []
            
            for tab in group.tabs {
                do {
                    let document: TextDocument
                    switch tab.content {
                        case .draft(let draft):
                            if let existing = controller.documents.compactMap({ $0 as? TextDocument })
                                .first(where: { $0.isSessionDraft && $0.sessionDraftID == draft.id })
                            {
                                document = existing
                            } else {
                                let text = try self.cache.loadDraft(id: draft.id)
                                document = try controller.openUntitledDocumentAndDisplay(false) as! TextDocument
                                document.restoreSessionDraft(draft, text: text)
                            }
                        case .file(let originalURL, let bookmark):
                            var isStale = false
                            let url = try bookmark.map {
                                try URL(resolvingBookmarkData: $0, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
                            } ?? originalURL
                            let scoped = url.startAccessingSecurityScopedResource()
                            do {
                                let (opened, _) = try await controller.openDocument(withContentsOf: url, display: false)
                                guard let textDocument = opened as? TextDocument else {
                                    throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: originalURL])
                                }
                                document = textDocument
                                if scoped { self.securityScopedURLs.append(url) }
                            } catch {
                                if scoped { url.stopAccessingSecurityScopedResource() }
                                throw error
                            }
                    }
                    
                    // Assemble the restored tabs explicitly in their cached order.
                    DocumentWindow.tabbingPreference = .manual
                    document.makeWindowControllers()
                    document.showWindows()
                    DocumentWindow.tabbingPreference = nil
                    if let window = document.windowControllers.first?.window {
                        if let first = restoredWindows.first?.1, first !== window {
                            first.tabGroup?.insertWindow(window, at: restoredWindows.count)
                        }
                        restoredWindows.append((tab.id, window))
                    }
                } catch {
                    errors.append(error)
                    failedTabs.append(tab)
                }
            }
            
            if let selected = restoredWindows.first(where: { $0.0 == group.selectedTabID })?.1 {
                selected.tabGroup?.selectedWindow = selected
                frontWindow = frontWindow ?? selected
            } else {
                frontWindow = frontWindow ?? restoredWindows.first?.1
            }
            if !failedTabs.isEmpty {
                self.retainedWindows.append(CachedSession.Window(tabs: failedTabs, selectedTabID: group.selectedTabID))
            }
        }
        
        self.isRestoring = false
        frontWindow?.makeKeyAndOrderFront(nil)
        for error in errors {
            NSApp.presentError(error)
        }
        if controller.documents.isEmpty {
            controller.performOnLaunchAction(restoresClosedWindows: false)
        }
    }
}
