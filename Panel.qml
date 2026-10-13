import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The omaclock meeting planner, worldtimebuddy-style: the saved cities as
// rows, the hours of one day as columns, each cell shaded by what that hour
// is in that city — accent for business hours, a mid tint at the edges,
// quiet for the night. Hovering a column slides a time across every row
// (each city's header shows what it would be then); clicking pins it, and
// the copy line shares the alignment.
//
// The design is fixed-proportion: 24 cells of one size, one single-line
// row per city. What keeps text untrimmed is that the two text columns are
// measured from the strings they will actually carry — the city column
// grows to its widest name, the time slot reserves the weekday-marked
// worst case — instead of hard-coded widths. On a screen too small for
// the full panel the hour cells yield width first (color compresses
// gracefully; text does not), and only a screen far too small falls back
// to eliding.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "io.github.captainawesomedi.omaclock"
  ipcTarget: "io.github.captainawesomedi.omaclock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel; the popout coordinator compares slot.activeItem.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings -----------------------------------------------------------

  readonly property int businessStart: Math.max(0, Math.min(23, parseInt(setting("businessStart", 9)) || 9))
  readonly property int businessEnd: Math.max(1, Math.min(24, parseInt(setting("businessEnd", 18)) || 18))
  readonly property bool use24h: setting("use24h", true) === true
  // The saved cities, straight from shell.json with the demonstrated seed
  // as the fallback — a binding, so a settings write (ours or the bar's)
  // reflows the rows on its own.
  property var savedZones: normalizeZones(setting("zones",
    ["Europe/London", "America/New_York", "Asia/Tokyo"]))

  function normalizeZones(value) {
    if (!value) return []
    if (typeof value === "string") return value.length > 0 ? [value] : []
    var out = []
    for (var i = 0; i < value.length; i++)
      if (value[i] && out.indexOf(value[i]) < 0) out.push(value[i])
    return out
  }

  // Zones in row order: home pinned first, then the saved list without it.
  property var zoneIds: [""]
  function rebuildZoneIds() {
    var list = [zones.homeId]
    var saved = normalizeZones(savedZones)
    for (var i = 0; i < saved.length; i++)
      if (saved[i] !== zones.homeId) list.push(saved[i])
    zoneIds = list
  }

  // ---- State --------------------------------------------------------------

  property date today: new Date()
  property int dayOffset: 0
  property int hoverHour: -1
  property int pinnedHour: -1
  property bool pickerOpen: false
  property string pickerFilter: ""
  property bool copied: false

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.today = date
  }

  readonly property var viewDate: Model.addDays(today, dayOffset)
  readonly property real viewDayStart: Model.dayStartEpoch(viewDate)
  readonly property int currentHour: today.getHours()
  readonly property int activeHour: hoverHour >= 0 ? hoverHour : pinnedHour

  Zones {
    id: zones
    ids: root.zoneIds
    dayStart: root.viewDayStart
    onRefreshed: root.rebuildRows()
  }

  onSavedZonesChanged: rebuildZoneIds()

  // The home id resolves asynchronously from /etc/localtime.
  Connections {
    target: zones
    function onHomeIdChanged() { root.rebuildZoneIds() }
  }

  // ---- The rows: everything the grid and headers render -------------------

  property var rows: []

  function homeLabel() {
    return zones.homeId !== "" ? Model.splitZoneId(zones.homeId).city : "Local"
  }

  function selectionPartsFor(id) {
    if (activeHour < 0) {
      var nowOff = zones.nowOffsetFor(id)
      return Model.wallParts(Math.floor(Date.now() / 1000), nowOff)
    }
    var off = zones.offsetFor(id, activeHour)
    if (off === null) off = zones.nowOffsetFor(id)
    return Model.wallParts(viewDayStart + activeHour * 3600, off)
  }

  function rebuildRows() {
    if (!zones.offsets) { rows = []; return }
    var localOff = zones.localOffsetSeconds()
    var out = []
    for (var i = 0; i < zoneIds.length; i++) {
      var id = zoneIds[i]
      var split = id !== "" ? Model.splitZoneId(id) : { city: homeLabel(), region: "" }
      var cells = []
      for (var h = 0; h < 24; h++) {
        var off = zones.offsetFor(id, h)
        if (off === null) { cells.push({ band: 0 }); continue }
        var wall = Model.wallParts(viewDayStart + h * 3600, off)
        cells.push({ band: Model.bandForHour(wall.h, businessStart, businessEnd) })
      }
      out.push({
        id: id,
        city: split.city,
        region: split.region,
        isHome: i === 0,
        delta: Model.offsetLabel(zones.nowOffsetFor(id) - localOff),
        selectionParts: selectionPartsFor(id),
        cells: cells
      })
    }
    rows = out
  }

  onActiveHourChanged: rebuildRows()
  onBusinessStartChanged: rebuildRows()
  onBusinessEndChanged: rebuildRows()
  onUse24hChanged: rebuildRows()

  // ---- Persistence --------------------------------------------------------

  function persistSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    // Applied locally first so the change lands on the click itself; the
    // shell.json write comes back through the bar as the same value (and
    // the settings-derived bindings follow it).
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function persistZones(newZones) {
    persistSetting("zones", newZones)
  }

  // The footer chip: Local → second city → each other saved city.
  function cycleBarZone() {
    persistSetting("barZone",
      Model.nextBarZone(String(setting("barZone", "saved") || ""), normalizeZones(savedZones)))
  }

  function addZone(id) {
    if (id === zones.homeId || zoneIds.indexOf(id) >= 0) return
    var saved = normalizeZones(savedZones)
    saved.push(id)
    persistZones(saved)
  }

  function removeZone(id) {
    var saved = []
    for (var i = 0; i < savedZones.length; i++)
      if (savedZones[i] !== id) saved.push(savedZones[i])
    persistZones(saved)
  }

  // ---- Copy ---------------------------------------------------------------

  function copySelection() {
    if (pinnedHour < 0 || rows.length === 0) return
    Quickshell.clipboardText = Model.copyLine(rows, pinnedHour, use24h)
    copied = true
    copiedFlash.restart()
  }

  Timer { id: copiedFlash; interval: 1200; onTriggered: root.copied = false }

  // ---- The open/close contract (as the clock panel) -----------------------

  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (pickerOpen) closePicker()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refresh() {
    root.today = new Date()
    zones.refresh()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Day chips ------------------------------------------------------------

  readonly property var dayChips: {
    var chips = []
    for (var o = -1; o <= 5; o++) {
      var d = Model.addDays(today, o)
      chips.push({ offset: o, label: Model.weekdayNames[d.getDay()] + " " + d.getDate() })
    }
    return chips
  }

  function movePinned(delta) {
    var base = pinnedHour >= 0 ? pinnedHour : currentHour
    pinnedHour = ((base + delta) % 24 + 24) % 24
    hoverHour = -1
  }

  function closePicker() {
    pickerOpen = false
    pickerFilter = ""
  }

  // ---- Theming ------------------------------------------------------------

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // The three bands, each a touch stronger under the active hour so the
  // slider column reads as one stripe across every row.
  function bandColor(band, active) {
    if (band === 2) return Qt.alpha(Color.accent, active ? 0.85 : 0.45)
    if (band === 1) return Qt.alpha(contentForeground, active ? 0.30 : 0.16)
    return Qt.alpha(contentForeground, active ? 0.10 : 0.05)
  }

  // ---- Layout ---------------------------------------------------------------
  //
  // The approved fixed-proportion grid, with the two text columns measured
  // instead of hard-coded. Measuring writes a TextMetrics' text and reads
  // its advance, which loops inside a binding — so the numbers are plain
  // properties set by remeasure(), re-run whenever the rows or the font
  // change.

  TextMetrics {
    id: tmBody
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.bodySmall
  }
  TextMetrics {
    id: tmCaption
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
  }

  function measuredWidth(m, text) {
    m.text = text
    return m.advanceWidth
  }

  property real timeSlotWidth: Style.space(52)
  property real cityTextWidth: Style.space(128)

  function remeasure() {
    // The time slot reserves the widest string it can ever carry — the
    // weekday mark plus the time — in both clock formats, so hovering and
    // format flips never reflow it and every row's time shares one right
    // edge.
    var t12 = measuredWidth(tmBody, "Wed 12:59p")
    var t24 = measuredWidth(tmBody, "Wed 00:00")
    timeSlotWidth = Math.ceil(Math.max(t12, t24)) + Style.space(2)

    // The city column: the widest single line among the rows' names and
    // their sub-labels, at least the classic width, at most a generous
    // cap past which (huge text scale, very long names) eliding takes
    // over as the last resort.
    var w = Style.space(128)
    for (var i = 0; i < rows.length; i++) {
      w = Math.max(w, measuredWidth(tmBody, rows[i].city))
      var sub = rows[i].region === "" || rows[i].isHome
        ? rows[i].delta : rows[i].region + " · " + rows[i].delta
      w = Math.max(w, measuredWidth(tmCaption, sub))
    }
    cityTextWidth = Math.ceil(Math.min(w, Style.space(200)))
  }

  onRowsChanged: remeasure()
  onContentFontFamilyChanged: remeasure()
  Component.onCompleted: remeasure()

  readonly property int cellHeight: Style.space(28)
  readonly property int rowHeight: Style.space(38)
  readonly property int removeSlot: Style.space(22)

  readonly property real cityColWidth: Style.space(8) + cityTextWidth
    + Style.space(12) + timeSlotWidth + removeSlot + Style.space(4)

  // Cell size: the design's 24 at full width, easing down to 14 when the
  // screen cannot give the panel its natural room — the grid keeps its
  // look, just denser, and the labels step out of its way.
  readonly property real cellDesign: Style.space(24)
  readonly property real cellMin: Style.space(14)
  readonly property real cellWidth: {
    var avail = planner.width - cityColWidth
    if (avail >= cellDesign * 24) return cellDesign
    return Math.max(cellMin, Math.floor(avail / 24))
  }
  readonly property real gridWidth: cellWidth * 24

  // One label every stride hours — three at full size, sparser only as the
  // cells compress — plus today's current hour wherever it falls. A rhythm
  // that divides 24 keeps the marked hours regular.
  readonly property int hourStride: cellWidth >= Style.space(22) ? 3
    : cellWidth >= Style.space(18) ? 4
    : cellWidth >= Style.space(15) ? 6 : 12

  // ---- The panel ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // Width = the measured content plus headroom: KeyboardPanel keeps its
    // own frame inset, and sizing to the bare grid would shave the last
    // column into the edge (the clock panel gives its calendar the same
    // slack).
    contentWidth: panel.fittedContentWidth(root.cityColWidth + root.cellDesign * 24 + Style.space(88))
    contentHeight: panel.fittedContentHeight(bodyColumn.implicitHeight + Style.space(24))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { root.movePinned(dx) }
      onActivateRequested: root.copySelection()
      onCloseRequested: {
        if (root.pickerOpen) root.closePicker()
        else root.close()
      }
    }

    Column {
      id: bodyColumn
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(14)

      // -- Header: the date and copy action on one line, the day chips on
      //    their own line below — the chips need the grid's full width, so
      //    sharing a band with the title only ever collides.
      Item {
        width: parent.width
        height: headerRow.height + chipsRow.height + Style.space(6)
        implicitHeight: height

        Item {
          id: headerRow
          width: parent.width
          height: Math.max(titleText.implicitHeight, Style.space(28))

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - copyChip.width - Style.space(12)
            elide: Text.ElideRight
            text: Qt.formatDateTime(root.viewDate, "dddd, d MMMM")
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.weight: Font.DemiBold
          }

          // Copy: enabled once a column is pinned.
          Rectangle {
            id: copyChip
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: copyLabel.implicitWidth + Style.space(18)
            height: Style.space(28)
            radius: Style.space(8)
            opacity: root.pinnedHour >= 0 ? 1 : 0.4
            color: copyHit.containsMouse && root.pinnedHour >= 0
              ? Qt.alpha(Color.accent, 0.25)
              : Qt.alpha(root.contentForeground, 0.07)

            Text {
              id: copyLabel
              anchors.centerIn: parent
              text: root.copied ? "Copied" : "Copy time"
              color: root.copied ? Color.accent : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: copyHit
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.copySelection()
            }
          }
        }

        Row {
          id: chipsRow
          anchors.top: headerRow.bottom
          anchors.topMargin: Style.space(6)
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(4)

          Rectangle {  // ‹ step back
            width: Style.space(26); height: Style.space(26)
            radius: Style.cornerRadius
            color: backHit.containsMouse ? Qt.alpha(root.contentForeground, 0.12) : "transparent"
            Text { anchors.centerIn: parent; text: "‹"; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.body }
            MouseArea { id: backHit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.dayOffset-- }
          }

          Repeater {
            model: root.dayChips

            Rectangle {
              required property var modelData
              width: chipLabel.implicitWidth + Style.space(14)
              height: Style.space(26)
              radius: Style.space(8)
              color: modelData.offset === root.dayOffset
                ? Color.accent
                : (chipHit.containsMouse ? Qt.alpha(root.contentForeground, 0.12) : Qt.alpha(root.contentForeground, 0.05))

              Text {
                id: chipLabel
                anchors.centerIn: parent
                text: modelData.offset === 0 ? "Today" : modelData.label
                color: modelData.offset === root.dayOffset ? Color.background : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.weight: modelData.offset === root.dayOffset ? Font.DemiBold : Font.Normal
              }

              MouseArea {
                id: chipHit
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.dayOffset = modelData.offset; root.pinnedHour = -1 }
              }
            }
          }

          Rectangle {  // › step forward
            width: Style.space(26); height: Style.space(26)
            radius: Style.cornerRadius
            color: fwdHit.containsMouse ? Qt.alpha(root.contentForeground, 0.12) : "transparent"
            Text { anchors.centerIn: parent; text: "›"; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.body }
            MouseArea { id: fwdHit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.dayOffset++ }
          }
        }
      }

      // -- The planner grid.
      Item {
        id: planner
        width: parent.width
        height: hourHeader.height + root.rows.length * root.rowHeight
        implicitHeight: height

        // City header column.
        Column {
          id: cityColumn
          anchors.left: parent.left
          width: root.cityColWidth

          Item { width: parent.width; height: hourHeader.height }

          Repeater {
            model: root.rows

            Item {
              required property var modelData
              required property int index
              width: root.cityColWidth
              height: root.rowHeight

              // The row's hover wash and click target.
              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(1)
                radius: Style.space(8)
                color: rowHit.containsMouse ? Qt.alpha(root.contentForeground, 0.06) : "transparent"
              }

              MouseArea {
                id: rowHit
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { if (root.activeHour >= 0) { root.pinnedHour = root.activeHour; root.copySelection() } }
              }

              // City and region get the space the time and remove mark
              // don't: fixed end slots mean the texts can never meet, and
              // the remove mark holds its slot even while invisible so
              // nothing shifts under the pointer. The column itself is
              // measured (cityTextWidth), so the elide below is a last
              // resort for screens far too small, not the norm.
              readonly property int rowRemoveSlot: modelData.isHome ? 0 : root.removeSlot

              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - parent.rowRemoveSlot - root.timeSlotWidth - Style.space(20)

                Text {
                  width: parent.width
                  text: modelData.city
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.DemiBold
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: modelData.region === "" || modelData.isHome ? modelData.delta
                      : modelData.region + " · " + modelData.delta
                  color: Qt.alpha(root.contentForeground, 0.55)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              // The live time: the city's time now, or at the hour under
              // the pointer — the planner's core read-out. A day that
              // differs from home's carries the weekday; the slot is
              // measured for that worst case, so the mark never trims it.
              Text {
                anchors.right: parent.right
                anchors.rightMargin: parent.rowRemoveSlot + Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: root.timeSlotWidth
                horizontalAlignment: Text.AlignRight
                text: {
                  var home = root.rows.length > 0 ? root.rows[0].selectionParts : null
                  var mark = home && modelData.selectionParts.d !== home.d
                    ? Model.weekdayNames[modelData.selectionParts.wd] + " " : ""
                  return mark + Model.wallTimeText(modelData.selectionParts, root.use24h)
                }
                color: root.activeHour >= 0 ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideLeft
              }

              // The remove mark: held slot, visible only under the pointer,
              // never on home.
              Item {
                visible: !modelData.isHome
                anchors.right: parent.right
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(20)
                height: width

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  opacity: rowHit.containsMouse ? 1 : 0
                  color: removeHit.containsMouse ? Qt.alpha(root.contentForeground, 0.2) : Qt.alpha(root.contentForeground, 0.08)

                  Behavior on opacity { NumberAnimation { duration: 90 } }

                  Text {
                    anchors.centerIn: parent
                    text: "×"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: removeHit
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.removeZone(modelData.id)
                }
              }
            }
          }
        }

        // Hour header + cell rows.
        Column {
          id: gridColumn
          anchors.left: parent.left
          anchors.leftMargin: root.cityColWidth
          width: root.gridWidth

          // The hour header: local hours of the displayed day on the
          // stride; today's current hour carries the marker.
          Item {
            id: hourHeader
            width: root.gridWidth
            height: Style.space(22)

            Row {
              Repeater {
                model: 24

                Item {
                  required property int index
                  width: root.cellWidth
                  height: hourHeader.height

                  readonly property bool labeled: index % root.hourStride === 0
                    || (index === root.currentHour && root.dayOffset === 0)

                  Text {
                    anchors.centerIn: parent
                    visible: parent.labeled
                    text: Model.hourLabel(index, root.use24h)
                    color: index === root.currentHour && root.dayOffset === 0
                      ? Color.accent
                      : Qt.alpha(root.contentForeground, 0.65)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Rectangle {
                    visible: index === root.currentHour && root.dayOffset === 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: Math.min(Style.space(14), root.cellWidth - Style.space(2))
                    height: Style.space(2)
                    radius: height / 2
                    color: Color.accent
                  }
                }
              }
            }
          }

          Repeater {
            model: root.rows

            Item {
              required property var modelData
              width: root.gridWidth
              height: root.rowHeight

              Row {
                Repeater {
                  model: modelData.cells

                  Rectangle {
                    required property var modelData
                    required property int index
                    width: root.cellWidth
                    height: root.cellHeight
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Math.min(Style.space(4), width / 2)
                    color: root.bandColor(modelData.band, index === root.activeHour)
                    border.width: index === root.pinnedHour ? 1 : 0
                    border.color: Color.accent
                  }
                }
              }
            }
          }
        }

        // The hover strips: one column-wide hover/click target spanning all
        // rows — the slider. Hovering slides, clicking pins (or unpins).
        Row {
          id: strips
          x: root.cityColWidth
          y: hourHeader.height
          width: root.gridWidth
          height: planner.height - hourHeader.height
          z: 10

          Repeater {
            model: 24

            MouseArea {
              required property int index
              width: root.cellWidth
              height: strips.height
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.hoverHour = index
              onExited: { if (root.hoverHour === index) root.hoverHour = -1 }
              onClicked: {
                root.pinnedHour = root.pinnedHour === index ? -1 : index
              }
            }
          }
        }
      }

      // -- Footer: the legend and the add-city door.
      Item {
        width: parent.width
        height: Math.max(legendRow.implicitHeight, Style.space(28))
        implicitHeight: height

        Row {
          id: legendRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Row {
            spacing: Style.space(5)
            Rectangle { width: Style.space(10); height: Style.space(10); radius: 3; color: Qt.alpha(Color.accent, 0.45); anchors.verticalCenter: parent.verticalCenter }
            Text { text: root.businessStart + "–" + root.businessEnd; color: Qt.alpha(root.contentForeground, 0.55); font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
          }
          Row {
            spacing: Style.space(5)
            Rectangle { width: Style.space(10); height: Style.space(10); radius: 3; color: Qt.alpha(root.contentForeground, 0.16); anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Edges"; color: Qt.alpha(root.contentForeground, 0.55); font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
          }
          Row {
            spacing: Style.space(5)
            Rectangle { width: Style.space(10); height: Style.space(10); radius: 3; color: Qt.alpha(root.contentForeground, 0.05); border.width: 1; border.color: Qt.alpha(root.contentForeground, 0.2); anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Night"; color: Qt.alpha(root.contentForeground, 0.55); font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
          }
        }

        // Right side: which zone the bar label shows (cycles Local →
        // second city → other saved cities), then the add-city door.
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Rectangle {
            id: barChip
            width: barChipLabel.implicitWidth + Style.space(14)
            height: Style.space(28)
            radius: Style.space(8)
            color: barChipHit.containsMouse ? Qt.alpha(Color.accent, 0.25) : Qt.alpha(root.contentForeground, 0.07)

            Text {
              id: barChipLabel
              anchors.centerIn: parent
              text: "Bar: " + Model.barZoneLabel(
                String(root.setting("barZone", "saved") || ""),
                root.normalizeZones(root.savedZones))
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: barChipHit
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cycleBarZone()
            }
          }

          Rectangle {
            width: addLabel.implicitWidth + Style.space(18)
            height: Style.space(28)
            radius: Style.space(8)
            color: addHit.containsMouse ? Qt.alpha(Color.accent, 0.25) : Qt.alpha(root.contentForeground, 0.07)

            Text {
              id: addLabel
              anchors.centerIn: parent
              text: "+ Add city"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: addHit
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.pickerOpen = !root.pickerOpen; if (root.pickerOpen) pickerField.forceActiveFocus() }
            }
          }
        }
      }

      // -- The pinned read-out: what the pinned hour is everywhere, in
      //    full — it wraps rather than trim, since a clipped share line
      //    is exactly the information this panel exists to give.
      Text {
        visible: root.pinnedHour >= 0 && root.rows.length > 0
        width: parent.width
        wrapMode: Text.WrapAnywhere
        horizontalAlignment: Text.AlignHCenter
        text: visible ? Model.copyLine(root.rows, root.pinnedHour, root.use24h) : ""
        color: Qt.alpha(root.contentForeground, 0.75)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // -- The city picker: type-to-filter over the IANA catalog.
    Rectangle {
      id: picker
      visible: root.pickerOpen
      anchors.fill: parent
      anchors.margins: Style.space(12)
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: 1
      border.color: Color.popups.border
      z: 20

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: pickerField
              width: parent.width - pickerClose.width - Style.space(8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            color: root.contentForeground
            placeholderText: "Search cities — try “tok” or “berlin”"
            onTextChanged: root.pickerFilter = text
            onAccepted: {
              var ranked = Model.rankZones(zones.catalog, root.pickerFilter)
              if (ranked.length > 0) { root.addZone(ranked[0].id); root.closePicker() }
            }
            Keys.onEscapePressed: root.closePicker()
          }

          Rectangle {
            id: pickerClose
            width: pickerCloseLabel.implicitWidth + Style.space(18)
            height: pickerField.height
            radius: Style.space(8)
            anchors.verticalCenter: pickerField.verticalCenter
            color: pickerCloseHit.containsMouse ? Qt.alpha(root.contentForeground, 0.15) : Qt.alpha(root.contentForeground, 0.07)

            Text {
              id: pickerCloseLabel
              anchors.centerIn: parent
              text: "Close"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: pickerCloseHit
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closePicker()
            }
          }
        }

        ListView {
          id: pickerList
          width: parent.width
          height: parent.height - pickerField.height - Style.space(8)
          clip: true
          spacing: 2
          model: Model.rankZones(zones.catalog, root.pickerFilter)

          delegate: Rectangle {
            required property var modelData
            width: pickerList.width
            height: Math.max(Style.space(34), pickerTexts.implicitHeight + Style.space(10))
            radius: Style.space(8)
            color: pickHit.containsMouse ? Qt.alpha(root.contentForeground, 0.1) : "transparent"

            Column {
              id: pickerTexts
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(52)

              Text {
                width: parent.width
                text: modelData.city
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                // An alias hit shows the alias ("Cork · Europe/Dublin"), a
                // country hit the country ("Ireland · Europe/Dublin"); a
                // plain city match keeps region · id.
                text: (modelData.why || modelData.country || modelData.region)
                  + " · " + modelData.id
                color: Qt.alpha(root.contentForeground, 0.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }

            Text {
              visible: root.zoneIds.indexOf(modelData.id) >= 0
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "✓"
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: pickHit
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.addZone(modelData.id); root.closePicker() }
            }
          }
        }
      }
    }
  }
}
