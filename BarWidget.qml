import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The omaclock bar label. It shows a configured zone rather than local
// time — the built-in clock already owns local — following the first saved
// city ("second city option") by default; `barZone` also accepts any zone
// id or "" / "local" for local. Left click opens the planner; right click
// walks the label formats; middle click opens the standalone omaclock app.
BarWidget {
  id: root
  moduleName: "io.github.captainawesomedi.omaclock"

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? "HH\n—\nmm"
    : setting("format", "HH:mm")
  readonly property var formatRing: [ "HH:mm", "ddd HH:mm", "dd MMM HH:mm" ]

  // ---- Which zone the label shows. "saved" follows the first saved city
  //      (the panel's second row); "" (or "local") is local time; anything
  //      else is a zone id.
  readonly property string barZone: {
    var v = String(setting("barZone", "saved") || "")
    return v === "local" ? "" : v
  }
  readonly property bool barShowCity: setting("barShowCity", true) === true

  readonly property var savedZoneList: {
    var v = settings && settings.zones ? settings.zones : []
    if (typeof v === "string") v = v.length > 0 ? [v] : []
    var out = []
    for (var i = 0; i < v.length; i++)
      if (v[i] && out.indexOf(v[i]) < 0) out.push(v[i])
    return out
  }

  readonly property string barEffectiveZone: barZone === "saved"
    ? (savedZoneList.length > 0 ? savedZoneList[0] : "")
    : barZone

  readonly property string zoneLabel: barEffectiveZone !== "" && barShowCity
    ? Model.splitZoneId(barEffectiveZone).city : ""

  // The zone's current UTC offset, sampled from coreutils `date` — at
  // startup, on zone change, and on every hour boundary so a DST flip
  // lands within the hour it happens.
  property real sampledOffset: -new Date().getTimezoneOffset() * 60

  function sampleBarOffset() {
    if (barEffectiveZone === "") {
      sampledOffset = -new Date().getTimezoneOffset() * 60
      return
    }
    barSampler.command = ["sh", "-c", "TZ=\"" + barEffectiveZone + "\" date +%z"]
    if (barSampler.running) barSampler.running = false
    barSampler.running = true
  }

  // The displayed instant: now shifted by the zone's offset difference, so
  // the local formatter reads it as the zone's wall time.
  function shifted(d) {
    if (barEffectiveZone === "") return d
    return new Date(d.getTime() + (sampledOffset - (-d.getTimezoneOffset() * 60)) * 1000)
  }

  readonly property string timeText: Qt.formatDateTime(displayDate, configuredFormat)
  readonly property string displayText: zoneLabel !== ""
    ? (vertical ? zoneLabel + "\n" + timeText : zoneLabel + " " + timeText)
    : timeText
  readonly property var verticalLines: displayText.split("\n")

  function cycleBarZone() {
    var next = Model.nextBarZone(barZone, savedZoneList)
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.barZone = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function refresh() {
    displayDate = shifted(new Date())
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var at = formatRing.indexOf(current)
    var next = formatRing[(at + 1 + formatRing.length) % formatRing.length]
    if (next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.format = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Planner popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.displayDate = root.shifted(date)
      if (date.getMinutes() === 0) root.sampleBarOffset()
    }
  }

  Process {
    id: barSampler
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = Model.parseOffsetLine(text)
        if (v !== null) root.sampledOffset = v
      }
    }
  }

  onBarEffectiveZoneChanged: sampleBarOffset()
  onSampledOffsetChanged: displayDate = shifted(new Date())
  Component.onCompleted: sampleBarOffset()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.captainawesomedi.omaclock"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function cycleBarZone(): void { root.cycleBarZone() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: (root.zoneLabel !== "" ? root.zoneLabel + " · " : "")
      + Qt.formatDateTime(root.displayDate, "dddd, d MMMM yyyy")

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omaclock") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
