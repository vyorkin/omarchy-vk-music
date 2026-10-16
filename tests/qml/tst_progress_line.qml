// The indeterminate line, rendered for the pixel check in
// tools/check_line_render.py.
//
// What the check exists for: the bright piece has to travel along the track.
// A line that renders its track and a piece that never moves looks exactly like
// a finished progress bar, which is the one thing a loading indicator must not
// look like.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
//   python3 tools/check_line_render.py
import QtQuick
import QtTest
import vkmusic

TestCase {
  name: "ProgressLine"
  when: windowShown

  readonly property string outputDir: "/tmp/vk-music-frame-tests"

  Item {
    id: scene
    width: 320
    height: 12
    Rectangle { anchors.fill: parent; color: "#000000" }

    ProgressLine {
      id: line
      anchors.fill: parent
      thickness: 4
      piece: 0.3
      color: "#ff0000"
      trackColor: "#0000ff"
      // Fixed positions: the animation must not decide what is rendered.
      phase: 0.0
    }
  }

  function renderTo(name, phase) {
    line.phase = phase
    wait(120)
    var grabbed = null
    scene.grabToImage(function(result) { grabbed = result })
    tryVerify(function() { return grabbed !== null }, 3000)
    wait(250)
    verify(grabbed.saveToFile(outputDir + "/" + name + ".png"), "saved " + name)
  }

  function test_render_positions() {
    renderTo("line-left", 0.0)
    renderTo("line-middle", 0.5)
    renderTo("line-right", 0.85)
  }

  // The determinate mode: a share of the line filled from the left, which is what
  // the bar shows for a track that is playing.
  function renderFill(name, progress) {
    line.indeterminate = false
    line.progress = progress
    renderTo(name, 0.0)
    line.indeterminate = true
  }

  function test_render_fill() {
    renderFill("line-fill-35", 0.35)
    renderFill("line-fill-100", 1.0)
  }
}
