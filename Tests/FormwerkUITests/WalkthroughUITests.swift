import XCTest

/// Walks through the main flow on iPad and saves screenshots for review:
/// new design → sketch a rectangle → done → extrude → fillet → print sheet.
final class WalkthroughUITests: XCTestCase {
    var app: XCUIApplication!
    var shots = 0
    let outDir = ProcessInfo.processInfo.environment["FORMWERK_SHOTS"] ?? NSTemporaryDirectory()

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-welcomeSeen", "YES", "-AppleLanguages", ProcessInfo.processInfo.environment["FORMWERK_LANG"].map { "(\($0))" } ?? "(en)"]
        app.launch()
    }

    func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        shots += 1
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "%02d-%@.png", shots, name))
        try? data.write(to: url)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testMainFlow() throws {
        sleep(2)
        shot("launch")
        // The document browser: create a new design.
        let create = app.buttons["New Design"].firstMatch
        if create.waitForExistence(timeout: 8) { create.tap() }
        sleep(4)
        shot("editor-empty")

        let canvas = app.windows.firstMatch
        let w = canvas.frame.width, h = canvas.frame.height
        func tap(_ x: CGFloat, _ y: CGFloat) {
            canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
        }

        // Sketch
        app.buttons["Sketch"].firstMatch.tap()
        sleep(2)
        app.buttons["Rectangle"].firstMatch.tap()
        tap(w * 0.38, h * 0.40)
        tap(w * 0.60, h * 0.62)
        sleep(1)
        shot("sketch-rectangle")
        app.buttons["Circle"].firstMatch.tap()
        tap(w * 0.49, h * 0.51)
        tap(w * 0.53, h * 0.51)
        sleep(1)
        shot("sketch-circle")
        app.buttons["Done"].firstMatch.tap()
        sleep(2)
        shot("sketch-done")

        // Extrude the selected area
        let extrude = app.buttons["Extrude"].firstMatch
        if extrude.waitForExistence(timeout: 3) { extrude.tap() }
        sleep(2)
        shot("extrude-tool")
        app.buttons["Done"].firstMatch.tap()
        sleep(2)
        shot("extruded")

        // Select the top face, then fillet its edges
        tap(w * 0.5, h * 0.45)
        sleep(1)
        shot("face-selected")
        let round = app.buttons["Round edges"].firstMatch
        if round.waitForExistence(timeout: 3) { round.tap() }
        sleep(2)
        shot("fillet-tool")
        app.buttons["Done"].firstMatch.tap()
        sleep(2)

        // Print sheet
        app.buttons["Print"].firstMatch.tap()
        sleep(3)
        shot("print")
    }

    func testTemplate() throws {
        sleep(2)
        let t = app.buttons["Wall bracket"].firstMatch
        if t.waitForExistence(timeout: 8) { t.tap() }
        sleep(5)
        shot("template-bracket")
    }
}
