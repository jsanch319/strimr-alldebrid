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
