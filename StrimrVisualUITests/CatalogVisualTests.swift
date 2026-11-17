import XCTest

/// Exercises production SwiftUI catalog views with an explicitly labeled, credential-free transport.
/// These tests do not claim to validate live Simkl/AllDebrid operations or actual video playback.
@MainActor
final class CatalogVisualTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CatalogVisualTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "catalog-fixture", withExtension: "json"))
        app.launchEnvironment["STRIMR_VISUAL_FIXTURES"] = try String(contentsOf: url, encoding: .utf8)
        app.launch()
        XCTAssertTrue(app.staticTexts["visual.fixture-label"].waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }

    override func tearDownWithError() throws {
        if let app {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "end-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func capture(_ name: String) {
        // Let artwork decoding and the existing 500 ms transition settle before the capture.
        Thread.sleep(forTimeInterval: 3)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ title: String) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        button.tap()
    }

    private func card(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "catalog.card." + id).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, limit: Int = 8) {
        for _ in 0 ..< limit {
            if element.exists, element.isHittable {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func assertLoadedBackdrop() {
        let state = app.descendants(matching: .any).matching(identifier: "visual.backdrop").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 20), app.debugDescription)
        let loaded = NSPredicate(format: "value != %@", "none")
        expectation(for: loaded, evaluatedWith: state)
        waitForExpectations(timeout: 40)
    }

    func testHomeContinueWatchingAndScrolling() {
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 30))
        assertLoadedBackdrop()
        capture("01-Home")
        scrollTo(card("movie:693134"))
        XCTAssertTrue(card("tv:95396:s1:e2").exists, app.debugDescription)
        capture("02-Continue-Watching")
        let services = app.staticTexts["Streaming Services"].firstMatch
        scrollTo(services)
        capture("03-Streaming-Services")
        let netflix = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@",
            "Netflix, streaming movies and series",
        )).firstMatch
        scrollTo(netflix)
        netflix.tap()
        XCTAssertTrue(app.navigationBars["Netflix"].waitForExistence(timeout: 15), app.debugDescription)
        let provider = app.descendants(matching: .any).matching(identifier: "catalog.provider.content").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 15))
        let movie = provider.descendants(matching: .any).matching(identifier: "catalog.card.movie:693134").firstMatch
        let show = provider.descendants(matching: .any).matching(identifier: "catalog.card.tv:95396").firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 20))
        provider.segmentedControls.buttons["TV Shows"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 20))
        XCTAssertFalse(movie.exists)
        show.tap()
        XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["catalog.detail.title"].label, "Severance")
        app.navigationBars.buttons["Netflix"].tap()
        app.buttons["Close"].tap()
        app.swipeUp()
        capture("04-Home-Scrolled")
    }

    func testAutoPlayUsesLoadingEntryAndKeepsExplicitManualSelector() {
        tab("Movies")
        let dune = card("movie:693134")
        XCTAssertTrue(dune.waitForExistence(timeout: 25))
        dune.tap()
        let play = app.buttons["catalog.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()
        // No live credentials: verify the playback entry/error path, never a fabricated playable source.
        XCTAssertTrue(app.navigationBars["Play"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Select Source"].exists)
        capture("15-Auto-Play-Entry-No-Credentials")
        app.buttons["Close"].tap()
        let manual = app.buttons["Select Source"]
        XCTAssertTrue(manual.waitForExistence(timeout: 15))
        manual.tap()
        XCTAssertTrue(app.navigationBars["Select Source"].waitForExistence(timeout: 20))
        capture("16-Manual-Source-Entry-No-Credentials")
    }

    func testHorizontalSwipePaginationWithoutArrows() {
        app.terminate()
        app.launchEnvironment["STRIMR_VISUAL_PAGINATION"] = "1"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 45))
        tab("Movies")
        let row = app.otherElements["catalog.row.Trending Movies"]
        XCTAssertTrue(row.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(row.buttons["poster.rail.next"].exists)
        XCTAssertFalse(row.buttons["poster.rail.previous"].exists)
        XCTAssertFalse(row.buttons["Next posters"].exists)
        XCTAssertFalse(row.buttons["Previous posters"].exists)
        let original = row.descendants(matching: .any).matching(identifier: "catalog.card.movie:693134").firstMatch
        XCTAssertTrue(original.exists)
        let otherRow = app.otherElements["catalog.row.Popular Movies"]
        let otherOriginal = otherRow.descendants(matching: .any).matching(identifier: "catalog.card.movie:693134")
            .firstMatch
        XCTAssertTrue(otherOriginal.exists)
        let otherX = otherOriginal.frame.minX
        capture("17-Swipe-Pagination-Start-No-Arrows")
        row.swipeLeft()
        let appended = row.descendants(matching: .any).matching(identifier: "catalog.card.movie:157336").firstMatch
        XCTAssertTrue(appended.waitForExistence(timeout: 25), app.debugDescription)
        row.swipeLeft()
        XCTAssertTrue(appended.isHittable, row.debugDescription)
        XCTAssertEqual(otherOriginal.frame.minX, otherX, accuracy: 1)
        capture("18-Swipe-Pagination-Appended-No-Arrows")
        row.swipeRight()
        XCTAssertTrue(original.isHittable, row.debugDescription)
        XCTAssertEqual(otherOriginal.frame.minX, otherX, accuracy: 1)
        capture("19-Swipe-Pagination-Returned-No-Arrows")
        row.swipeLeft()
        XCTAssertTrue(appended.isHittable, row.debugDescription)
    }

    func testMoviesAndMovieDetails() {
        tab("Movies")
        XCTAssertTrue(app.staticTexts["Trending Movies"].waitForExistence(timeout: 25))
        assertLoadedBackdrop()
        capture("05-Movies")
        let dune = card("movie:693134")
        XCTAssertTrue(dune.waitForExistence(timeout: 20), app.debugDescription)
        dune.tap()
        XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["catalog.detail.title"].label, "Dune: Part Two")
        XCTAssertTrue(app.buttons["catalog.detail.play"].exists)
        assertLoadedBackdrop()
        capture("06-Movie-Details")
        app.swipeUp()
        capture("07-Movie-Details-Scrolled")
        // Switching away and back retains the native Movies navigation stack.
        tab("TV Shows")
        tab("Movies")
        XCTAssertTrue(app.staticTexts["catalog.detail.title"].exists)
    }

    func testTVShowsAndEpisodes() {
        tab("TV Shows")
        XCTAssertTrue(app.staticTexts["Trending TV Shows"].waitForExistence(timeout: 25))
        assertLoadedBackdrop()
        capture("08-TV-Shows")
        card("tv:95396").tap()
        XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["catalog.detail.title"].label, "Severance")
        assertLoadedBackdrop()
        capture("09-TV-Details")
        let episode = app.staticTexts["1. Episode 1 · visual test fixture"].firstMatch
        scrollTo(episode)
        capture("10-TV-Episodes")
        // Scroll the existing UI; do not resize cards or change production layout to fit the capture.
        let section = app.staticTexts["Seasons and Episodes"].firstMatch
        let targetTop = max(180, app.navigationBars.firstMatch.frame.maxY + 60)
        let distance = max(0, section.frame.minY - targetTop)
        if distance > 1 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = start.withOffset(CGVector(dx: 0, dy: -min(distance, app.frame.height * 0.5)))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        for number in 1 ... 3 {
            XCTAssertTrue(
                app.staticTexts["\(number). Episode \(number) · visual test fixture"].firstMatch.isHittable,
                app.debugDescription,
            )
        }
        XCTAssertTrue(
            app.buttons.matching(identifier: "Play Episode").element(boundBy: 1).isHittable,
            app.debugDescription,
        )
        capture("20-TV-Three-Episodes")
    }

    func testGenreDiscoveryAndBackNavigation() {
        for (tabName, titleID, expectedTitle, kindName, kind) in [
            ("Movies", "movie:693134", "Dune: Part Two", "Movies", "movie"),
            ("TV Shows", "tv:95396", "Severance", "TV Shows", "tv"),
        ] {
            tab(tabName)
            let title = card(titleID)
            XCTAssertTrue(title.waitForExistence(timeout: 25), app.debugDescription)
            title.tap()
            XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 20))
            let genre = app.buttons["catalog.genre.\(kind).1"]
            scrollTo(genre)
            genre.tap()
            XCTAssertTrue(app.staticTexts["catalog.genre.kind"].waitForExistence(timeout: 20))
            XCTAssertEqual(app.staticTexts["catalog.genre.kind"].label, kindName)
            let row = app.descendants(matching: .any).matching(identifier: "catalog.row.Popular").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 25), app.debugDescription)
            XCTAssertTrue(card(titleID).waitForExistence(timeout: 20))
            XCTAssertFalse(card(kind == "movie" ? "tv:95396" : "movie:693134").exists)
            assertLoadedBackdrop()
            capture("21-Genre-\(kind)")
            card(titleID).tap()
            XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["catalog.detail.play"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.staticTexts["catalog.genre.kind"].waitForExistence(timeout: 15))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.staticTexts["catalog.detail.title"].label, expectedTitle)
        }
    }

    func testSearchAndDetails() {
        tab("Search")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), app.debugDescription)
        search.tap()
        search.typeText("Dune")
        let dune = card("movie:693134")
        XCTAssertTrue(dune.waitForExistence(timeout: 25), app.debugDescription)
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        assertLoadedBackdrop()
        capture("11-Search")
        dune.tap()
        XCTAssertTrue(app.staticTexts["catalog.detail.title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["catalog.detail.title"].label, "Dune: Part Two")
    }

    func testMyListAndSettings() {
        tab("More")
        app.buttons["My List"].tap()
        XCTAssertTrue(card("movie:1061474").waitForExistence(timeout: 25), app.debugDescription)
        assertLoadedBackdrop()
        capture("12-My-List")
        app.segmentedControls.buttons["Movies"].tap()
        XCTAssertFalse(card("tv:83867").exists)
        capture("13-My-List-Movies")
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "visual.backdrop").firstMatch.exists)
        capture("14-Settings")
    }
}
