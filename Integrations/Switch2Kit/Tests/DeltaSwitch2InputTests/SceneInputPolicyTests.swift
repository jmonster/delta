import XCTest
import DeltaSwitch2Input

final class SceneInputPolicyTests: XCTestCase
{
    func testPermissionAlertNeutralizesWithoutStoppingRadio()
    {
        var policy = SceneInputPolicy(active: ["game"])
        policy.receive(.deactivate, scene: "game")
        XCTAssertFalse(policy.acceptsInput)
        XCTAssertFalse(policy.shouldStop)
        policy.receive(.activate, scene: "game")
        XCTAssertTrue(policy.acceptsInput)
    }

    func testSecondForegroundWindowKeepsControllersUsable()
    {
        var policy = SceneInputPolicy(active: ["game", "library"])
        policy.receive(.deactivate, scene: "library")
        policy.receive(.background, scene: "library")
        XCTAssertTrue(policy.acceptsInput)
        XCTAssertFalse(policy.shouldStop)
    }

    func testLastSceneBackgroundOrDisconnectStops()
    {
        for event in [SceneInputPolicy.Event.background, .disconnect]
        {
            var policy = SceneInputPolicy(active: ["game"])
            policy.receive(event, scene: "game")
            XCTAssertFalse(policy.acceptsInput)
            XCTAssertTrue(policy.shouldStop)
        }
    }

    func testForegroundDoesNotAcceptInputsUntilActivation()
    {
        var policy = SceneInputPolicy()
        policy.receive(.foreground, scene: "game")
        XCTAssertFalse(policy.acceptsInput)
        XCTAssertFalse(policy.shouldStop)
        policy.receive(.activate, scene: "game")
        XCTAssertTrue(policy.acceptsInput)
    }
}
