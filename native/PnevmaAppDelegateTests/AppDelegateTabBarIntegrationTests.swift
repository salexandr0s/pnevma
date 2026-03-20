import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class AppDelegateTabBarIntegrationTests: XCTestCase {
    private static var sharedAppDelegate: AppDelegate?
    private var launchedAppDelegate: AppDelegate?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        launchedAppDelegate?.resetForIntegrationTesting()
        launchedAppDelegate = nil
        super.tearDown()
    }

    override class func tearDown() {
        sharedAppDelegate?.shutdownForTesting()
        sharedAppDelegate = nil
        super.tearDown()
    }

    func testMainWindowTabBarHandlesSelectAddAndInlineRenameFromRealWindow() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)

            appDelegate.newTab()
            waitUntil {
                self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count == 2
            }

            let tabBar = try XCTUnwrap(findSubview(ofType: TabBarView.self, in: contentView))
            waitUntil {
                contentView.layoutSubtreeIfNeeded()
                tabBar.layoutSubtreeIfNeeded()
                return tabBar.isHidden == false
            }

            let secondTab = try XCTUnwrap(tabViews(in: tabBar).dropFirst().first)
            let secondTitlePoint = try titlePoint(in: secondTab, ancestor: contentView)
            let secondHit = try XCTUnwrap(contentView.hitTest(secondTitlePoint))
            XCTAssertTrue(
                secondHit.isDescendant(of: tabBar) || secondHit === tabBar,
                "select hit=\(secondHit) point=\(NSStringFromPoint(secondTitlePoint)) tabBar=\(NSStringFromRect(tabBar.frame)) secondTab=\(NSStringFromRect(secondTab.frame)) local=\(NSStringFromPoint(tabBar.convert(secondTitlePoint, from: contentView)))"
            )
            try dispatchClick(in: window, rootView: contentView, point: secondTitlePoint)
            XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.activeTabIndex, 1)

            let addButton = try XCTUnwrap(tabBar.subviews.compactMap { $0 as? NSButton }.first)
            let addPoint = center(of: addButton, ancestor: contentView)
            let addHit = try XCTUnwrap(contentView.hitTest(addPoint))
            XCTAssertTrue(
                addHit === addButton || addHit.isDescendant(of: addButton),
                "add hit=\(addHit) point=\(NSStringFromPoint(addPoint)) addButton=\(NSStringFromRect(addButton.frame)) tabBar=\(NSStringFromRect(tabBar.frame)) local=\(NSStringFromPoint(tabBar.convert(addPoint, from: contentView)))"
            )
            try dispatchClick(in: window, rootView: contentView, point: addPoint)
            waitUntil {
                self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count == 3
            }
            XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count, 3)

            let refreshedFirstTab = try XCTUnwrap(tabViews(in: tabBar).first)
            let firstCloseButton = try closeButton(in: refreshedFirstTab)
            firstCloseButton.performClick(nil)
            waitUntil {
                self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count == 2
            }
            XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count, 2)

            let firstTab = try XCTUnwrap(tabViews(in: tabBar).first)
            let renamePoint = try titlePoint(in: firstTab, ancestor: contentView)
            let renameHit = try XCTUnwrap(contentView.hitTest(renamePoint))
            XCTAssertTrue(
                renameHit.isDescendant(of: tabBar) || renameHit === tabBar,
                "rename hit=\(renameHit) point=\(NSStringFromPoint(renamePoint)) tabBar=\(NSStringFromRect(tabBar.frame)) firstTab=\(NSStringFromRect(firstTab.frame)) local=\(NSStringFromPoint(tabBar.convert(renamePoint, from: contentView)))"
            )
            try dispatchDoubleClick(in: window, rootView: contentView, point: renamePoint)

            waitUntil { self.visibleRenameField(in: tabBar) != nil }
            let renameField = try XCTUnwrap(visibleRenameField(in: tabBar))
            waitUntil { self.currentEditor(for: renameField) != nil }
            let editor = try XCTUnwrap(currentEditor(for: renameField))
            XCTAssertTrue(window.firstResponder === editor)
            renameField.stringValue = "Build"
            editor.string = "Build"
            renameField.validateEditing()
            renameField.commitEditing()

            waitUntil {
                self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.first?.title == "Build"
            }
            XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.first?.title, "Build")
        }
    }

    func testTitlebarOpenWorkspaceButtonReceivesPointDispatchedClickFromRealWindow() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let openWorkspaceButton = try XCTUnwrap(
                waitForView(withAccessibilityIdentifier: "titlebar.openWorkspace", in: contentView)
            )

            let openPoint = center(of: openWorkspaceButton, ancestor: contentView)
            let hit = try XCTUnwrap(contentView.hitTest(openPoint))
            XCTAssertTrue(
                hit === openWorkspaceButton || hit.isDescendant(of: openWorkspaceButton),
                "titlebar hit=\(hit) point=\(NSStringFromPoint(openPoint)) button=\(NSStringFromRect(openWorkspaceButton.frame))"
            )

            try dispatchClick(in: window, rootView: contentView, point: openPoint)
            waitUntil {
                self.openerPanel(from: appDelegate)?.isVisible == true
            }

            XCTAssertNil(window.appearance)
            XCTAssertNil(self.openerPanel(from: appDelegate)?.appearance)
        }
    }

    func testToolDrawerSwapReplacesActiveToolContentWithoutClosingDrawer() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }

            appDelegate.openToolInDrawerForTesting("analytics")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "analytics"
            }

            XCTAssertEqual(appDelegate.toolDrawerContentModelForTesting.activeToolTitle, "Usage")
            XCTAssertEqual(appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType, "analytics")
            let initialPaneView = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.activePaneView)
            let initialRevision = appDelegate.toolDrawerContentModelForTesting.contentRevision

            appDelegate.openToolInDrawerForTesting("notifications")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "notifications"
                    && appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType == "notifications"
                    && appDelegate.toolDrawerContentModelForTesting.activeBrowserSession == nil
            }

            XCTAssertTrue(appDelegate.toolDrawerChromeStateForTesting.isPresented)
            XCTAssertEqual(appDelegate.toolDrawerContentModelForTesting.activeToolTitle, "Notifications")
            XCTAssertFalse(initialPaneView === appDelegate.toolDrawerContentModelForTesting.activePaneView)
            XCTAssertGreaterThan(appDelegate.toolDrawerContentModelForTesting.contentRevision, initialRevision)
        }
    }

    func testToolDockAnalyticsButtonReceivesPointDispatchedClickAfterBrowserDrawerOpens() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let toolDockView = try XCTUnwrap(
                waitForView(withAccessibilityIdentifier: "tool-dock.view", in: contentView)
            )
            let browserPoint = try toolDockItemCenter(
                for: "browser",
                in: toolDockView,
                ancestor: contentView,
                workspaceManager: workspaceManager(from: appDelegate)
            )
            let analyticsPoint = try toolDockItemCenter(
                for: "analytics",
                in: toolDockView,
                ancestor: contentView,
                workspaceManager: workspaceManager(from: appDelegate)
            )

            try dispatchClick(in: window, rootView: contentView, point: browserPoint)
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "browser"
            }

            let hit = try XCTUnwrap(contentView.hitTest(analyticsPoint))
            XCTAssertTrue(
                hit.isDescendant(of: toolDockView) || hit === toolDockView,
                "analytics dock hit=\(hit) point=\(NSStringFromPoint(analyticsPoint)) toolDock=\(NSStringFromRect(toolDockView.frame))"
            )

            try dispatchClick(in: window, rootView: contentView, point: analyticsPoint)
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "analytics"
                    && appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType == "analytics"
            }
        }
    }

    func testToolDrawerHidesPaneInlineHeaders() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)

            appDelegate.openToolInDrawerForTesting("notifications")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "notifications"
            }
            XCTAssertNil(
                waitForView(
                    withAccessibilityIdentifier: "pane.notifications.inlineHeader",
                    in: contentView,
                    timeout: 0.1
                )
            )

            appDelegate.openToolInDrawerForTesting("ssh")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "ssh"
            }
            XCTAssertNil(
                waitForView(
                    withAccessibilityIdentifier: "pane.ssh.inlineHeader",
                    in: contentView,
                    timeout: 0.1
                )
            )
        }
    }

    func testResourceDrawerUsesSingleDrawerTitleAndHidesInlineHeader() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)

            appDelegate.openToolInDrawerForTesting("resource_monitor")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "resource_monitor"
                    && appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType == "resource_monitor"
            }

            let drawerTitle = try XCTUnwrap(
                waitForView(withAccessibilityIdentifier: "bottom.drawer.title", in: contentView)
            )
            XCTAssertEqual(drawerTitle.accessibilityLabel(), "Resources")
            XCTAssertNil(
                waitForView(
                    withAccessibilityIdentifier: "pane.resourceMonitor.inlineHeader",
                    in: contentView,
                    timeout: 0.1
                )
            )
            XCTAssertNotNil(
                waitForView(
                    withAccessibilityIdentifier: "pane.resourceMonitor.segmentedControl",
                    in: contentView
                )
            )
        }
    }

    func testResourceDrawerSegmentedControlSwitchesTabsWithoutRemounting() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)

            appDelegate.openToolInDrawerForTesting("resource_monitor")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "resource_monitor"
                    && appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType == "resource_monitor"
            }

            let initialPaneView = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.activePaneView)
            let initialRevision = appDelegate.toolDrawerContentModelForTesting.contentRevision
            let segmentedControl = try XCTUnwrap(
                waitForSegmentedControl(
                    withAccessibilityIdentifier: "pane.resourceMonitor.segmentedControl",
                    in: contentView
                )
            )

            XCTAssertNotNil(
                waitForView(
                    withAccessibilityIdentifier: "pane.resourceMonitor.tab.overview",
                    in: contentView
                )
            )

            XCTAssertTrue(activateSegment(1, in: segmentedControl))
            waitUntil {
                segmentedControl.selectedSegment == 1
                    && self.waitForView(
                        withAccessibilityIdentifier: "pane.resourceMonitor.tab.processes",
                        in: contentView,
                        timeout: 0.05
                    ) != nil
            }

            XCTAssertTrue(activateSegment(2, in: segmentedControl))
            waitUntil {
                segmentedControl.selectedSegment == 2
                    && self.waitForView(
                        withAccessibilityIdentifier: "pane.resourceMonitor.tab.host",
                        in: contentView,
                        timeout: 0.05
                    ) != nil
            }

            XCTAssertTrue(appDelegate.toolDrawerChromeStateForTesting.isPresented)
            XCTAssertTrue(initialPaneView === appDelegate.toolDrawerContentModelForTesting.activePaneView)
            XCTAssertEqual(initialRevision, appDelegate.toolDrawerContentModelForTesting.contentRevision)
        }
    }

    func testToolDrawerVisibleRectInterceptsHitsBeforeContentArea() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let contentArea = try XCTUnwrap(findSubview(ofType: ContentAreaView.self, in: contentView))

            DrawerSizing.setStoredHeight(360)
            appDelegate.openToolInDrawerForTesting("analytics")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "analytics"
            }

            let drawerRect = expectedDrawerRect(
                in: contentArea,
                storedHeight: appDelegate.toolDrawerContentModelForTesting.drawerHeight
            )
            let drawerPoint = contentView.convert(
                NSPoint(x: drawerRect.midX, y: drawerRect.midY),
                from: contentArea
            )
            let hit = try XCTUnwrap(contentView.hitTest(drawerPoint))

            XCTAssertFalse(
                hit === contentArea || hit.isDescendant(of: contentArea),
                "drawer hit leaked into content area: hit=\(hit) point=\(NSStringFromPoint(drawerPoint)) drawerRect=\(NSStringFromRect(drawerRect)) contentArea=\(NSStringFromRect(contentArea.frame))"
            )

            let contentAreaPoint = contentView.convert(
                NSPoint(x: contentArea.bounds.midX, y: 40),
                from: contentArea
            )
            let contentHit = try XCTUnwrap(contentView.hitTest(contentAreaPoint))
            XCTAssertTrue(
                contentHit === contentArea || contentHit.isDescendant(of: contentArea),
                "drawer host unexpectedly blocked content area above the drawer: hit=\(contentHit) point=\(NSStringFromPoint(contentAreaPoint)) drawerRect=\(NSStringFromRect(drawerRect))"
            )
        }
    }

    func testToolDrawerResizeHandleReceivesPointDispatchedDrag() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let contentArea = try XCTUnwrap(findSubview(ofType: ContentAreaView.self, in: contentView))

            appDelegate.openToolInDrawerForTesting("analytics")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "analytics"
            }

            let initialRect = expectedDrawerRect(
                in: contentArea,
                storedHeight: appDelegate.toolDrawerContentModelForTesting.drawerHeight
            )
            let initialHeight = DrawerSizing.resolvedHeight(
                storedHeight: appDelegate.toolDrawerContentModelForTesting.drawerHeight,
                availableHeight: contentArea.bounds.height
            )
            let resizeHandle = try XCTUnwrap(
                waitForView(withAccessibilityIdentifier: "bottom.drawer.resize", in: contentView)
            )
            XCTAssertEqual(
                resizeHandle.frame.height,
                DrawerSizing.resizeHandleHeight,
                accuracy: 0.5
            )
            let startPoint = center(of: resizeHandle, ancestor: contentView)
            let endPoint = contentView.convert(
                NSPoint(x: initialRect.midX, y: max(0, initialRect.minY - 60)),
                from: contentArea
            )
            let startHit = try XCTUnwrap(contentView.hitTest(startPoint))
            XCTAssertTrue(
                startHit === resizeHandle || startHit.isDescendant(of: resizeHandle),
                "resize handle hit=\(startHit) point=\(NSStringFromPoint(startPoint)) handle=\(NSStringFromRect(resizeHandle.frame))"
            )

            try dispatchDrag(in: window, rootView: contentView, start: startPoint, end: endPoint)

            waitUntil {
                let updatedHeight = appDelegate.toolDrawerContentModelForTesting.drawerHeight ?? 0
                return updatedHeight > initialHeight + 20
            }
            let updatedHeight = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.drawerHeight)
            XCTAssertGreaterThan(updatedHeight, initialHeight)
            contentView.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                resizeHandle.frame.height,
                DrawerSizing.resizeHandleHeight,
                accuracy: 0.5
            )
        }
    }

    func testResourceDrawerResizeStripReceivesDragAfterTabSwitch() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            waitUntil { self.workspaceManager(from: appDelegate)?.activeWorkspace != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let contentArea = try XCTUnwrap(findSubview(ofType: ContentAreaView.self, in: contentView))

            DrawerSizing.setStoredHeight(360)
            appDelegate.openToolInDrawerForTesting("resource_monitor")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "resource_monitor"
                    && appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType == "resource_monitor"
            }

            let initialPaneView = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.activePaneView)
            let segmentedControl = try XCTUnwrap(
                waitForSegmentedControl(
                    withAccessibilityIdentifier: "pane.resourceMonitor.segmentedControl",
                    in: contentView
                )
            )
            XCTAssertTrue(activateSegment(1, in: segmentedControl))
            waitUntil {
                segmentedControl.selectedSegment == 1
                    && self.waitForView(
                        withAccessibilityIdentifier: "pane.resourceMonitor.tab.processes",
                        in: contentView,
                        timeout: 0.05
                    ) != nil
            }

            let initialRect = expectedDrawerRect(
                in: contentArea,
                storedHeight: appDelegate.toolDrawerContentModelForTesting.drawerHeight
            )
            let initialHeight = DrawerSizing.resolvedHeight(
                storedHeight: appDelegate.toolDrawerContentModelForTesting.drawerHeight,
                availableHeight: contentArea.bounds.height
            )
            let resizeHandle = try XCTUnwrap(
                waitForView(withAccessibilityIdentifier: "bottom.drawer.resize", in: contentView)
            )
            XCTAssertEqual(
                resizeHandle.frame.height,
                DrawerSizing.resizeHandleHeight,
                accuracy: 0.5
            )
            let startPoint = center(of: resizeHandle, ancestor: contentView)
            let endPoint = contentView.convert(
                NSPoint(x: initialRect.midX, y: max(0, initialRect.minY - 60)),
                from: contentArea
            )

            try dispatchDrag(in: window, rootView: contentView, start: startPoint, end: endPoint)

            waitUntil {
                let updatedHeight = appDelegate.toolDrawerContentModelForTesting.drawerHeight ?? 0
                return updatedHeight > initialHeight + 20
            }
            let updatedHeight = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.drawerHeight)
            XCTAssertGreaterThan(updatedHeight, initialHeight)
            XCTAssertTrue(appDelegate.toolDrawerChromeStateForTesting.isPresented)
            XCTAssertTrue(initialPaneView === appDelegate.toolDrawerContentModelForTesting.activePaneView)
            contentView.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                resizeHandle.frame.height,
                DrawerSizing.resizeHandleHeight,
                accuracy: 0.5
            )
        }
    }

    func testToolDrawerSameToolStillTogglesClosed() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }

            appDelegate.openToolInDrawerForTesting("analytics")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "analytics"
            }

            appDelegate.openToolInDrawerForTesting("analytics")
            waitUntil { appDelegate.toolDrawerChromeStateForTesting.isPresented == false }

            XCTAssertFalse(appDelegate.toolDrawerChromeStateForTesting.isPresented)
        }
    }

    func testToolDrawerBrowserSwapPreservesDrawerAndHeight() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }

            appDelegate.openToolInDrawerForTesting("browser")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "browser"
                    && appDelegate.toolDrawerContentModelForTesting.activeBrowserSession != nil
            }

            let browserSession = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.activeBrowserSession)
            browserSession.setDrawerHeight(480)
            let initialRevision = appDelegate.toolDrawerContentModelForTesting.contentRevision

            appDelegate.openToolInDrawerForTesting("analytics")
            waitUntil {
                appDelegate.toolDrawerChromeStateForTesting.isPresented
                    && appDelegate.toolDrawerContentModelForTesting.activeToolID == "analytics"
                    && appDelegate.toolDrawerContentModelForTesting.activeBrowserSession == nil
                    && appDelegate.toolDrawerContentModelForTesting.activePaneView?.paneType == "analytics"
            }

            XCTAssertTrue(appDelegate.toolDrawerChromeStateForTesting.isPresented)
            XCTAssertEqual(appDelegate.toolDrawerContentModelForTesting.activeToolTitle, "Usage")
            let preservedHeight = try XCTUnwrap(appDelegate.toolDrawerContentModelForTesting.drawerHeight)
            XCTAssertEqual(preservedHeight, 480, accuracy: 0.5)
            XCTAssertGreaterThan(appDelegate.toolDrawerContentModelForTesting.contentRevision, initialRevision)
        }
    }

    private func tabViews(in tabBar: TabBarView) -> [NSView] {
        tabBar.subviews.filter { !($0 is NSButton) }
    }

    private func launchAppDelegate() -> AppDelegate {
        if let sharedAppDelegate = Self.sharedAppDelegate {
            launchedAppDelegate = sharedAppDelegate
            NSApp.delegate = sharedAppDelegate
            sharedAppDelegate.resetForIntegrationTesting()
            return sharedAppDelegate
        }

        let appDelegate = AppDelegate()
        Self.sharedAppDelegate = appDelegate
        launchedAppDelegate = appDelegate
        NSApp.delegate = appDelegate
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        appDelegate.resetForIntegrationTesting()
        return appDelegate
    }

    private func titleLabel(in tabView: NSView) throws -> NSTextField {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSTextField }.first)
    }

    private func closeButton(in tabView: NSView) throws -> NSButton {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func center(of view: NSView, ancestor: NSView) -> NSPoint {
        ancestor.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    private func titlePoint(in tabView: NSView, ancestor: NSView) throws -> NSPoint {
        center(of: try titleLabel(in: tabView), ancestor: ancestor)
    }

    private func dispatchClick(
        in window: NSWindow,
        rootView: NSView,
        point: NSPoint,
        clickCount: Int = 1
    ) throws {
        let location = rootView.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
        window.sendEvent(down)

        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
        window.sendEvent(up)
    }

    private func dispatchDoubleClick(
        in window: NSWindow,
        rootView: NSView,
        point: NSPoint
    ) throws {
        try dispatchClick(in: window, rootView: rootView, point: point, clickCount: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        try dispatchClick(in: window, rootView: rootView, point: point, clickCount: 2)
    }

    private func dispatchDrag(
        in window: NSWindow,
        rootView: NSView,
        start: NSPoint,
        end: NSPoint
    ) throws {
        let startLocation = rootView.convert(start, to: nil)
        let endLocation = rootView.convert(end, to: nil)

        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startLocation,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        window.sendEvent(down)

        let dragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endLocation,
            modifierFlags: [],
            timestamp: 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        window.sendEvent(dragged)

        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endLocation,
            modifierFlags: [],
            timestamp: 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0
        ))

        let targetView = try XCTUnwrap(rootView.hitTest(start))
        targetView.mouseDown(with: down)
        targetView.mouseDragged(with: dragged)
        targetView.mouseUp(with: up)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func withUITestLightweightEnvironment(
        _ body: () throws -> Void
    ) throws {
        let savedUITesting = ProcessInfo.processInfo.environment["PNEVMA_UI_TESTING"]
        let savedLightweight = ProcessInfo.processInfo.environment["PNEVMA_UI_TEST_LIGHTWEIGHT_MODE"]
        setenv("PNEVMA_UI_TESTING", "1", 1)
        setenv("PNEVMA_UI_TEST_LIGHTWEIGHT_MODE", "1", 1)
        defer {
            restoreEnvironmentVariable("PNEVMA_UI_TESTING", to: savedUITesting)
            restoreEnvironmentVariable("PNEVMA_UI_TEST_LIGHTWEIGHT_MODE", to: savedLightweight)
        }
        try body()
    }

    private func restoreEnvironmentVariable(_ name: String, to value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    private func findSubview<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let root = root as? T {
            return root
        }
        for subview in root.subviews {
            if let match = findSubview(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func waitForView(
        withAccessibilityIdentifier identifier: String,
        in root: NSView,
        timeout: TimeInterval = 2
    ) -> NSView? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let view = findView(withAccessibilityIdentifier: identifier, in: root) {
                return view
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return findView(withAccessibilityIdentifier: identifier, in: root)
    }

    private func findView(withAccessibilityIdentifier identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = findView(withAccessibilityIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func visibleRenameField(in root: NSView) -> TabRenameField? {
        if let field = root as? TabRenameField, field.isHidden == false {
            return field
        }
        for subview in root.subviews {
            if let field = visibleRenameField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func currentEditor(for field: TabRenameField) -> NSTextView? {
        field.currentEditor() as? NSTextView
    }

    private func workspaceManager(from appDelegate: AppDelegate) -> WorkspaceManager? {
        Mirror(reflecting: appDelegate)
            .children
            .first(where: { $0.label == "workspaceManager" })?
            .value as? WorkspaceManager
    }

    private func openerPanel(from appDelegate: AppDelegate) -> NSPanel? {
        Mirror(reflecting: appDelegate)
            .children
            .first(where: { $0.label == "openerPanel" })?
            .value as? NSPanel
    }

    private func toolDockItemCenter(
        for toolID: String,
        in toolDockView: NSView,
        ancestor: NSView,
        workspaceManager: WorkspaceManager?
    ) throws -> NSPoint {
        let tools = sidebarTools(for: workspaceManager?.activeWorkspace)
        guard let index = tools.firstIndex(where: { $0.id == toolID }) else {
            throw XCTSkip("Tool \(toolID) is not available in the active workspace")
        }

        let dockButtonWidth: CGFloat = 50
        let dockButtonSpacing: CGFloat = 8
        let innerHorizontalPadding: CGFloat = 8
        let outerHorizontalPadding: CGFloat = 18
        let contentWidth = CGFloat(tools.count) * dockButtonWidth
            + CGFloat(max(tools.count - 1, 0)) * dockButtonSpacing
            + innerHorizontalPadding * 2
        let centeredLeading = outerHorizontalPadding
            + max(0, (toolDockView.bounds.width - outerHorizontalPadding * 2 - contentWidth) / 2)
            + innerHorizontalPadding
        let localPoint = NSPoint(
            x: centeredLeading + CGFloat(index) * (dockButtonWidth + dockButtonSpacing) + dockButtonWidth / 2,
            y: toolDockView.bounds.midY
        )
        return ancestor.convert(localPoint, from: toolDockView)
    }

    private func expectedDrawerRect(in contentArea: ContentAreaView, storedHeight: CGFloat?) -> CGRect {
        let availableHeight = contentArea.bounds.height
        let height = DrawerSizing.resolvedHeight(
            storedHeight: storedHeight,
            availableHeight: availableHeight
        )
        return CGRect(
            x: 0,
            y: max(0, availableHeight - height),
            width: contentArea.bounds.width,
            height: height
        )
    }

    private func waitForSegmentedControl(
        withAccessibilityIdentifier identifier: String,
        in root: NSView,
        timeout: TimeInterval = 2
    ) -> NSSegmentedControl? {
        if let view = waitForView(withAccessibilityIdentifier: identifier, in: root, timeout: timeout) {
            if let control = view as? NSSegmentedControl {
                return control
            }
            if let control = findSubview(ofType: NSSegmentedControl.self, in: view) {
                return control
            }
        }
        return findSubview(ofType: NSSegmentedControl.self, in: root)
    }

    @discardableResult
    private func activateSegment(_ segment: Int, in control: NSSegmentedControl) -> Bool {
        guard segment >= 0, segment < control.segmentCount else { return false }
        guard control.isEnabled(forSegment: segment) else { return false }
        guard let action = control.action else { return false }

        control.selectedSegment = segment
        let didSendAction = control.sendAction(action, to: control.target)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return didSendAction
    }

    nonisolated private static func syncOnMainActor(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
            semaphore.signal()
        }
        semaphore.wait()
    }
}
