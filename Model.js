// Pure logic for the omaclock widget: the zone catalog, the shell of wall-
// time math, and the small formatters. Everything here is stateless — the
// Zones engine owns the subprocess-fed offsets, the panel owns state.
.pragma library

// ---- The catalog -----------------------------------------------------------

// IANA's backward links (US/*, Canada/*, …) and the Etc/* offsets are
// skipped; bare UTC stays. City comes from the last path segment, region
// from the middle segment when the area splits a country.
var backwardRoots = {
  US: 1, Canada: 1, Brazil: 1, Chile: 1, Mexico: 1, Cuba: 1, Egypt: 1,
  GB: 1, "GB-Etc": 1, Hongkong: 1, Iceland: 1, Iran: 1, Israel: 1,
  Japan: 1, Kwajalein: 1, Libya: 1, Navajo: 1, Poland: 1, Portugal: 1,
  ROC: 1, ROK: 1, Singapore: 1, Turkey: 1, SystemV: 1
}
var skippedExact = {
  GMT: 1, GMT0: 1, "GMT+0": 1, "GMT-0": 1, Universal: 1, Zulu: 1,
  localtime: 1, EST: 1, MST: 1, HST: 1, EST5EDT: 1, CST6CDT: 1,
  MST7MDT: 1, PST8PDT: 1, Factory: 1
}

function isSkippedId(id) {
  if (skippedExact[id]) return true
  if (id === "UTC") return false
  var root = id.split("/")[0]
  return backwardRoots[root] === 1 || root === "Etc"
}

function titleCaseSegment(segment) {
  var atStart = true
  var out = ""
  for (var i = 0; i < segment.length; i++) {
    var c = segment[i]
    if (c === "_") { out += " "; atStart = true }
    else if (atStart) { out += c.toUpperCase(); atStart = false }
    else out += c.toLowerCase()
  }
  return out
}

// "America/Argentina/Buenos_Aires" → city "Buenos Aires", region
// "Argentina"; two-segment ids keep the area as the region.
function splitZoneId(id) {
  var parts = id.split("/")
  if (parts.length < 2) return { city: id, region: "" }
  return {
    city: titleCaseSegment(parts[parts.length - 1]),
    region: titleCaseSegment(parts.length > 2 ? parts[parts.length - 2] : parts[0])
  }
}

function parseZoneTab(text, countryNames) {
  var zones = []
  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length === 0 || line[0] === "#") continue
    var fields = line.split(/\s+/)
    if (fields.length < 3) continue
    var id = fields[2]
    if (isSkippedId(id)) continue
    var country = countryNames ? (countryNames[fields[0]] || "") : ""
    if (id === "UTC") {
      zones.push({ id: id, city: "UTC", region: "UTC", country: country })
      continue
    }
    var parts = splitZoneId(id)
    zones.push({ id: id, city: parts.city, region: parts.region, country: country })
  }
  return zones
}

// Cities the tz database does not name — zone.tab carries one representative
// city per zone, so "Cork" (Europe/Dublin), "New Delhi" (Asia/Kolkata) and
// "Osaka" (Asia/Tokyo) would otherwise find nothing. Each alias resolves to
// its zone's id; the picker shows the alias as the reason a row matched.
var zoneAliases = {
  "Europe/Dublin":       ["Cork", "Limerick", "Galway", "Waterford"],
  "Europe/London":       ["Belfast", "Londonderry"],
  "Europe/Paris":        ["Lyon", "Marseille", "Nice", "Toulouse"],
  "Europe/Berlin":       ["Munich", "Hamburg", "Frankfurt", "Cologne"],
  "Europe/Madrid":       ["Barcelona", "Seville"],
  "Europe/Rome":         ["Milan", "Naples", "Venice", "Florence", "Turin"],
  "Europe/Moscow":       ["Saint Petersburg"],
  "Europe/Lisbon":       ["Porto"],
  "Europe/Amsterdam":    ["Rotterdam", "The Hague"],
  "Asia/Kolkata":        ["New Delhi", "Delhi", "Mumbai", "Bombay", "Bangalore",
                          "Bengaluru", "Chennai", "Madras", "Hyderabad", "Pune"],
  "Asia/Tokyo":          ["Osaka", "Kyoto", "Nagoya", "Sapporo", "Yokohama", "Kobe"],
  "Asia/Seoul":          ["Busan"],
  "Asia/Shanghai":       ["Beijing", "Peking", "Shenzhen", "Guangzhou", "Hangzhou"],
  "Asia/Dubai":          ["Abu Dhabi", "Sharjah"],
  "America/New_York":    ["Boston", "Philadelphia", "Washington", "Manhattan", "Brooklyn"],
  "America/Chicago":     ["Houston", "Austin", "Dallas"],
  "America/Denver":      ["Boulder", "Salt Lake City"],
  "America/Los_Angeles": ["Seattle", "San Francisco", "San Jose", "Mountain View",
                          "Palo Alto", "Sunnyvale", "Cupertino", "Santa Clara",
                          "Silicon Valley", "Portland", "Las Vegas"],
  "America/Toronto":     ["Ottawa", "Montreal"],
  "America/Mexico_City": ["Guadalajara", "Monterrey"],
  "America/Sao_Paulo":   ["Rio de Janeiro"]
}

// If zone.tab cannot be read, a hand-picked spread of the world still makes
// the picker usable; the ids are all real IANA names.
function fallbackZones() {
  var ids = [
    "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles",
    "America/Vancouver", "America/Denver", "America/Chicago",
    "America/Mexico_City", "America/New_York", "America/Toronto",
    "America/Bogota", "America/Sao_Paulo", "America/Argentina/Buenos_Aires",
    "Atlantic/Reykjavik", "Europe/London", "Europe/Dublin", "Europe/Lisbon",
    "Europe/Madrid", "Europe/Paris", "Europe/Brussels", "Europe/Amsterdam",
    "Europe/Berlin", "Europe/Zurich", "Europe/Rome", "Europe/Stockholm",
    "Europe/Oslo", "Europe/Copenhagen", "Europe/Warsaw", "Europe/Prague",
    "Europe/Vienna", "Europe/Budapest", "Europe/Athens", "Europe/Helsinki",
    "Europe/Kyiv", "Europe/Istanbul", "Europe/Moscow", "Africa/Casablanca",
    "Africa/Lagos", "Africa/Cairo", "Africa/Nairobi", "Africa/Johannesburg",
    "Asia/Jerusalem", "Asia/Riyadh", "Asia/Tehran", "Asia/Dubai",
    "Asia/Karachi", "Asia/Kolkata", "Asia/Colombo", "Asia/Kathmandu",
    "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Singapore",
    "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Taipei", "Asia/Manila",
    "Asia/Seoul", "Asia/Tokyo", "Australia/Perth", "Australia/Adelaide",
    "Australia/Sydney", "Australia/Brisbane", "Pacific/Auckland",
    "Pacific/Fiji", "UTC"
  ]
  var zones = []
  for (var i = 0; i < ids.length; i++) {
    var parts = splitZoneId(ids[i])
    zones.push({ id: ids[i], city: parts.city, region: parts.region })
  }
  return zones
}

// The picker's ranked list, in omaunits' ladder: exact city, city prefix,
// then — for the cities zone.tab does not name and for country names —
// alias and country matches, then any substring of city/region/id/country.
// Results carry `why` (the alias or country that matched) so the picker can
// say "Cork · Europe/Dublin" instead of a bare city.
function rankZones(catalog, filter) {
  var needle = String(filter || "").trim().toLowerCase().replace(/\s+/g, " ")
  if (needle === "") return catalog.slice(0, 60)
  var ranked = []
  for (var i = 0; i < catalog.length; i++) {
    var z = catalog[i]
    var city = z.city.toLowerCase()
    var region = (z.region || "").toLowerCase()
    var country = (z.country || "").toLowerCase()
    var score = -1
    var why = null
    if (city === needle) {
      score = 0
    } else if (city.indexOf(needle) === 0) {
      score = 1
    } else {
      var aliases = zoneAliases[z.id] || []
      for (var a = 0; a < aliases.length; a++) {
        var aliasLower = aliases[a].toLowerCase()
        if (aliasLower === needle) { if (score < 1) { score = 1; why = aliases[a] } }
        else if (aliasLower.indexOf(needle) === 0) { if (score < 2) { score = 2; why = aliases[a] } }
      }
      if (country && (country === needle || country.indexOf(needle) === 0)) {
        if (score < 2) { score = 2; why = z.country }
      }
      if (score < 0) {
        if ((city + " " + region + " " + z.id.toLowerCase() + " " + country).indexOf(needle) >= 0) {
          score = 3
        } else {
          for (var b = 0; b < aliases.length; b++) {
            if (aliases[b].toLowerCase().indexOf(needle) >= 0) { score = 3; why = aliases[b]; break }
          }
        }
      }
    }
    if (score >= 0) ranked.push({ score: score, index: i, why: why })
  }
  ranked.sort(function(a, b) { return a.score - b.score || a.index - b.index })
  var out = []
  for (var j = 0; j < ranked.length; j++) {
    var hit = catalog[ranked[j].index]
    out.push({
      id: hit.id, city: hit.city, region: hit.region,
      country: hit.country || "", why: ranked[j].why
    })
  }
  return out
}

// ---- Wall-time math --------------------------------------------------------
//
// Qt's QML engine has no Intl, so offsets come from the Zones engine's
// `date` samples; everything else is arithmetic on UTC decompositions.

// Local midnight of a Date, as epoch seconds.
function dayStartEpoch(d) {
  var midnight = new Date(d.getFullYear(), d.getMonth(), d.getDate())
  return Math.floor(midnight.getTime() / 1000)
}

function addDays(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days)
}

// A wall clock read: the date-time a clock in that zone shows at the given
// instant. Fields come from the UTC decomposition of instant + offset.
function wallParts(epochSeconds, offsetSeconds) {
  var d = new Date((epochSeconds + offsetSeconds) * 1000)
  return {
    y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate(),
    h: d.getUTCHours(), min: d.getUTCMinutes(), wd: d.getUTCDay()
  }
}

var weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function two(n) { return n < 10 ? "0" + n : "" + n }

function wallTimeText(parts, use24h) {
  if (use24h) return two(parts.h) + ":" + two(parts.min)
  var h12 = parts.h % 12
  if (h12 === 0) h12 = 12
  return h12 + ":" + two(parts.min) + (parts.h < 12 ? "a" : "p")
}

// Column header labels: 24-hour runs the day 0–23; 12-hour marks am/pm.
function hourLabel(h, use24h) {
  if (use24h) return two(h)
  var h12 = h % 12
  if (h12 === 0) h12 = 12
  return "" + h12 + (h < 12 ? "a" : "p")
}

// "+3h", "-8h", "+5h30" (half-hour zones), "0h" for home.
function offsetLabel(deltaSeconds) {
  var sign = deltaSeconds < 0 ? "-" : "+"
  var abs = Math.abs(deltaSeconds)
  var hours = Math.floor(abs / 3600)
  var minutes = Math.floor((abs % 3600) / 60)
  var text = (abs === 0 ? "" : sign) + hours + "h"
  if (minutes > 0) text += two(minutes)
  return text
}

// The hour bands: business inside the configured window, shoulder at its
// edges (7am to start, end to 10pm), night otherwise.
function bandForHour(hour, businessStart, businessEnd) {
  if (hour >= businessStart && hour < businessEnd) return 2  // business
  if (hour >= 7 && hour < businessStart) return 1            // morning edge
  if (hour >= businessEnd && hour < 22) return 1             // evening edge
  return 0                                                   // night
}

// The shareable line a pinned time copies: weekday shown only where a
// city's calendar day differs from home's, worldtimebuddy's convention.
function copyLine(rows, pinnedHour, use24h) {
  var parts = []
  var homeDay = null
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (i === 0) homeDay = r.selectionParts.d
    var dayMark = r.selectionParts.d !== homeDay ? weekdayNames[r.selectionParts.wd] + " " : ""
    parts.push(dayMark + wallTimeText(r.selectionParts, use24h) + " " + r.city)
  }
  return parts.join(" · ")
}

// ---- The bar label's zone --------------------------------------------------
//
// The bar can show any zone instead of local time (the built-in clock owns
// local). "" is local, "saved" follows the first saved city, otherwise a
// zone id.

// "±HHMM" (coreutils `date +%z`) → seconds.
function parseOffsetLine(line) {
  var t = String(line).trim()
  if (t.length < 5) return null
  var sign = t[0] === "-" ? -1 : 1
  var hours = parseInt(t.substring(1, 3), 10)
  var minutes = parseInt(t.substring(3, 5), 10)
  if (isNaN(hours) || isNaN(minutes)) return null
  return sign * (hours * 3600 + minutes * 60)
}

// The cycle the bar chip and IPC walk: second city ("saved") → each other
// saved zone, wrapping. Local is deliberately not in the cycle — the
// built-in clock already owns local — though `barZone` still accepts ""
// for anyone who sets it by hand.
function nextBarZone(current, savedZones) {
  var cur = current === "local" ? "" : current
  if (savedZones.length === 0) return "saved"
  var list = ["saved"]
  for (var i = 0; i < savedZones.length; i++)
    if (savedZones[i] !== savedZones[0]) list.push(savedZones[i])
  var at = list.indexOf(cur)
  return list[(at + 1 + list.length) % list.length]
}

// Human label for a barZone value: "Local" or the resolved city name.
function barZoneLabel(mode, savedZones) {
  var m = mode === "local" ? "" : mode
  if (m === "") return "Local"
  var id = m === "saved" ? (savedZones.length > 0 ? savedZones[0] : "") : m
  return id !== "" ? splitZoneId(id).city : "Local"
}
