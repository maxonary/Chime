import XCTest

final class BubbleInteractionTests: XCTestCase {
  @MainActor
  private func openBubble() -> XCUIApplication {
    let app = XCUIApplication()
    // Override the configuration for this process: no microphone, credentials,
    // or external service is needed to verify that a touch reaches Start.
    app.launchArguments = ["--preview-memory", "-appSettings", "ui-test-unconfigured"]
    app.launch()
    let back = app.buttons["Back to the bubble"]
    if back.waitForExistence(timeout: 3) { back.tap() }
    else { app.swipeLeft(velocity: .slow) }
    XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 5))
    return app
  }

  @MainActor
  func testBubbleTapReachesStartAction() {
    let app = openBubble()
    // Coordinate touches exercise recognition, rather than invoking an
    // accessibility action that could bypass a broken touch recognizer.
    app.buttons["Start conversation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.alerts["Voice connection"].waitForExistence(timeout: 3), app.debugDescription)
    XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "has not been connected")).firstMatch.exists)
    app.alerts.buttons["OK"].tap()
    app.buttons["Start conversation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.alerts["Voice connection"].waitForExistence(timeout: 3))
  }

  @MainActor
  func testHoldDoesNotStartConversationAndNextTapStillWorks() {
    let app = openBubble()
    let center = app.buttons["Start conversation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.press(forDuration: 1.2)
    XCTAssertFalse(app.alerts["Voice connection"].waitForExistence(timeout: 1))
    center.tap()
    XCTAssertTrue(app.alerts["Voice connection"].waitForExistence(timeout: 3))
  }

  @MainActor
  func testPagingStillWorksAndBubbleCanBeTappedAfterReturning() {
    let app = openBubble()
    app.swipeLeft(velocity: .slow)
    XCTAssertTrue(app.staticTexts["Preferences"].waitForExistence(timeout: 3), app.debugDescription)
    app.swipeRight(velocity: .slow)
    XCTAssertTrue(app.buttons["Start conversation"].waitForExistence(timeout: 3))
    app.swipeRight(velocity: .slow)
    XCTAssertTrue(app.staticTexts["Memory"].waitForExistence(timeout: 3), app.debugDescription)
    app.swipeLeft(velocity: .slow)
    app.buttons["Start conversation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.alerts["Voice connection"].waitForExistence(timeout: 3))
  }
}
