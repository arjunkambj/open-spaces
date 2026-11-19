import AppKit
import Foundation
import SwiftUI
import Testing
import WisperDomain
import WisperEngine

@testable import WisperMacUI

/// Screens to place the pill on. Measured like macOS does: from the bottom left, y up.
private enum Screens {
  static let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
  /// A menu bar and a Dock that hides itself.
  static let plain = PillScreen(frame: full, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
  static let dockBottom = PillScreen(frame: full, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
  static let dockLeft = PillScreen(frame: full, visibleFrame: CGRect(x: 80, y: 0, width: 1360, height: 875))
  static let dockRight = PillScreen(frame: full, visibleFrame: CGRect(x: 0, y: 0, width: 1360, height: 875))
  /// A laptop with a notch whose menu bar hides itself: only the notch keeps the top.
  static let notch = PillScreen(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    topInset: 38
  )
  /// A second display to the right of the first, a little higher up.
  static let second = PillScreen(
    frame: CGRect(x: 1440, y: 200, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1440, y: 200, width: 1920, height: 1055)
  )
  static let tiny = PillScreen(
    frame: CGRect(x: 0, y: 0, width: 40, height: 40),
    visibleFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
  )
}

@Suite struct PillPlacementTests {
  struct Drop: CustomTestStringConvertible, Sendable {
    var name: String
    var screen: PillScreen
    var point: CGPoint
    var edge: PillEdge
    /// Where the pill ends up attached.
    var foot: CGPoint

    var testDescription: String { name }
  }

  static let drops: [Drop] = [
    Drop(
      name: "low in the middle",
      screen: Screens.plain,
      point: CGPoint(x: 700, y: 30),
      edge: .bottom,
      foot: CGPoint(x: 700, y: 0)
    ),
    Drop(
      name: "the middle of the screen",
      screen: Screens.plain,
      point: CGPoint(x: 720, y: 300),
      edge: .bottom,
      foot: CGPoint(x: 720, y: 0)
    ),
    Drop(
      name: "high up",
      screen: Screens.plain,
      point: CGPoint(x: 700, y: 800),
      edge: .top,
      foot: CGPoint(x: 700, y: 875)
    ),
    Drop(
      name: "on the menu bar",
      screen: Screens.plain,
      point: CGPoint(x: 700, y: 895),
      edge: .top,
      foot: CGPoint(x: 700, y: 875)
    ),
    Drop(
      name: "at the left",
      screen: Screens.plain,
      point: CGPoint(x: 12, y: 400),
      edge: .left,
      foot: CGPoint(x: 0, y: 400)
    ),
    Drop(
      name: "at the right",
      screen: Screens.plain,
      point: CGPoint(x: 1430, y: 520),
      edge: .right,
      foot: CGPoint(x: 1440, y: 520)
    ),
    Drop(
      name: "on a Dock at the bottom",
      screen: Screens.dockBottom,
      point: CGPoint(x: 600, y: 20),
      edge: .bottom,
      foot: CGPoint(x: 600, y: 70)
    ),
    Drop(
      name: "on the end of a Dock at the bottom",
      screen: Screens.dockBottom,
      // The Dock has the corner: this counts as a drop at the closest point beside the Dock.
      point: CGPoint(x: 5, y: 30),
      edge: .bottom,
      foot: CGPoint(x: 28, y: 70)
    ),
    Drop(
      name: "on a Dock at the left",
      screen: Screens.dockLeft,
      point: CGPoint(x: 10, y: 400),
      edge: .left,
      foot: CGPoint(x: 80, y: 400)
    ),
    Drop(
      name: "on the foot of a Dock at the left",
      screen: Screens.dockLeft,
      point: CGPoint(x: 40, y: 10),
      edge: .left,
      foot: CGPoint(x: 80, y: 28)
    ),
    Drop(
      name: "on a Dock at the right",
      screen: Screens.dockRight,
      point: CGPoint(x: 1435, y: 400),
      edge: .right,
      foot: CGPoint(x: 1360, y: 400)
    ),
    Drop(
      name: "behind the notch",
      screen: Screens.notch,
      point: CGPoint(x: 756, y: 975),
      edge: .top,
      foot: CGPoint(x: 756, y: 944)
    ),
    Drop(
      name: "exactly the bottom left corner",
      screen: Screens.plain,
      point: CGPoint(x: 0, y: 0),
      edge: .bottom,
      foot: CGPoint(x: 28, y: 0)
    ),
    Drop(
      name: "exactly the bottom right corner",
      screen: Screens.plain,
      point: CGPoint(x: 1440, y: 0),
      edge: .bottom,
      foot: CGPoint(x: 1412, y: 0)
    ),
    Drop(
      name: "exactly the top right corner",
      screen: Screens.plain,
      point: CGPoint(x: 1440, y: 900),
      edge: .top,
      foot: CGPoint(x: 1412, y: 875)
    ),
    Drop(
      name: "exactly the top left corner",
      screen: Screens.plain,
      point: CGPoint(x: 0, y: 900),
      edge: .top,
      foot: CGPoint(x: 28, y: 875)
    ),
    Drop(
      name: "off the screen to the left",
      screen: Screens.plain,
      point: CGPoint(x: -300, y: 400),
      edge: .left,
      foot: CGPoint(x: 0, y: 400)
    ),
    Drop(
      name: "off the screen below",
      screen: Screens.plain,
      point: CGPoint(x: 500, y: -90),
      edge: .bottom,
      foot: CGPoint(x: 500, y: 0)
    ),
    Drop(
      name: "low on the left edge",
      screen: Screens.plain,
      point: CGPoint(x: 3, y: 10),
      edge: .left,
      foot: CGPoint(x: 0, y: 28)
    ),
    Drop(
      name: "on a second display",
      screen: Screens.second,
      point: CGPoint(x: 3350, y: 700),
      edge: .right,
      foot: CGPoint(x: 3360, y: 700)
    ),
    Drop(
      name: "a tiny screen",
      screen: Screens.tiny,
      point: CGPoint(x: 5, y: 20),
      edge: .left,
      foot: CGPoint(x: 0, y: 20)
    ),
  ]

  @Test(arguments: drops)
  func aDroppedPillDocksToTheNearestEdge(_ drop: Drop) {
    let spot = PillPlacement.spot(droppedAt: drop.point, on: drop.screen)
    #expect(spot.edge == drop.edge)
    let foot = PillPlacement.foot(of: spot, on: drop.screen)
    #expect(abs(foot.x - drop.foot.x) < 0.01 && abs(foot.y - drop.foot.y) < 0.01, "\(foot)")

    // Never mid-screen: the foot is on an edge of the usable part, and inside it.
    let usable = drop.screen.usable
    #expect(usable.insetBy(dx: -0.01, dy: -0.01).contains(foot))
    switch spot.edge {
    case .bottom: #expect(foot.y == usable.minY)
    case .top: #expect(foot.y == usable.maxY)
    case .left: #expect(foot.x == usable.minX)
    case .right: #expect(foot.x == usable.maxX)
    }

    // Its window holds the foot and reaches inward from the pill's edge.
    let frame = PillPlacement.panelFrame(for: spot, on: drop.screen)
    #expect(frame.insetBy(dx: -1, dy: -1).contains(foot))
    #expect(frame.size == (spot.edge.isSide ? PillPlacement.sidePanel : PillPlacement.flatPanel))
    if drop.screen.usable.width >= frame.width, drop.screen.usable.height >= frame.height {
      // Nothing the pill shows can be under the Dock, the menu bar or the notch, or off screen.
      #expect(usable.insetBy(dx: -1, dy: -1).contains(frame), "\(frame) in \(usable)")
    }

    // Dropped again where it sits, it stays.
    let again = PillPlacement.spot(droppedAt: foot, on: drop.screen, from: spot.edge)
    #expect(again.edge == spot.edge)
    #expect(abs(again.along - spot.along) < 0.0001)
  }

  @Test func theUsablePartLeavesOutTheMenuBarTheNotchAndTheDock() {
    #expect(Screens.plain.usable == CGRect(x: 0, y: 0, width: 1440, height: 875))
    #expect(Screens.dockBottom.usable == CGRect(x: 0, y: 70, width: 1440, height: 805))
    #expect(Screens.dockLeft.usable.minX == 80)
    #expect(Screens.dockRight.usable.maxX == 1360)
    #expect(Screens.notch.usable.maxY == 944)
    // A visible frame that makes no sense falls back to the whole display.
    let odd = PillScreen(frame: Screens.full, visibleFrame: .zero)
    #expect(odd.usable == Screens.full)
  }

  @Test func aDraggedPillOnlyTurnsWhenAnotherEdgeIsClearlyNearer() {
    // 100 from the left, 110 from the bottom: the left is nearer, but not by much.
    let close = CGPoint(x: 100, y: 110)
    #expect(PillPlacement.spot(droppedAt: close, on: Screens.plain).edge == .left)
    #expect(PillPlacement.spot(droppedAt: close, on: Screens.plain, from: .bottom).edge == .bottom)
    #expect(PillPlacement.spot(droppedAt: close, on: Screens.plain, from: .left).edge == .left)
    // 50 from the left: clearly nearer now.
    let clear = CGPoint(x: 50, y: 110)
    #expect(PillPlacement.spot(droppedAt: clear, on: Screens.plain, from: .bottom).edge == .left)
  }

  @Test func aSpotThatMakesNoSenseStillLandsOnTheScreen() {
    for along in [-3.0, 7.0, .nan, .infinity] {
      for edge in PillEdge.allCases {
        let foot = PillPlacement.foot(of: PillSpot(edge: edge, along: along), on: Screens.dockBottom)
        #expect(Screens.dockBottom.usable.insetBy(dx: -0.01, dy: -0.01).contains(foot))
      }
    }
  }

  @Test func homeIsTheMiddleOfTheBottomEdgeAboveTheDock() {
    #expect(PillPlacement.foot(of: .home, on: Screens.dockBottom) == CGPoint(x: 720, y: 70))
    let frame = PillPlacement.panelFrame(for: .home, on: Screens.dockBottom)
    #expect(frame == CGRect(x: 480, y: 70, width: 480, height: 170))
  }

  @Test func theWindowSlidesAlongTheEdgeToStayOnTheScreen() {
    let spot = PillSpot(edge: .bottom, along: 0)
    let frame = PillPlacement.panelFrame(for: spot, on: Screens.plain)
    #expect(frame.minX == 0)
    // The pill is then left of the window's middle, where the window is told it is.
    let foot = PillPlacement.viewPoint(PillPlacement.foot(of: spot, on: Screens.plain), in: frame)
    #expect(foot == CGPoint(x: 28, y: 170))
    let side = PillPlacement.panelFrame(for: PillSpot(edge: .right, along: 1), on: Screens.plain)
    #expect(side.maxX == 1440 && side.maxY == 875)
  }

  @Test func aPointIsMeasuredFromTheWindowsTopLeft() {
    let panel = CGRect(x: 100, y: 200, width: 480, height: 170)
    #expect(PillPlacement.viewPoint(CGPoint(x: 100, y: 370), in: panel) == .zero)
    #expect(PillPlacement.viewPoint(CGPoint(x: 340, y: 200), in: panel) == CGPoint(x: 240, y: 170))
  }

  @Test func aPressThatHardlyMovesIsAClick() {
    let start = CGPoint(x: 10, y: 10)
    #expect(!PillPlacement.isDrag(from: start, to: CGPoint(x: 12, y: 12), isRecording: false))
    #expect(PillPlacement.isDrag(from: start, to: CGPoint(x: 15, y: 10), isRecording: false))
    // While recording, a shaky click on Stop is still a click.
    #expect(!PillPlacement.isDrag(from: start, to: CGPoint(x: 16, y: 10), isRecording: true))
    #expect(PillPlacement.isDrag(from: start, to: CGPoint(x: 19, y: 10), isRecording: true))
  }

  @Test func aPointBelongsToTheScreenItIsOnOrElseTheNearest() {
    let screens = [Screens.plain, Screens.second]
    #expect(PillPlacement.screen(for: CGPoint(x: 10, y: 10), among: screens) == 0)
    #expect(PillPlacement.screen(for: CGPoint(x: 2000, y: 600), among: screens) == 1)
    // Below the second display, which starts higher up: nearest is the second.
    #expect(PillPlacement.screen(for: CGPoint(x: 2500, y: 100), among: screens) == 1)
    #expect(PillPlacement.screen(for: CGPoint(x: -500, y: 100), among: screens) == 0)
    #expect(PillPlacement.screen(for: .zero, among: []) == nil)
  }
}

@MainActor
@Suite struct PillMemoryTests {
  private let left = PillSpot(edge: .left, along: 0.4)

  @Test func aSpotIsRememberedForEachArrangementOfDisplays() {
    var memory = PillMemory()
    #expect(memory.isEmpty)
    #expect(memory.placement(among: [Screens.plain]) == nil)

    memory.remember(left, onScreen: 0, among: [Screens.plain])
    let alone = memory.placement(among: [Screens.plain])
    #expect(alone?.screen == 0)
    #expect(alone?.spot == left)

    // With a monitor plugged in, that is another arrangement: nothing is remembered for it yet.
    let both = [Screens.plain, Screens.second]
    #expect(memory.placement(among: both) == nil)
    let top = PillSpot(edge: .top, along: 0.5)
    memory.remember(top, onScreen: 1, among: both)
    #expect(memory.placement(among: both)?.screen == 1)
    #expect(memory.placement(among: both)?.spot == top)
    // The same displays listed the other way round are the same arrangement.
    #expect(memory.placement(among: [Screens.second, Screens.plain])?.screen == 0)
    // Unplugged again, the laptop has its own spot back.
    #expect(memory.placement(among: [Screens.plain])?.spot == left)
  }

  @Test func aSpotThatNoLongerFitsIsNotUsed() {
    var memory = PillMemory()
    memory.remember(left, onScreen: 0, among: [Screens.plain])
    // The resolution changed.
    let resized = PillScreen(
      frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080)
    )
    #expect(memory.placement(among: [resized]) == nil)
    #expect(memory.placement(among: []) == nil)
    // A Dock that moved changes the usable part, not the display: the spot still counts.
    #expect(memory.placement(among: [Screens.dockLeft])?.spot == left)
  }

  @Test func aSpotFromABrokenFileIsNotUsed() throws {
    for along in ["7", "-1"] {
      let json =
        #"{"entries":{"0,0,1440,900":{"spot":{"edge":"left","along":\#(along)},"display":[0,0,1440,900]}}}"#
      let memory = try JSONDecoder().decode(PillMemory.self, from: Data(json.utf8))
      #expect(memory.placement(among: [Screens.plain]) == nil)
    }
    #expect(
      (try? JSONDecoder().decode(
        PillMemory.self,
        from: Data(#"{"entries":{"x":{"spot":{"edge":"up"}}}}"#.utf8)
      )) == nil
    )
  }

  @Test func rememberingOutsideTheListDoesNothing() {
    var memory = PillMemory()
    memory.remember(left, onScreen: 3, among: [Screens.plain])
    #expect(memory.isEmpty)
  }

  @Test func theSpotsAreKeptBetweenLaunchesAndCanBeReset() throws {
    let name = "open-wisper-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    let first = PillSpots(defaults: defaults)
    #expect(!first.isMoved)
    first.remember(left, onScreen: 0, among: [Screens.plain])
    #expect(first.isMoved)

    let second = PillSpots(defaults: defaults)
    #expect(second.isMoved)
    #expect(second.memory.placement(among: [Screens.plain])?.spot == left)

    second.reset()
    #expect(!second.isMoved)
    #expect(!PillSpots(defaults: defaults).isMoved)
  }

  @Test func withoutAPlaceToKeepThemTheSpotsLastForTheRun() {
    let spots = PillSpots()
    spots.remember(left, onScreen: 0, among: [Screens.plain])
    #expect(spots.isMoved)
    spots.reset()
    #expect(!spots.isMoved)
  }

  @Test func thePillMenuOffersToPutItBackOnlyOnceItWasMoved() async {
    let spots = PillSpots()
    let stage = await Stage(pillSpots: spots)
    func offersReset() -> Bool {
      MenuBarContent.pillEntries(for: stage.model, controls: stage.controls, microphones: [])
        .contains { $0.kind == .action(.resetPillPosition) }
    }
    #expect(!offersReset())
    spots.remember(left, onScreen: 0, among: [Screens.plain])
    #expect(offersReset())
    MenuBarContent.perform(.resetPillPosition, model: stage.model, controls: stage.controls)
    #expect(!spots.isMoved)
    #expect(!offersReset())
  }
}

/// The pill drawn against each edge, measured the way its window measures it.
@MainActor
@Suite struct PillEdgeLayoutTests {
  private func host(_ stage: Stage, pointer: PillPointer, size: CGSize) async -> NSView {
    let view = NSHostingView(
      rootView: PillView(pointer: pointer).environment(stage.model).environment(stage.controls)
    )
    view.frame = CGRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    await settle { !pointer.hotFrame.isEmpty }
    return view
  }

  @Test func onASideThePillStandsUprightAgainstThatEdge() async {
    let stage = await Stage()
    let pointer = PillPointer()
    pointer.edge = .left
    let view = await host(stage, pointer: pointer, size: PillPlacement.sidePanel)
    #expect(pointer.hotFrame.size == CGSize(width: 8, height: 40), "Tall and thin")
    #expect(pointer.hotFrame.minX > 0 && pointer.hotFrame.minX <= 6)
    #expect(abs(pointer.hotFrame.midY - 180) < 1)
    #expect(pointer.canMove)

    pointer.edge = .right
    await settle { pointer.hotFrame.maxX > 300 }
    #expect(pointer.hotFrame.size == CGSize(width: 8, height: 40))
    #expect(pointer.hotFrame.maxX < 400 && pointer.hotFrame.maxX >= 394)

    // Recording there, it is an upright capsule with the buttons at its ends.
    stage.controls.toggleHandsFree()
    await settle { pointer.hotFrame.width == 28 }
    #expect(pointer.hotFrame.width == 28)
    #expect(pointer.hotFrame.height > 80)
    #expect(pointer.isRecording)
    stage.controls.cancel()
    _ = view
  }

  @Test func atTheTopItHangsFromTheEdge() async {
    let stage = await Stage()
    let pointer = PillPointer()
    pointer.edge = .top
    let view = await host(stage, pointer: pointer, size: PillPlacement.flatPanel)
    #expect(pointer.hotFrame.size == CGSize(width: 40, height: 8))
    #expect(pointer.hotFrame.minY > 0 && pointer.hotFrame.minY <= 6)
    #expect(abs(pointer.hotFrame.midX - 240) < 1)
    _ = view
  }

  @Test func itSitsWhereItsWindowSaysAndStaysInsideNearACorner() async {
    let stage = await Stage()
    let pointer = PillPointer()
    pointer.foot = CGPoint(x: 28, y: 170)
    let view = await host(stage, pointer: pointer, size: PillPlacement.flatPanel)
    #expect(abs(pointer.hotFrame.midX - 28) < 1, "Centred on the point it is attached to")
    // A hands-free recording is wider than twice the distance to the corner: it moves in.
    stage.controls.toggleHandsFree()
    await settle { pointer.hotFrame.width > 80 }
    #expect(pointer.hotFrame.minX >= 0)
    #expect(pointer.hotFrame.maxX <= 480)
    stage.controls.cancel()
    _ = view
  }

  @Test func carriedByThePointerItIsCentredOnItAndLargeEnoughToSee() async {
    let stage = await Stage()
    let pointer = PillPointer()
    pointer.isFloating = true
    pointer.foot = CGPoint(x: 300, y: 200)
    let view = await host(stage, pointer: pointer, size: CGSize(width: 800, height: 600))
    await settle { pointer.hotFrame.height == 30 }
    #expect(pointer.hotFrame.size == CGSize(width: 64, height: 30))
    #expect(abs(pointer.hotFrame.midX - 300) < 1 && abs(pointer.hotFrame.midY - 200) < 1)
    _ = view
  }

  @Test func aMessageCannotBePickedUp() async {
    let stage = await Stage()
    let pointer = PillPointer()
    let view = await host(stage, pointer: pointer, size: PillPlacement.flatPanel)
    #expect(pointer.canMove)
    stage.controls.noteCopied()
    await settle { !pointer.canMove }
    #expect(!pointer.canMove)
    _ = view
  }

  @Test func aReleaseThatEndsADragClicksNothing() async {
    let stage = await Stage()
    #expect(PillState(look: .resting, meetingSince: nil).canMove)
    #expect(PillState(look: .recording(mode: .dictation, handsFree: true), meetingSince: nil).canMove)
    #expect(PillState(look: .working, meetingSince: nil).canMove)
    #expect(PillState(look: .hidden, meetingSince: Date()).canMove)
    #expect(!PillState(look: .hidden, meetingSince: nil).canMove)
    #expect(!PillState(look: .notice("No.", canFix: false), meetingSince: nil).canMove)
    #expect(!PillState(look: .question("Yes?", yes: "Yes", no: "No"), meetingSince: nil).canMove)
    _ = stage
  }

  @Test func whileGrabbedThePillLooksHeldAndAQuestionShowsItsAnswers() {
    let grabbed = PillState.resolve(
      phase: .idle,
      showsRecording: false,
      isWrappingUp: false,
      notice: nil,
      meetingSince: nil,
      isEnabled: true,
      isHovered: false,
      hintKeys: ["fn"],
      isGrabbed: true
    )
    #expect(grabbed.look == .hint(keys: ["fn"]))
    #expect(grabbed.isGrabbed)
    let asking = PillState.resolve(
      phase: .idle,
      showsRecording: false,
      isWrappingUp: false,
      notice: MacControls.Notice(
        message: "Stop that?",
        fix: .globeKey,
        isProblem: false,
        answers: MacControls.Notice.Answers(yes: "Fix it", no: "Not now")
      ),
      meetingSince: nil,
      isEnabled: true,
      isHovered: false,
      hintKeys: []
    )
    #expect(asking.look == .question("Stop that?", yes: "Fix it", no: "Not now"))
  }
}
