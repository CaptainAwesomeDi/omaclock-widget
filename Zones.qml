import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The timezone engine. Qt's QML engine has no Intl and no arbitrary-zone
// formatting, so offsets come from coreutils `date`: one batched subprocess
// run samples every zone at each hour boundary of the displayed day (plus
// right now), and all wall-time math happens in JS on top of those samples.
// A run costs a few dozen `date` invocations and only happens when the day
// or the city list changes — never per tick.
Item {
  id: engine

  // The machine's own zone, resolved from /etc/localtime. Empty string
  // means "local" (the sampler then runs plain `date` with no TZ).
  property string homeId: ""

  // Zones to sample, home first. "" entries are sampled as local.
  property var ids: []

  // Local midnight of the displayed day, epoch seconds.
  property real dayStart: 0

  // offsets[id] = 25 second-offsets at hour boundaries 0..24 of dayStart;
  // nowOffsets[id] = the zone's current offset. Null until the first run.
  property var offsets: null
  property var nowOffsets: ({})

  // The picker's catalog: IANA city zones, zone.tab first, embedded
  // fallback second. Entries carry the country name (from iso3166.tab) so
  // searching "Ireland" or "Japan" works, not just city names.
  property var catalog: []

  property string _zoneTabText: ""
  property string _isoText: ""

  function rebuildCatalog() {
    var names = {}
    var lines = String(_isoText).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i].indexOf("\t")
      if (at < 2) continue
      names[lines[i].substring(0, at)] = lines[i].substring(at + 1).trim()
    }
    var parsed = _zoneTabText.length > 0
      ? Model.parseZoneTab(_zoneTabText, names) : []
    catalog = parsed.length > 0 ? parsed : Model.fallbackZones()
  }

  property var _pendingEpochs: []
  property var _pendingIds: []

  signal refreshed()

  readonly property int epochCount: 26  // 25 boundaries + now

  function localOffsetSeconds() {
    return -new Date().getTimezoneOffset() * 60
  }

  function offsetFor(id, hourIndex) {
    if (!offsets) return null
    var samples = offsets[id]
    if (!samples) return null
    var i = Math.max(0, Math.min(24, hourIndex))
    return samples[i]
  }

  function nowOffsetFor(id) {
    return nowOffsets[id] !== undefined ? nowOffsets[id] : localOffsetSeconds()
  }

  function refresh() {
    var effective = ids.length > 0 ? ids : [""]
    var epochs = []
    for (var h = 0; h <= 24; h++) epochs.push(Math.floor(dayStart + h * 3600))
    epochs.push(Math.floor(Date.now() / 1000))

    var script = ""
    for (var i = 0; i < effective.length; i++) {
      var prefix = effective[i] === "" ? "" : ("TZ=\"" + effective[i] + "\" ")
      for (var e = 0; e < epochs.length; e++)
        script += prefix + "date -d @" + epochs[e] + " +%z;"
    }

    _pendingEpochs = epochs
    _pendingIds = effective
    if (sampler.running) sampler.running = false
    sampler.command = ["sh", "-c", script]
    sampler.running = true
  }

  onIdsChanged: refresh()
  onDayStartChanged: refresh()
  Component.onCompleted: {
    homeResolver.command = ["sh", "-c", "readlink /etc/localtime || true"]
    homeResolver.running = true
    catalogLoader.command = ["cat", "/usr/share/zoneinfo/zone.tab"]
    catalogLoader.running = true
    countryLoader.command = ["cat", "/usr/share/zoneinfo/iso3166.tab"]
    countryLoader.running = true
  }

  function parseSamples(text) {
    var lines = String(text).split("\n")
    var newOffsets = {}
    var newNow = {}
    var expected = _pendingIds.length * epochCount
    var parsed = 0
    for (var i = 0; i < lines.length; i++) {
      var value = Model.parseOffsetLine(lines[i])
      if (value === null) continue
      if (parsed >= expected) break
      var zoneIndex = Math.floor(parsed / epochCount)
      var epochIndex = parsed % epochCount
      var id = _pendingIds[zoneIndex]
      if (epochIndex < 25) {
        if (!newOffsets[id]) newOffsets[id] = []
        newOffsets[id].push(value)
      } else {
        newNow[id] = value
      }
      parsed++
    }
    if (parsed === expected) {
      offsets = newOffsets
      nowOffsets = newNow
      refreshed()
    }
  }

  // The home zone: /etc/localtime is a symlink into the zoneinfo tree.
  Process {
    id: homeResolver
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      var link = String(text).trim()
      var marker = "zoneinfo/"
      var at = link.lastIndexOf(marker)
      engine.homeId = at >= 0 ? link.substring(at + marker.length) : ""
    } }
    onExited: engine.refresh()
  }

  Process {
    id: catalogLoader
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      engine._zoneTabText = String(text)
    } }
    onExited: function(exitCode) {
      if (exitCode !== 0) engine._zoneTabText = ""
      engine.rebuildCatalog()
    }
  }

  Process {
    id: countryLoader
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: {
      engine._isoText = String(text)
    } }
    onExited: function(exitCode) {
      if (exitCode !== 0) engine._isoText = ""
      engine.rebuildCatalog()
    }
  }

  Process {
    id: sampler
    running: false
    command: []
    stdout: StdioCollector { id: samplerOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) engine.parseSamples(samplerOut.text)
    }
  }
}
