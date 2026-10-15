// The buffering frame: the share of the perimeter it should fill, and rendered
// images for the pixel check in tools/check_frame_render.py.
//
// The bug these exist for was invisible to arithmetic: the length handed to the
// walk was a *share* clamped with a pixel-style minimum, `Math.max(1, share)`,
// which silently meant "the whole frame" at every percentage, so the outline was
// always painted full and never moved.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
//   python3 tools/check_frame_render.py
import QtQuick
import QtTest
import vkmusic

TestCase {
  name: "ProgressFrame"
  when: windowShown

  readonly property string outputDir: "/tmp/vk-music-frame-tests"

  Item {
    id: scene
    width: 64
    height: 64
    Rectangle { anchors.fill: parent; color: "#000000" }

    ProgressFrame {
      id: frame
      anchors.fill: parent
      cornerRadius: 6
      thickness: 3
      color: "#ff0000"
      frameColor: "#0000ff"
      progress: 0.5
    }
  }

  function renderTo(name, progress) {
    frame.progress = progress
    wait(150)
    var grabbed = null
    scene.grabToImage(function(result) { grabbed = result })
    tryVerify(function() { return grabbed !== null }, 3000)
    wait(250)
    verify(grabbed.saveToFile(outputDir + "/" + name + ".png"), "saved " + name)
  }

  // The share the fill covers, straight from the component.
  function test_fill_share_matches_progress() {
    var expected = [0, 0.15, 0.37, 0.5, 0.75, 1]
    for (var i = 0; i < expected.length; i++) {
      frame.progress = expected[i]
      compare(frame.fillShare, expected[i], "fill share for " + expected[i])
    }
    frame.progress = 0.5
  }

  // Rendered files for tools/check_frame_render.py: a quarter, a half, and all
  // of the perimeter.
  function test_render_steps() {
    renderTo("q25", 0.25)
    renderTo("q50", 0.5)
    renderTo("q100", 1.0)
  }
}
