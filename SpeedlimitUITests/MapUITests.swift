import XCTest

final class MapUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(); app.launchArguments = ["--ui-testing","--fixture-routes"]; app.launch()
    }
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }
    func testPublicCCTVLivePlaybackPauseBackgroundAndClose() throws {
        guard ProcessInfo.processInfo.environment["SPEEDLIMIT_LIVE_CCTV_TESTS"] == "1" else {
            throw XCTSkip("Opt-in real public CCTV network check; independent of fixture UI tests")
        }
        app.terminate()
        app.launchArguments = ["--ui-testing","--live-cctv-details"]
        app.launch()
        let status = app.staticTexts["cctv.status"], image = app.images["cctv.image"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        expectation(for:NSPredicate(format:"label == 'LIVE'"),evaluatedWith:status)
        waitForExpectations(timeout:25)
        expectation(for:NSPredicate { object,_ in
            guard let text = (object as? XCUIElement)?.value as? String,
                  let count = Int(text.split(separator:" ").first ?? "") else { return false }
            return count >= 4
        },evaluatedWith:status)
        waitForExpectations(timeout:10)
        XCTAssertTrue(image.exists)
        print("REAL_CCTV_VIDEO \(status.value ?? "no frame count")")
        let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.name = "Actual provincial CCTV video, multiple received frames"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["cctv.playback"].tap()
        XCTAssertEqual(status.label,"PAUSED"); XCTAssertTrue(image.exists)
        let count = status.value as? String
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:5))
        app.activate()
        XCTAssertTrue(status.waitForExistence(timeout:8))
        XCTAssertEqual(status.label,"PAUSED"); XCTAssertFalse(image.exists)
        XCTAssertEqual(status.value as? String,count)
        XCTAssertFalse(app.progressIndicators["cctv.loading"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:8))
    }
    func testPublicCCTVPlayingStopsWhenBackgroundedAndWaitsBeforeReconnect() throws {
        guard ProcessInfo.processInfo.environment["SPEEDLIMIT_LIVE_CCTV_TESTS"] == "1" else {
            throw XCTSkip("Opt-in real public CCTV background check")
        }
        app.terminate(); app.launchArguments = ["--ui-testing","--live-cctv-details"]; app.launch()
        let status = app.staticTexts["cctv.status"], image = app.images["cctv.image"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        expectation(for:NSPredicate(format:"label == 'LIVE'"),evaluatedWith:status); waitForExpectations(timeout:25)
        XCTAssertTrue(image.exists)
        XCUIDevice.shared.press(.home); XCTAssertTrue(app.wait(for:.runningBackground,timeout:5))
        app.activate(); XCTAssertTrue(status.waitForExistence(timeout:8))
        XCTAssertFalse(image.exists); XCTAssertEqual(status.label,"CONNECTING")
        XCTAssertFalse(app.progressIndicators["cctv.loading"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH 'Reconnect in '")).firstMatch.exists)
        app.buttons["cctv.playback"].tap(); XCTAssertEqual(status.label,"PAUSED")
        app.buttons["Close"].tap(); XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:8))
    }
    func testMapHasTopSearchAndNoPermanentBottomPanel() {
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:10))
        XCTAssertFalse(app.otherElements["road.details"].exists)
        XCTAssertFalse(app.buttons["route.start"].exists)
        app.buttons["map.settings"].tap()
        XCTAssertTrue(app.navigationBars["Layers & Settings"].waitForExistence(timeout:5))
        XCTAssertTrue(app.switches["Traffic CCTV"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["search.field"].exists)
    }
    func testMapKeyExplainsGroupsAndOfflineSpeedSearchPreservesCurveConditions() {
        let key = app.buttons["map.layerLegend"]
        XCTAssertTrue(key.waitForExistence(timeout:10)); key.tap()
        XCTAssertTrue(app.navigationBars["Map Key"].waitForExistence(timeout:5))
        let references = app.buttons["map.speedReferences"]
        if !references.isHittable { app.swipeUp() }
        XCTAssertTrue(references.isHittable); references.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText("台64")
        app.keyboards.buttons["search"].tap()
        let conditional = app.staticTexts["直線段：70、彎道段：60"]
        XCTAssertTrue(conditional.waitForExistence(timeout:5))
        conditional.tap()
        XCTAssertTrue(app.staticTexts["不包含民生陸橋側車道"].waitForExistence(timeout:5))
        let missingDate = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","Not supplied")).firstMatch
        if !missingDate.exists { app.swipeUp() }
        XCTAssertTrue(missingDate.exists)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Official Taiwan 64 curve and side-road exceptions"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["台64"].buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.navigationBars["Speed Limits"].waitForExistence(timeout:5))
        app.buttons["speed.close"].tap()
        XCTAssertTrue(key.waitForExistence(timeout:5))
        XCTAssertTrue(app.textFields["search.field"].isHittable)
    }
    func testGovernmentUpdateControlsRemainUsableAndRestorePreference() {
        app.buttons["map.settings"].tap()
        let automatic = app.switches["data.autoUpdate"]
        for _ in 0..<8 {
            if automatic.exists && automatic.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(automatic.isHittable)
        let previous = automatic.value as? String
        automatic.coordinate(withNormalizedOffset:.init(dx:0.9,dy:0.5)).tap()
        XCTAssertNotEqual(automatic.value as? String,previous)
        automatic.coordinate(withNormalizedOffset:.init(dx:0.9,dy:0.5)).tap()
        XCTAssertEqual(automatic.value as? String,previous)
        let check = app.buttons["data.checkUpdates"]
        XCTAssertTrue(check.exists); XCTAssertTrue(check.isEnabled)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:5))
    }
    func testMixedLayersIncludeCCTVAndSectionCorridors() {
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout:10))
        let legend = app.buttons["map.layerLegend"]
        XCTAssertTrue(legend.waitForExistence(timeout:10))
        let loaded = NSPredicate(format:"value CONTAINS 'CCTV markers' AND NOT value BEGINSWITH '0 '")
        expectation(for:loaded,evaluatedWith:legend)
        waitForExpectations(timeout:10)
        XCTAssertFalse((legend.value as? String ?? "").contains(", 0 section corridors"))
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "CCTV layer and dashed blue sections"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["map.settings"].tap()
        let cctv = app.switches["Traffic CCTV"]
        XCTAssertTrue(cctv.exists)
        if cctv.value as? String == "1" { cctv.coordinate(withNormalizedOffset:.init(dx:0.9,dy:0.5)).tap() }
        XCTAssertEqual(cctv.value as? String,"0")
        app.buttons["Done"].tap()
        expectation(for:NSPredicate(format:"value BEGINSWITH '0 CCTV markers'"),evaluatedWith:legend)
        waitForExpectations(timeout:10)
        // Restore this independently persisted layer for subsequent test launches.
        app.buttons["map.settings"].tap()
        app.switches["Traffic CCTV"].coordinate(withNormalizedOffset:.init(dx:0.9,dy:0.5)).tap()
        app.buttons["Done"].tap()
    }
    func pickPin() {
        XCTAssertTrue(app.buttons["map.pick"].waitForExistence(timeout:10))
        app.buttons["map.pick"].tap()
        app.coordinate(withNormalizedOffset:.init(dx:0.42,dy:0.54)).tap()
    }
    func testPinRouteStartsAndEndsInsideApp() {
        pickPin()
        XCTAssertTrue(app.buttons["route.start"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["route.start"].isEnabled)
        app.buttons["route.start"].tap()
        let end = app.buttons["navigation.end"]
        if !end.waitForExistence(timeout:8) {
            print(app.debugDescription)
            let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertTrue(end.exists)
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertFalse(app.buttons["route.start"].exists)
        app.buttons["navigation.end"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["route.start"].exists)
    }
    func testBackgroundReturnRestoresMapAndKeepsNavigation() {
        pickPin(); XCTAssertTrue(app.buttons["route.start"].waitForExistence(timeout:10))
        app.buttons["route.start"].tap()
        XCTAssertTrue(app.buttons["navigation.end"].waitForExistence(timeout:8))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:5))
        app.activate()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["navigation.end"].waitForExistence(timeout:8))
        XCTAssertTrue(app.maps.firstMatch.isHittable)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Restored map and retained navigation after background cleanup"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["navigation.end"].tap()
        XCTAssertTrue(app.buttons["map.layerLegend"].waitForExistence(timeout:10))
    }
    func testCancelRouteDoesNotReturn() {
        pickPin(); XCTAssertTrue(app.buttons["route.cancel"].waitForExistence(timeout:5))
        app.buttons["route.cancel"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["route.start"].waitForExistence(timeout:2))
    }
    func testSearchClearsReliably() {
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap(); field.typeText("Taipei")
        app.buttons["Clear search"].tap()
        XCTAssertEqual(field.value as? String,"Search Apple Maps")
    }
    func testSearchFocusKeepsKeyboardResponsiveAndRestoresMapLegend() {
        let field = app.textFields["search.field"], legend = app.buttons["map.layerLegend"]
        XCTAssertTrue(legend.waitForExistence(timeout:10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        XCTAssertFalse(legend.exists)
        XCTAssertTrue(app.buttons["search.pickMap"].exists)
        field.typeText("Taipei")
        app.buttons["Clear search"].tap()
        XCTAssertEqual(field.value as? String,"Search Apple Maps")
        app.keyboards.buttons["search"].tap()
        XCTAssertTrue(legend.waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["map.pick"].isHittable)
    }
    func testSearchCanSwitchDirectlyToMapDestinationPicking() {
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap()
        let pick = app.buttons["search.pickMap"], actionY = pick.frame.midY
        field.typeText("Taipei")
        XCTAssertEqual(pick.frame.midY,actionY,accuracy:1,"Autocomplete must not move the map-picking action")
        pick.tap()
        expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.keyboards.firstMatch)
        waitForExpectations(timeout:5)
        XCTAssertTrue(app.maps.firstMatch.isHittable)
        app.coordinate(withNormalizedOffset:.init(dx:0.42,dy:0.54)).tap()
        XCTAssertTrue(app.buttons["route.start"].waitForExistence(timeout:10))
        app.buttons["route.cancel"].tap()
    }
    func testSearchEntryPerformanceWithLoadedCameraMap() {
        app.terminate(); app.launchArguments.append("--profile-search"); app.launch()
        XCTAssertTrue(app.buttons["map.layerLegend"].waitForExistence(timeout:10))
        let options = XCTMeasureOptions(); options.iterationCount = 2
        measure(metrics:[XCTClockMetric(),XCTCPUMetric(application:app),XCTMemoryMetric(application:app)],options:options) {
            let field = app.textFields["search.field"]
            field.tap()
            if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
            field.typeText("Taipei 101")
            XCTAssertTrue((field.value as? String ?? "").contains("Taipei 101"))
            app.buttons["search.cancel"].tap()
        }
    }
    func testLandscapeSearchAndRouteControlsStayReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:10))
        XCTAssertTrue(app.textFields["search.field"].isHittable)
        pickPin()
        let start = app.buttons["route.start"]
        XCTAssertTrue(start.waitForExistence(timeout:10))
        XCTAssertFalse(app.navigationBars["Camera Details"].exists)
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(app.buttons["route.cancel"].isHittable)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Landscape route selection"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["route.cancel"].tap()
    }
    func testRepeatedMapPanningPerformance() {
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout:10))
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics:[XCTClockMetric(),XCTCPUMetric(application:app),XCTMemoryMetric(application:app)],options:options) {
            let start = app.coordinate(withNormalizedOffset:.init(dx:0.3,dy:0.5))
            let end = app.coordinate(withNormalizedOffset:.init(dx:0.7,dy:0.5))
            start.press(forDuration:0.05,thenDragTo:end)
            end.press(forDuration:0.05,thenDragTo:start)
        }
        XCTAssertTrue(app.textFields["search.field"].exists)
    }
    func testStartupFailureRecoversWithoutBlockingMap() {
        app.terminate(); app.launchArguments += ["--fixture-load-failure"]; app.launch()
        let retry = app.buttons["data.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout:10))
        XCTAssertTrue(app.textFields["search.field"].isHittable)
        XCTAssertTrue(app.buttons["map.pick"].isHittable)
        retry.tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout:8))
        XCTAssertFalse(app.otherElements["data.loading"].exists)
        pickPin(); XCTAssertTrue(app.buttons["route.start"].waitForExistence(timeout:10))
        XCTAssertEqual(app.state,.runningForeground)
    }
    func testDestinationCanBePickedAndCancelledWithoutGPS() {
        app.terminate(); app.launchArguments += ["--fixture-no-gps"]; app.launch()
        pickPin()
        let waiting = app.staticTexts["route.waitingGPS"]
        if !waiting.waitForExistence(timeout:5) { print(app.debugDescription) }
        XCTAssertTrue(waiting.exists)
        XCTAssertTrue(app.textFields["search.field"].isHittable)
        XCTAssertFalse(app.buttons["route.start"].exists)
        app.buttons["route.cancel"].tap()
        XCTAssertFalse(app.buttons["route.cancel"].waitForExistence(timeout:2))
        XCTAssertTrue(app.buttons["map.pick"].isHittable)
    }
    func testAlternateRouteSwitchingRemainsResponsive() {
        pickPin(); XCTAssertTrue(app.buttons["route.start"].waitForExistence(timeout:10))
        let alternate = app.buttons["Route Test route B, 7 minutes"]
        XCTAssertTrue(alternate.exists); alternate.tap()
        app.buttons["Route Test route A, 5 minutes"].tap(); alternate.tap()
        XCTAssertTrue(app.buttons["route.start"].isHittable)
        app.buttons["route.start"].tap()
        XCTAssertTrue(app.buttons["navigation.end"].waitForExistence(timeout:8))
        XCTAssertEqual(app.state,.runningForeground)
    }
    func testGPSOutageHidesOldTurnDistanceAndRecoveryKeepsRoute() {
        app.terminate(); app.launchArguments += ["--fixture-gps-outage"]; app.launch()
        pickPin(); XCTAssertTrue(app.buttons["route.start"].waitForExistence(timeout:10))
        app.buttons["route.start"].tap()
        let maneuver = app.staticTexts["navigation.maneuver"]
        XCTAssertTrue(maneuver.waitForExistence(timeout:5))
        let delayed = app.staticTexts["gps.delayed"]
        XCTAssertTrue(delayed.waitForExistence(timeout:5))
        XCTAssertEqual(maneuver.label,"Waiting for location")
        XCTAssertTrue(app.buttons["navigation.end"].exists)
        let outage = XCTAttachment(screenshot:app.screenshot()); outage.name = "GPS outage - retained route and paused guidance"
        outage.lifetime = .keepAlways; add(outage)
        app.buttons["Retry"].tap()
        XCTAssertTrue(delayed.waitForNonExistence(timeout:5))
        XCTAssertNotEqual(maneuver.label,"Waiting for location")
        XCTAssertTrue(app.buttons["navigation.end"].exists)
        app.buttons["navigation.end"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout:5))
    }
}
