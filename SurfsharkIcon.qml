import QtQuick
import QtQuick.Shapes
import qs.Commons

// A shark fin, drawn as a path rather than a font glyph or an SVG file. Same
// reasoning as the first-party TailscaleIcon: a glyph depends on the particular
// Nerd Font build and can land as a tofu box, and a tiny SVG rasterises badly
// at bar size. One colour, always from the theme — no brand gradient.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // A struck-through fin means the tunnel is down — the same visual language
  // the Tailscale widget uses for "off".
  property bool crossed: false
  // The wave under the fin appears only when the tunnel is actually up, so the
  // state reads without relying on colour.
  property bool wave: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    anchors.fill: parent
    antialiasing: true
    smooth: true

    // The path is authored in a 0..100 box and scaled, so the icon is identical
    // at any bar height.
    transform: Scale {
      xScale: root.iconSize / 100
      yScale: root.iconSize / 100
    }

    ShapePath {
      fillColor: root.color
      strokeWidth: -1
      // The leading edge climbs to the tip and the trailing edge falls back in a
      // concave sweep — that concavity is what reads as a fin.
      PathSvg {
        path: "M 6,78 C 32,76 56,62 72,40 C 82,26 88,14 92,4 "
            + "C 94,34 88,58 74,72 C 60,84 30,86 6,78 Z"
      }
    }

    ShapePath {
      fillColor: root.wave ? root.color : "transparent"
      strokeWidth: -1
      // A short wave under the fin; present only while the tunnel is up.
      PathSvg {
        path: "M 4,90 C 20,84 32,96 48,90 C 64,84 76,96 96,88 "
            + "L 96,97 C 76,105 64,93 48,99 C 32,105 20,93 4,99 Z"
      }
    }
  }

  // The strike-through, shown when off. It runs at +45, across the fin: at -45
  // it would lie along the fin's own diagonal and the shape would read as a
  // feather rather than a crossed-out fin.
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: 45
  }
}
