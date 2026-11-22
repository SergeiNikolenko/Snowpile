import AppKit
import CoreGraphics
import XCTest
@testable import Snowpile

final class ElementLocatorTests: XCTestCase {
    private let windowFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testExtractsComposerBubbleAndSidebarCardWhileIgnoringLayoutWrappers() {
        let scrollClip = CGRect(x: 307, y: 0, width: 1613, height: 1080)
        let nodes: [ElementLocator.NodeSnapshot] = [
            // 0: full-window pointer-events-none overlay
            .init(role: "AXGroup", subrole: "", frame: windowFrame, clip: windowFrame,
                  classes: ["pointer-events-none", "fixed", "inset-0"], parent: nil, childCount: 1),
            // 1: full-height left sidebar panel (should be rejected as shell pane)
            .init(role: "AXGroup", subrole: "AXLandmarkComplementary", frame: CGRect(x: 0, y: 46, width: 307, height: 1034),
                  clip: windowFrame, classes: ["app-shell-left-panel", "bg-surface", "border"], parent: 0, childCount: 2),
            // 2: floating right sidebar card ("Changes / Sources")
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 1612, y: 54, width: 300, height: 392), clip: windowFrame,
                  classes: ["rounded-2xl", "extension:border", "extension:border-default", "extension:shadow-md",
                            "bg-surface-elevated-secondary", "electron:elevation-prominent", "group/summary-panel"],
                  parent: 0, childCount: 6),
            // 2b: thin clickable row inside the tall right sidebar card (should be suppressed)
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 1632, y: 94, width: 260, height: 28), clip: windowFrame,
                  classes: ["rounded-lg", "bg-surface-hover"], parent: 2, childCount: 1),
            // 3: visible user message bubble above composer
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 746, y: 260, width: 520, height: 74), clip: scrollClip,
                  classes: ["bg-user-message", "text-user-message", "bubble-vBnidZ", "py-2.5", "rounded-2xl"],
                  parent: 0, childCount: 1),
            // 4: plain paragraph (no visual card styling)
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 746, y: 380, width: 736, height: 94), clip: scrollClip,
                  classes: ["Paragraph-kKnbIo", "hover:bg-zinc-800"], parent: 0, childCount: 3),
            // 5: transparent footer overlay with conditional has-[...]:bg-surface
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 307, y: 925, width: 1613, height: 155), clip: scrollClip,
                  classes: ["footer-A8ZvKV", "pointer-events-none", "has-[[data-thread-focus-mode]]:bg-surface"],
                  parent: 0, childCount: 1),
            // 6: rounded composer container
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 746, y: 925, width: 736, height: 139), clip: scrollClip,
                  classes: ["ComposerLayoutBody-uBBf1A"], parent: 6, childCount: 8),
            // 7: ProseMirror AXTextArea inside composer (should promote to 6 and not create a second shelf)
            .init(role: "AXTextArea", subrole: "", frame: CGRect(x: 758, y: 980, width: 712, height: 40), clip: scrollClip,
                  classes: ["ProseMirror"], parent: 7, childCount: 1),
            // 8: old message bubble tucked behind the floating composer (should be suppressed)
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 1327, y: 996, width: 155, height: 43), clip: scrollClip,
                  classes: ["bg-user-message", "bubble-vBnidZ", "rounded-2xl"], parent: 0, childCount: 1),
            // 9: nested inherit wrapper inside a floating card (should not duplicate)
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 1612, y: 54, width: 300, height: 228), clip: windowFrame,
                  classes: ["content-Sj8_aX", "rounded-[inherit]", "bg-inherit"], parent: 2, childCount: 1),
        ]

        let surfaces = ElementLocator.extractSurfaces(windowFrame: windowFrame, nodes: nodes)
        XCTAssertEqual(surfaces.count, 3)
        // Right sidebar card (inset by 10pt extra for rounded-2xl)
        XCTAssertEqual(surfaces[0].minY, 54)
        XCTAssertEqual(surfaces[0].minX, 1622)
        XCTAssertEqual(surfaces[0].width, 280)
        // Visible user message bubble
        XCTAssertEqual(surfaces[1].minY, 260)
        XCTAssertEqual(surfaces[1].minX, 756)
        XCTAssertEqual(surfaces[1].width, 500)
        // Promoted composer card (at y=925, not inner ProseMirror at y=980)
        XCTAssertEqual(surfaces[2].minY, 925)
        XCTAssertEqual(surfaces[2].minX, 756)
        XCTAssertEqual(surfaces[2].width, 716)
    }

    func testClipsScrolledOutBubblesAndKeepsNativeBoxesAndTextFields() {
        let scrollClip = CGRect(x: 0, y: 80, width: 1200, height: 600)
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let nodes: [ElementLocator.NodeSnapshot] = [
            // Scrolled above scroll viewport -> rejected
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 200, y: 40, width: 400, height: 60), clip: scrollClip,
                  classes: ["rounded-2xl", "bg-zinc-800"], parent: nil, childCount: 1),
            // Plain native search field near top of window -> kept
            .init(role: "AXSearchField", subrole: "", frame: CGRect(x: 300, y: 20, width: 320, height: 24), clip: box,
                  classes: [], parent: nil, childCount: 0),
            // Native macOS AXBox card -> kept
            .init(role: "AXBox", subrole: "", frame: CGRect(x: 100, y: 180, width: 360, height: 140), clip: box,
                  classes: [], parent: nil, childCount: 2),
            // Card extending off the right edge of the window -> horizontally clipped to window right edge
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 1020, y: 200, width: 260, height: 120), clip: box,
                  classes: ["rounded-2xl", "bg-surface", "border"], parent: nil, childCount: 1),
        ]

        let surfaces = ElementLocator.extractSurfaces(windowFrame: box, nodes: nodes)
        XCTAssertEqual(surfaces.count, 3)
        XCTAssertEqual(surfaces[0], CGRect(x: 300, y: 20, width: 320, height: 24))
        XCTAssertEqual(surfaces[1].minY, 180)
        XCTAssertEqual(surfaces[1].width, 348)
        XCTAssertEqual(surfaces[2].minY, 200)
        XCTAssertEqual(surfaces[2].minX, 1030)
        XCTAssertEqual(surfaces[2].maxX, 1200)
    }

    func testWindowListFiltersInvisibleHelperWindows() {
        // Invisible CLI helper (like cua-driver): accessory, no bundle ID, empty title -> excluded
        XCTAssertFalse(WindowList.shouldInclude(widget: false, windowName: "", activationPolicy: .accessory, hasBundleIdentifier: false))
        // Prohibited background process -> excluded
        XCTAssertFalse(WindowList.shouldInclude(widget: false, windowName: "Helper", activationPolicy: .prohibited, hasBundleIdentifier: true))
        // Regular app window -> included
        XCTAssertTrue(WindowList.shouldInclude(widget: false, windowName: "Codex", activationPolicy: .regular, hasBundleIdentifier: true))
        // Accessory app with bundle ID (like Snowpile Settings or Raycast) -> included
        XCTAssertTrue(WindowList.shouldInclude(widget: false, windowName: "Snowpile Settings", activationPolicy: .accessory, hasBundleIdentifier: true))
        // Desktop widget -> included
        XCTAssertTrue(WindowList.shouldInclude(widget: true, windowName: "Weather", activationPolicy: nil, hasBundleIdentifier: false))
    }

    func testPromotesNativeSafariURLCapsuleAboveInnerTextField() {
        let box = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let nodes: [ElementLocator.NodeSnapshot] = [
            // 0: native toolbar
            .init(role: "AXToolbar", subrole: "", frame: CGRect(x: 0, y: 0, width: 1440, height: 76), clip: box,
                  classes: [], parent: nil, childCount: 1),
            // 1: rounded Liquid Glass URL pill wrapping the text field
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 420, y: 33, width: 580, height: 36), clip: box,
                  classes: [], parent: 0, childCount: 1),
            // 2: inner centered AXTextField much narrower than the outer pill (as in Safari 26)
            .init(role: "AXTextField", subrole: "", frame: CGRect(x: 590, y: 43, width: 240, height: 16), clip: box,
                  classes: [], parent: 1, childCount: 0),
        ]

        let layout = ElementLocator.extractLayout(windowFrame: box, nodes: nodes)
        XCTAssertEqual(layout.surfaces.count, 1)
        XCTAssertEqual(layout.surfaces[0].minY, 33, "snow should rest on the outer pill top border, not inside above the URL")
        XCTAssertGreaterThan(layout.surfaces[0].minX, 420, "pill corners should be inset")
        XCTAssertLessThan(layout.surfaces[0].maxX, 1000)
        XCTAssertTrue(layout.occluders.contains { $0.isSurfaceBody && $0.rect.minY == 35 && $0.rect.width == 580 })
    }

    func testClipsOverlappingBubbleAgainstFloatingRightCard() {
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let nodes: [ElementLocator.NodeSnapshot] = [
            // 0: message bubble whose right side extends behind the floating Changes card
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 460, y: 120, width: 520, height: 72), clip: box,
                  classes: ["bg-user-message", "bubble-abc", "rounded-2xl"], parent: nil, childCount: 1),
            // 1: floating right Changes card overlapping x=900..1180
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 900, y: 60, width: 280, height: 340), clip: box,
                  classes: ["rounded-2xl", "bg-surface-elevated-secondary", "extension:shadow-md", "electron:elevation-prominent", "group/summary-panel"],
                  parent: nil, childCount: 2),
        ]

        let surfaces = ElementLocator.extractSurfaces(windowFrame: box, nodes: nodes)
        XCTAssertEqual(surfaces.count, 2)
        let card = surfaces[0]
        let bubble = surfaces[1]
        XCTAssertEqual(card.minY, 60)
        XCTAssertEqual(bubble.minY, 120)
        XCTAssertLessThanOrEqual(bubble.maxX, 900, "bubble snow shelf must stop before the overlapping Changes card")
    }

    func testExtractsMergedVerticalTextBlocksAndCardBodyOccluders() {
        let box = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let nodes: [ElementLocator.NodeSnapshot] = [
            // Vertical chat paragraphs separated by 22pt gaps (should merge into one tall vertical occluder)
            .init(role: "AXStaticText", subrole: "", frame: CGRect(x: 420, y: 200, width: 620, height: 64), clip: box,
                  classes: [], parent: nil, childCount: 0),
            .init(role: "AXStaticText", subrole: "", frame: CGRect(x: 420, y: 286, width: 600, height: 72), clip: box,
                  classes: [], parent: nil, childCount: 0),
            .init(role: "AXStaticText", subrole: "", frame: CGRect(x: 420, y: 380, width: 580, height: 80), clip: box,
                  classes: [], parent: nil, childCount: 0),
            // Floating right Changes card across an empty gutter (must stay separate from center text)
            .init(role: "AXGroup", subrole: "", frame: CGRect(x: 1280, y: 70, width: 290, height: 360), clip: box,
                  classes: ["rounded-2xl", "bg-surface", "shadow-md"], parent: nil, childCount: 1),
            // Degenerate 1pt height invisible helper text (must be ignored)
            .init(role: "AXStaticText", subrole: "", frame: CGRect(x: 0, y: 0, width: 1094, height: 1), clip: box,
                  classes: [], parent: nil, childCount: 0),
        ]

        let layout = ElementLocator.extractLayout(windowFrame: box, nodes: nodes)
        let textOccluders = layout.occluders.filter { !$0.isSurfaceBody }
        let surfaceOccluders = layout.occluders.filter(\.isSurfaceBody)
        XCTAssertEqual(textOccluders.count, 1, "stacked paragraphs should merge into one vertical text block")
        XCTAssertLessThanOrEqual(textOccluders[0].rect.minY, 200)
        XCTAssertGreaterThanOrEqual(textOccluders[0].rect.maxY, 460)
        XCTAssertLessThan(textOccluders[0].rect.maxX, 1100, "must not merge across empty gutter into right card")
        XCTAssertEqual(surfaceOccluders.count, 1)
        XCTAssertEqual(surfaceOccluders[0].rect.minX, 1280)
        XCTAssertEqual(surfaceOccluders[0].rect.minY, 72)
    }

    func testDetectsWakeModesForCodexClaudeAndBrowsers() {
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "com.openai.codex"), .chromium)
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "com.openai.chat"), .chromium)
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "com.anthropic.claudefordesktop"), .electron)
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "com.anthropic.claude-science"), .electron)
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "app.zen-browser.zen"), .chromium)
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "com.google.Chrome"), .chromium)
        XCTAssertEqual(ElementLocator.detectWakeMode(bundleURL: nil, bundleIdentifier: "com.apple.Safari"), .standard)
    }
}
