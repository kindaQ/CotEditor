//
//  UITests.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2018-02-13.
//
//  ---------------------------------------------------------------------------
//
//  © 2018-2026 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest
import AppKit
import Darwin

@MainActor final class UITests: XCTestCase {
    
    override func setUp() async throws {
        
        try await super.setUp()
        
        // In UI tests it is usually best to stop immediately when a failure occurs.
        self.continueAfterFailure = false
    }
    
    
    func testTyping() {
        
        let app = XCUIApplication()
        app.launch()
        
        // open a new document
        let menuBarsQuery = app.menuBars
        menuBarsQuery.menuBarItems["File"].click()
        menuBarsQuery.menuItems["New Window"].click()
        
        // type some words
        let documentWindow = app.windows.firstMatch
        let textView = documentWindow.textViews.firstMatch
        _ = textView.waitForExistence(timeout: 5)
        textView.typeText("Test.\r")
        XCTAssertEqual(textView.value as! String, "Test.\n")
        
        // wait a bit to let document autosave
        sleep(1)
        
        // delete entire words
        for _ in 1...6 {
            textView.typeKey(.delete, modifierFlags: [])
        }
        
        // close window without saving
        documentWindow.buttons[XCUIIdentifierCloseWindow].click()
        if documentWindow.sheets.count > 0 {
            // it actually depends on user settings and iCloud availability if save sheet appears...
            documentWindow.sheets.firstMatch.children(matching: .button)["Delete"].click()
        }
        sleep(1)
        XCTAssert(!documentWindow.exists)
    }
    
    
    func testSettingsWindow() {
        
        let app = XCUIApplication()
        app.launch()
        
        // open the Settings window
        let menuBarsQuery = app.menuBars
        menuBarsQuery.menuBarItems["CotEditor"].click()
        menuBarsQuery.menuItems["Settings…"].click()
        
        // open all panes
        app.buttons["General"].firstMatch.click()
        app.buttons["Appearance"].firstMatch.click()
        app.buttons["Window"].firstMatch.click()
        app.buttons["Edit"].firstMatch.click()
        app.buttons["Mode"].firstMatch.click()
        app.buttons["Format"].firstMatch.click()
        app.buttons["Snippets"].firstMatch.click()
        app.buttons["Shortcuts"].firstMatch.click()
        app.buttons["Donation"].firstMatch.click()
    }
    
    
    func testRestoresDraftTabsWhenReopened() async throws {
        
        let (app, cacheDirectory) = try self.launchSessionTestApp()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let firstText = "Session cache first draft 20261102"
        let secondText = "Session cache second draft 20261102"
        self.enterDraftTabs(app, firstText: firstText, secondText: secondText)
        let bundleURL = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.coteditor.CotEditor").first?.bundleURL)
        
        for _ in 0..<2 {
            self.closeSessionWindow(app)
            XCTAssertNotEqual(app.state, .notRunning)
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
            self.assertRestoredDraftTabs(app, firstText: firstText, secondText: secondText)
            app.windows.firstMatch.tabs.element(boundBy: 1).click()
        }
    }
    
    
    func testRestoresDraftTabsAfterProcessRelaunch() throws {
        
        let (app, cacheDirectory) = try self.launchSessionTestApp()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let firstText = "Process relaunch first draft 20261102"
        let secondText = "Process relaunch second draft 20261102"
        self.enterDraftTabs(app, firstText: firstText, secondText: secondText)
        self.closeSessionWindow(app)
        app.terminate()
        app.launch()
        self.assertRestoredDraftTabs(app, firstText: firstText, secondText: secondText)
    }


    func testRestoresSeparateWindowsAsOneTabGroup() async throws {

        let texts = ["Legacy window draft A", "Existing file in merged tabs", "Legacy window draft B", "Legacy window draft C"]
        // The workflow prepares this app-owned fixture before the sandboxed runner starts.
        let (app, cacheDirectory) = try self.launchSessionTestApp(cacheDirectoryName: "SessionUITests-separate-windows")
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        self.assertMergedTabs(app, texts: texts)
        let bundleURL = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.coteditor.CotEditor").first?.bundleURL)
        self.closeSessionWindow(app)
        _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
        self.assertMergedTabs(app, texts: texts)
        self.closeSessionWindow(app)
        app.terminate()
        app.launch()
        self.assertMergedTabs(app, texts: texts)

        app.windows.firstMatch.tabs.element(boundBy: 1).buttons.firstMatch.click()
        let remainingTexts = [texts[0], texts[2], texts[3]]
        self.assertMergedTabs(app, texts: remainingTexts)
        self.closeSessionWindow(app)
        app.terminate()
        app.launch()
        self.assertMergedTabs(app, texts: remainingTexts)
    }


    private func assertMergedTabs(_ app: XCUIApplication, texts: [String]) {

        let tabs = app.windows.firstMatch.tabs
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", texts.count), object: tabs)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertEqual(app.windows.count, 1)
        for (index, text) in texts.enumerated() {
            tabs.element(boundBy: index).click()
            XCTAssertEqual(app.windows.firstMatch.textViews["EditorTextView"].value as? String, text)
        }
    }


    func testTabBarDefaultsToVisibleAndRemembersManualChoice() throws {

        let (app, cacheDirectory) = try self.launchSessionTestApp()
        defer {
            if app.state != .notRunning, app.windows.firstMatch.exists,
               !app.windows.firstMatch.tabGroups.firstMatch.exists
            {
                app.menuBars.menuBarItems["View"].click()
                app.menuBars.menuItems["Show Tab Bar"].click()
            }
            app.terminate()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        app.menuBars.menuBarItems["View"].click()
        let hide = app.menuBars.menuItems["Hide Tab Bar"]
        XCTAssertTrue(hide.isEnabled)
        hide.click()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.windows.firstMatch.tabGroups)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)

        self.closeSessionWindow(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.textViews["EditorTextView"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.windows.firstMatch.tabGroups.firstMatch.exists)

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["New Tab"].click()
        XCTAssertEqual(app.windows.firstMatch.tabs.count, 2)
        self.closeSessionWindow(app)
        app.terminate()
        app.launch()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: app.windows.firstMatch.tabs)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
        XCTAssertEqual(app.windows.count, 1)
        app.menuBars.menuBarItems["View"].click()
        print("Native Hide Tab Bar enabled with multiple tabs: \(app.menuBars.menuItems["Hide Tab Bar"].isEnabled)")
        app.typeKey(.escape, modifierFlags: [])

        app.windows.firstMatch.tabs.element(boundBy: 1).buttons.firstMatch.click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count <= 1"), object: app.windows.firstMatch.tabs)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        app.menuBars.menuBarItems["View"].click()
        let hideAgain = app.menuBars.menuItems["Hide Tab Bar"]
        if hideAgain.exists {
            XCTAssertTrue(hideAgain.isEnabled)
            hideAgain.click()
            app.menuBars.menuBarItems["View"].click()
        }
        let show = app.menuBars.menuItems["Show Tab Bar"]
        XCTAssertTrue(show.isEnabled)
        show.click()
        XCTAssertTrue(app.windows.firstMatch.tabGroups.firstMatch.waitForExistence(timeout: 10))
    }
    
    
    private func launchSessionTestApp(cacheDirectoryName: String = "SessionUITests-" + UUID().uuidString) throws -> (XCUIApplication, URL) {
        
        let account = try XCTUnwrap(getpwuid(getuid()))
        let home = URL(filePath: String(cString: account.pointee.pw_dir))
        let cacheDirectory = home
            .appending(path: "Library/Containers/com.coteditor.CotEditor/Data/tmp/" + cacheDirectoryName)
        let app = XCUIApplication()
        app.launchEnvironment["COTEDITOR_SESSION_CACHE_DIRECTORY"] = cacheDirectory.path
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.textViews["EditorTextView"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.tabGroups.firstMatch.exists)
        return (app, cacheDirectory)
    }
    
    
    private func enterDraftTabs(_ app: XCUIApplication, firstText: String, secondText: String) {
        
        let firstEditor = app.windows.firstMatch.textViews["EditorTextView"]
        firstEditor.click()
        firstEditor.typeText(firstText)
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["New Tab"].click()
        let secondEditor = app.windows.firstMatch.textViews["EditorTextView"]
        XCTAssertTrue(secondEditor.waitForExistence(timeout: 10))
        secondEditor.click()
        secondEditor.typeText(secondText)
        XCTAssertEqual(app.windows.firstMatch.tabs.count, 2)
    }
    
    
    private func closeSessionWindow(_ app: XCUIApplication) {
        
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.windows)
        let result = XCTWaiter.wait(for: [closed], timeout: 10)
        if result != .completed {
            print(app.debugDescription)
            if let path = app.launchEnvironment["COTEDITOR_SESSION_CACHE_DIRECTORY"] {
                print("Session test cache: \(path)")
                print((try? String(contentsOfFile: path + "/test-events.txt", encoding: .utf8)) ?? "No session events recorded")
            }
        }
        XCTAssertEqual(result, .completed)
    }
    
    
    private func assertRestoredDraftTabs(_ app: XCUIApplication, firstText: String, secondText: String) {
        
        let editor = app.windows.firstMatch.textViews["EditorTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", secondText), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
        XCTAssertEqual(app.windows.firstMatch.tabs.count, 2)
        app.windows.firstMatch.tabs.element(boundBy: 0).click()
        XCTAssertEqual(app.windows.firstMatch.textViews["EditorTextView"].value as? String, firstText)
    }
    
    
    func testLaunchPerformance() throws {
        
        // This measures how long it takes to launch your application.
        self.measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
