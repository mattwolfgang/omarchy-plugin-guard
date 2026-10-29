import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "example.tiny-clock"
  property string now: Qt.formatTime(new Date(), "HH:mm")

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.now = Qt.formatTime(new Date(), "HH:mm")
  }

  WidgetButton { anchors.fill: parent; bar: root.bar; text: root.now }
}
