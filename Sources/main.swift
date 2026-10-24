// Sun Dial: a menu bar app. The menu bar icon is a tiny dial; clicking it floats
// the full Earth, Sun and Moon over the desktop with no window around them.

import AppKit
import SwiftUI
import MapKit

// MARK: - Places

struct Place: Codable, Identifiable, Equatable {
    var id = UUID()
    let name: String
    let lon: Double

    /// Same name and within about 5 km of longitude: the same place, so it isn't added twice.
    func isSameSpot(as other: Place) -> Bool { name == other.name && abs(lon - other.lon) < 0.05 }
}

let defaultPlaces: [Place] = [
    Place(name: "San Jose", lon: -121.89),
    Place(name: "New York", lon: -74.0),
    Place(name: "London", lon: -0.13),
    Place(name: "Bangalore", lon: 77.59),
    Place(name: "Tokyo", lon: 139.69),
    Place(name: "Sydney", lon: 151.21),
]
/// Longitude of the place at the top of the dial (the first place).
var homeLon = defaultPlaces[0].lon

// MARK: - Sky math

func mod(_ a: Double, _ n: Double) -> Double { (a.truncatingRemainder(dividingBy: n) + n).truncatingRemainder(dividingBy: n) }
let rad = Double.pi / 180

/// Longitude where the sun is directly overhead, including the equation of time.
func subsolarLon(_ d: Date) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.hour, .minute, .second], from: d)
    let utcH = Double(c.hour!) + Double(c.minute!) / 60 + Double(c.second!) / 3600
    let n = Double(cal.ordinality(of: .day, in: .year, for: d)!)
    let b = 2 * Double.pi * (n - 81) / 364
    let eot = 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)
    return mod(-15 * (utcH - 12 + eot / 60) + 180, 360) - 180
}

/// Low-precision moon: good to about a degree.
func moonState(_ date: Date) -> (sublunarLon: Double, age: Double) {
    let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
    let l = 218.316 + 13.176396 * d, mm = 134.963 + 13.064993 * d, f = 93.272 + 13.22935 * d
    let lon = l + 6.289 * sin(mm * rad), lat = 5.128 * sin(f * rad)
    let e = 23.44 * rad
    let ra = atan2(sin(lon * rad) * cos(e) - tan(lat * rad) * sin(e), cos(lon * rad)) / rad
    let gmst = 280.46061837 + 360.98564736629 * d
    let g = 357.528 + 0.9856003 * d
    let sunLon = 280.46 + 0.9856474 * d + 1.915 * sin(g * rad) + 0.02 * sin(2 * g * rad)
    return (mod(ra - gmst + 180, 360) - 180, mod(lon - sunLon, 360))
}

func solarHour(_ lon: Double, _ ss: Double) -> Double { mod(12 + (lon - ss) / 15, 24) }
/// Clockwise degrees from the top. Places west of home are clockwise, where the sun goes next.
func dialAngle(_ lon: Double) -> Double { mod(homeLon - lon, 360) }
func polar(_ c: CGPoint, _ r: Double, _ deg: Double) -> CGPoint {
    CGPoint(x: c.x + r * sin(deg * rad), y: c.y - r * cos(deg * rad))
}
/// Day is warm amber, dawn and dusk are coral, night is a soft periwinkle.
func phaseColor(_ h: Double) -> Color {
    if h >= 6.5 && h < 17.5 { return Color(red: 1, green: 0.80, blue: 0.38) }
    if (h >= 5.5 && h < 6.5) || (h >= 17.5 && h < 18.5) { return Color(red: 1, green: 0.55, blue: 0.42) }
    return Color(red: 0.58, green: 0.65, blue: 1)
}
func fmtTime(_ h: Double) -> String {
    let m = Int((h * 60).rounded()) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
}

// MARK: - The floating dial

struct DialView: View {
    @ObservedObject var model: DialModel
    @StateObject private var search = CitySearch()
    @FocusState private var typing: Bool
    @State private var hovering = false
    @State private var adding = false
    @State private var settingHome = false
    @State private var overCancel = false
    @State private var shakes: CGFloat = 0
    @State private var notFound = false
    /// True while the pointer is over the Earth or its sky; the pips and center dot only show then.
    @State private var overDial = false
    static let r = 38.0
    /// The sky ring, where the sun and moon travel.
    static let skyR = r + 17, sunR = r + 28

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { tl in
            let c = CGPoint(x: DialModel.size / 2, y: DialModel.size / 2)
            let ss = subsolarLon(tl.date)
            ZStack {
                Canvas { ctx, size in draw(ctx, size, tl.date) }
                // Grab the Earth, sun or moon to move the whole dial around the screen.
                Circle().fill(Color.white.opacity(0.001))
                    .frame(width: 2 * (DialView.sunR + 12), height: 2 * (DialView.sunR + 12))
                    .position(x: c.x, y: c.y)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { _ in model.dragMove() }
                        .onEnded { _ in model.dragEnd() })
                    .onTapGesture { if adding { stopAdding() } }
                ForEach(model.places) { p in
                    PlaceChip(place: p, isHome: p.id == model.places.first?.id, hour: solarHour(p.lon, ss), center: c,
                              dragging: model.dragging, showPip: overDial || adding,
                              onRemove: { model.remove(p) }, onChangeHome: { startAdding(home: true) })
                }
                Group { if adding { searchBox } else { addSpot } }.position(x: c.x, y: c.y)
            }
            .onContinuousHover { phase in
                var over = false
                if case .active(let pt) = phase { over = hypot(pt.x - c.x, pt.y - c.y) < DialView.sunR + 16 }
                if over != overDial { withAnimation(.easeInOut(duration: 0.35)) { overDial = over } }
            }
        }
        .frame(width: DialModel.size, height: DialModel.size)
        .scaleEffect(model.shown ? 1 : 0.86)
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.shown)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: model.places)
        .onChange(of: model.shown) { shown in if !shown { stopAdding() } }
        .onAppear {
            hovering = model.snapState == "hover"
            overDial = model.snapState == "hover"
            adding = model.snapState == "edit"
        }
    }

    // The add spot sits on the North Pole, the center of the Earth: a faint dot that becomes a + on hover.
    var addSpot: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.001)).frame(width: 26, height: 26)
            Circle()
                .fill(Color(red: 0.06, green: 0.08, blue: 0.14).opacity(hovering ? 0.75 : 0))
                .overlay(Circle().stroke(Color.white.opacity(hovering ? 0.45 : 0), lineWidth: 1))
                .frame(width: hovering ? 22 : 4, height: hovering ? 22 : 4)
                .background(Circle().fill(Color.white.opacity(hovering || !overDial ? 0 : 0.35)))
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.4)
        }
        .contentShape(Circle().size(width: 26, height: 26))
        .onHover { h in if !model.dragging || !h { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } } }
        .onTapGesture { startAdding() }
        .help("Add a place")
    }

    var searchBox: some View {
        VStack(spacing: 4) {
            Group {
                if model.snapshot {
                    Text(settingHome ? "New home" : "Add a place").foregroundColor(.white.opacity(0.5))
                } else {
                    TextField("", text: $search.query, prompt: Text(settingHome ? "New home" : "Add a place").foregroundColor(.white.opacity(0.5)))
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .focused($typing)
                        .onSubmit { if let first = search.results.first { add(first) } }
                        .onExitCommand { stopAdding() }
                }
            }
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 160)
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .overlay(alignment: .trailing) {
                Button { stopAdding() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(overCancel ? 1 : 0.6))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color.white.opacity(overCancel ? 0.3 : 0.12)))
                }
                .buttonStyle(.plain)
                .onHover { overCancel = $0 }
                .help("Cancel")
                .padding(.trailing, 6)
            }
            .background(Capsule().fill(Color(red: 0.06, green: 0.08, blue: 0.14).opacity(0.85)))
            .overlay(Capsule().stroke(notFound ? Color(red: 0.9, green: 0.33, blue: 0.3).opacity(0.8) : Color.white.opacity(0.25), lineWidth: 0.75))
            .modifier(Shake(t: shakes))
            if notFound {
                Text("Couldn't find that place")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.06, green: 0.08, blue: 0.14).opacity(0.85)))
                    .transition(.opacity)
            }
            ForEach(Array(search.results.enumerated()), id: \.offset) { i, r in
                Button { add(r) } label: {
                    HStack(spacing: 6) {
                        Text(r.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        Text(r.subtitle).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(maxWidth: 230)
                    .background(Capsule().fill(Color(red: 0.06, green: 0.08, blue: 0.14).opacity(i == 0 ? 0.92 : 0.75)))
                    .overlay(Capsule().stroke(Color.white.opacity(i == 0 ? 0.35 : 0.1), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
        }
        // Keep the field itself at the center; suggestions hang below it.
        .frame(height: 30, alignment: .top)
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }

    func startAdding(home: Bool = false) {
        settingHome = home
        search.query = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { adding = true }
        model.searchOpen = true
        model.cancelSearch = { stopAdding() }
        DispatchQueue.main.async { typing = true }
    }

    func stopAdding() {
        search.query = ""
        notFound = false
        typing = false
        hovering = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { adding = false }
        model.searchOpen = false
    }

    func add(_ r: MKLocalSearchCompletion) {
        search.resolve(r) { place in
            guard let place else {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                notFound = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { notFound = false }
                return
            }
            settingHome ? model.setHome(place) : model.add(place)
            stopAdding()
        }
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize, _ now: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = DialView.r, k = r / 140
        let ss = subsolarLon(now)
        let sunA = dialAngle(ss)
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))

        // Earth: calm ocean with a few soft, made-up patches of land.
        ctx.drawLayer { g in
            g.opacity = 0.88
            g.clip(to: disc)
            g.fill(disc, with: .radialGradient(Gradient(colors: [Color(red: 0.30, green: 0.62, blue: 0.80), Color(red: 0.18, green: 0.46, blue: 0.64)]),
                                               center: c, startRadius: 0, endRadius: r))
            g.drawLayer { land in
                land.addFilter(.blur(radius: max(3, 11 * k)))
                let blobs: [(Double, Double, Double, Double)] = [
                    (-70, -60, 70, 50), (40, -80, 50, 38), (80, 20, 46, 70), (-20, 40, 60, 40),
                    (-95, 55, 34, 46), (10, -10, 30, 26), (95, -70, 26, 30),
                ]
                for (x, y, w, h) in blobs {
                    land.fill(Path(ellipseIn: CGRect(x: c.x + k * (x - w / 2), y: c.y + k * (y - h / 2), width: k * w, height: k * h)),
                              with: .color(Color(red: 0.40, green: 0.70, blue: 0.52).opacity(0.6)))
                }
            }
            // Light spreads from the point under the sun and fades to full black on the far side.
            let lit = polar(c, r, sunA)
            g.fill(disc, with: .radialGradient(Gradient(stops: [
                .init(color: .white.opacity(0.7), location: 0),
                .init(color: Color(red: 1, green: 0.96, blue: 0.82).opacity(0.35), location: 0.14),
                .init(color: Color(red: 1, green: 0.96, blue: 0.82).opacity(0.1), location: 0.36),
                .init(color: Color(red: 0.12, green: 0.05, blue: 0.02).opacity(0.25), location: 0.48),
                .init(color: .black.opacity(0.85), location: 0.6),
                .init(color: .black, location: 0.74),
            ]), center: lit, startRadius: 0, endRadius: 2 * r))
        }

        // Moon: drawn from above, so its lit half faces the sun.
        let sunP = polar(c, DialView.sunR, sunA)
        let moon = moonState(now)
        let mp = polar(c, DialView.skyR, dialAngle(moon.sublunarLon))
        let mr = 10.0, q = mr / 10
        let mRect = CGRect(x: mp.x - mr, y: mp.y - mr, width: 2 * mr, height: 2 * mr)
        ctx.fill(Path(ellipseIn: mRect.insetBy(dx: -9, dy: -9)), with: .radialGradient(Gradient(stops: [
            .init(color: Color(red: 0.81, green: 0.85, blue: 1).opacity(0.35), location: 0.45),
            .init(color: Color(red: 0.81, green: 0.85, blue: 1).opacity(0), location: 1),
        ]), center: mp, startRadius: 0, endRadius: mr + 9))
        ctx.fill(Path(ellipseIn: mRect), with: .radialGradient(Gradient(colors: [Color(white: 0.96), Color(white: 0.85), Color(white: 0.71)]),
                                                              center: CGPoint(x: mp.x - 2, y: mp.y - 2), startRadius: 0, endRadius: mr * 1.3))
        for (x, y, cr, o) in [(-3.3, -3.3, 3.2, 0.45), (3.3, -0.8, 2.0, 0.4), (-0.8, 4.2, 2.5, 0.35), (4.6, 4.6, 1.1, 0.5), (-6.2, 2.5, 0.9, 0.5)] {
            ctx.fill(Path(ellipseIn: CGRect(x: mp.x + q * (x - cr), y: mp.y + q * (y - cr), width: 2 * q * cr, height: 2 * q * cr)),
                     with: .color(Color(red: 0.55, green: 0.58, blue: 0.64).opacity(o)))
        }
        let dx = sunP.x - mp.x, dy = sunP.y - mp.y, len = max(hypot(dx, dy), 1)
        let ux = dx / len, uy = dy / len
        ctx.fill(Path(ellipseIn: mRect), with: .linearGradient(Gradient(stops: [
            .init(color: Color(red: 0.04, green: 0.05, blue: 0.09).opacity(0.88), location: 0),
            .init(color: Color(red: 0.04, green: 0.05, blue: 0.09).opacity(0.7), location: 0.4),
            .init(color: Color(red: 0.04, green: 0.05, blue: 0.09).opacity(0), location: 0.58),
        ]), startPoint: CGPoint(x: mp.x - ux * mr, y: mp.y - uy * mr), endPoint: CGPoint(x: mp.x + ux * mr, y: mp.y + uy * mr)))

        // Sun.
        ctx.fill(Path(ellipseIn: CGRect(x: sunP.x - 19, y: sunP.y - 19, width: 38, height: 38)), with: .radialGradient(Gradient(stops: [
            .init(color: Color(red: 1, green: 0.95, blue: 0.77), location: 0),
            .init(color: Color(red: 1, green: 0.79, blue: 0.29), location: 0.35),
            .init(color: Color(red: 1, green: 0.79, blue: 0.29).opacity(0), location: 1),
        ]), center: sunP, startRadius: 0, endRadius: 19))
        ctx.fill(Path(ellipseIn: CGRect(x: sunP.x - 11, y: sunP.y - 11, width: 22, height: 22)), with: .color(Color(red: 1, green: 0.81, blue: 0.3)))
    }
}

/// One place: only its pip shows at rest. Hover the pip and a label pops out
/// with the name, sun time and a small button: × to remove a place, or a house to change home.
struct PlaceChip: View {
    let place: Place, isHome: Bool, hour: Double, center: CGPoint, dragging: Bool, showPip: Bool
    let onRemove: () -> Void, onChangeHome: () -> Void
    @State private var poof = false
    @State private var overMark = false
    @State private var overLabel = false
    @State private var open = false
    @State private var overX = false

    var body: some View {
        let a = dialAngle(place.lon)
        let mark = polar(center, DialView.r - 5, a)
        ZStack {
            // The pip: a small neutral dot just inside the rim, shown only while the pointer is over the dial.
            let pr = isHome ? 2.6 : 2.0
            Circle().fill(Color.white.opacity(0.85))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.6))
                .frame(width: 2 * pr, height: 2 * pr)
                .opacity(showPip || open ? 1 : 0)
                .position(mark)
                .allowsHitTesting(false)
            // Invisible hover target over the pip.
            Circle().fill(Color.white.opacity(0.001))
                .frame(width: 12, height: 12)
                .contentShape(Circle())
                .onHover { overMark = $0; update() }
                .position(mark)
            // The label sits in its own fixed frame, so it grows out of the pip instead of flying in from across the dial.
            let g = layout(a)
            ZStack {
                if open {
                    label(a)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.35, anchor: UnitPoint(x: 0.5 - g.s / 2, y: 0.5 + g.co / 2)).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            .frame(width: g.w, height: g.h)
            .position(g.center)
        }
        .onAppear { if ProcessInfo.processInfo.environment["SNAPSTATE"] == "hover" && isHome { open = true } }
        .onChange(of: dragging) { d in if d { open = false } }
    }

    /// Only the pip opens the label; the label can keep itself open but never reopen itself.
    /// That, plus a closing label that can't be hovered, stops it flickering in and out at the edge.
    func update() {
        if dragging { return }
        if overMark || (overLabel && open) {
            if !open { withAnimation(.easeOut(duration: 0.32)) { open = true } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !overMark && !overLabel { withAnimation(.easeIn(duration: 0.15)) { open = false } }
            }
        }
    }

    static let nameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let timeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    var time: String { "  " + fmtTime(hour) }

    /// Label size and where it sits: just outside the pip, extending away from the Earth.
    func layout(_ a: Double) -> (w: Double, h: Double, center: CGPoint, s: Double, co: Double) {
        let nameW = (place.name as NSString).size(withAttributes: [.font: PlaceChip.nameFont]).width
        let timeW = (time as NSString).size(withAttributes: [.font: PlaceChip.timeFont]).width
        let w = nameW + timeW + 19 + 14, h = 19.0
        let at = polar(center, DialView.r + 13, a), s = sin(a * rad), co = cos(a * rad)
        return (w, h, CGPoint(x: at.x + s * w / 2, y: at.y - co * h / 2), s, co)
    }

    func label(_ a: Double) -> some View {
        let tint = phaseColor(hour)
        let nameFont = PlaceChip.nameFont, timeFont = PlaceChip.timeFont
        let g = layout(a), w = g.w, h = g.h, s = g.s
        let xFirst = s < -0.3 // the × goes on the end farthest from the Earth
        return HStack(spacing: 0) {
            if xFirst { endButton.padding(.trailing, 6) }
            Text(place.name).font(Font(nameFont)).foregroundColor(.white.opacity(0.95))
            Text(time).font(Font(timeFont)).foregroundColor(tint)
            if !xFirst { endButton.padding(.leading, 6) }
        }
        .fixedSize()
        .frame(width: w, height: h)
        .background(Capsule().fill(Color(red: 0.06, green: 0.08, blue: 0.14).opacity(0.9)))
        .overlay(Capsule().stroke(tint.opacity(0.55), lineWidth: 0.75))
        .scaleEffect(poof ? 1.8 : 1)
        .opacity(poof ? 0 : 1)
        .blur(radius: poof ? 6 : 0)
        .contentShape(Capsule())
        .onHover { overLabel = $0; update() }
        .allowsHitTesting(open)
    }

    /// Home gets a change-home button; every other place gets a remove ×.
    @ViewBuilder var endButton: some View {
        if isHome { homeButton } else { removeButton }
    }

    var homeButton: some View {
        Button { onChangeHome() } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(overX ? Color(red: 0.08, green: 0.1, blue: 0.16) : .white.opacity(0.7))
                .frame(width: 13, height: 13)
                .background(Circle().fill(overX ? Color(red: 1, green: 0.8, blue: 0.38) : Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { overX = $0 }
        .help("Change home")
    }

    var removeButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) { poof = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onRemove() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.white.opacity(overX ? 1 : 0.7))
                .frame(width: 13, height: 13)
                .background(Circle().fill(overX ? Color(red: 0.9, green: 0.33, blue: 0.3) : Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onHover { overX = $0 }
        .help("Remove \(place.name)")
    }
}

/// Looks up cities as you type, using Apple's built-in MapKit search (no account or key needed).
final class CitySearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { if query.isEmpty { results = [] } else { completer.queryFragment = query } }
    }
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        // Prefer city-like results: no house numbers in the title.
        let cities = c.results.filter { $0.title.rangeOfCharacter(from: .decimalDigits) == nil }
        results = query.isEmpty ? [] : Array(cities.prefix(4))
    }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }

    func resolve(_ r: MKLocalSearchCompletion, done: @escaping (Place?) -> Void) {
        MKLocalSearch(request: MKLocalSearch.Request(completion: r)).start { resp, _ in
            guard let item = resp?.mapItems.first else { return done(nil) }
            let name = item.placemark.locality ?? r.title.components(separatedBy: ",")[0]
            done(Place(name: name, lon: item.placemark.coordinate.longitude))
        }
    }
}

final class DialModel: ObservableObject {
    static let size: CGFloat = 320
    @Published var shown = false
    @Published var places: [Place] {
        didSet {
            homeLon = places.first?.lon ?? 0
            if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "places") }
        }
    }
    var snapshot = false
    var snapState = ""
    var onEscape: (() -> Void)?
    var searchOpen = false
    var cancelSearch: (() -> Void)?
    weak var panel: NSWindow?
    /// True while the dial is being moved; hover effects stay off until it's dropped.
    @Published var dragging = false
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// Moves the panel with the mouse, using screen coordinates so the moving window doesn't feed back into the drag.
    func dragMove() {
        guard let panel else { return }
        let m = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (m, panel.frame.origin); dragging = true }
        guard let st = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: st.origin.x + m.x - st.mouse.x, y: st.origin.y + m.y - st.mouse.y))
    }
    func dragEnd() {
        dragStart = nil
        dragging = false
        if let o = panel?.frame.origin { UserDefaults.standard.set([o.x, o.y], forKey: "origin") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "places"),
           let saved = try? JSONDecoder().decode([Place].self, from: data), !saved.isEmpty {
            places = saved
        } else {
            places = defaultPlaces
        }
        homeLon = places.first?.lon ?? 0
    }

    func add(_ p: Place) {
        guard !places.contains(where: { $0.isSameSpot(as: p) }) else { return }
        places.append(p)
    }
    func remove(_ p: Place) { places.removeAll { $0.id == p.id } }
    /// The new home goes on top; the old home stays on as a regular place.
    func setHome(_ p: Place) {
        let rest = places.filter { !$0.isSameSpot(as: p) }
        places = [p] + rest
    }
}

/// A quick side-to-side shake; animate `t` up by 1 for one shake.
struct Shake: GeometryEffect {
    var t: CGFloat
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(t * .pi * 6), y: 0))
    }
}

// MARK: - Menu bar icon: a tiny dial

func menuBarIcon(_ now: Date) -> NSImage {
    let sunA = dialAngle(subsolarLon(now))
    // A template image: macOS tints it white on a dark menu bar and black on a light one.
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
        let c = CGPoint(x: rect.midX, y: rect.midY), r = 6.0
        // Dark half: the side of the ring facing away from the sun (angles: 0 = right, clockwise when flipped).
        let half = NSBezierPath()
        half.move(to: c)
        half.appendArc(withCenter: c, radius: r, startAngle: sunA, endAngle: sunA + 180, clockwise: false)
        half.close()
        NSColor.black.withAlphaComponent(0.6).setFill()
        half.fill()
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = 1.5
        NSColor.black.setStroke()
        ring.stroke()
        let s = polar(c, r, sunA)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)).fill()
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var panel: KeyPanel!
    let model = DialModel()
    var outsideClick: Any?
    var escKey: Any?
    var localEsc: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarIcon(Date())
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.item.button?.image = menuBarIcon(Date())
        }

        // A borderless, fully transparent panel: only the drawing shows.
        let s = DialModel.size
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        model.onEscape = { [weak self] in self?.hide() }
        model.panel = panel
        let host = NSHostingView(rootView: DialView(model: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Move Back Under Menu Bar", action: #selector(resetPosition), keyEquivalent: "")
            menu.items.last?.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Sun Dial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        model.shown ? hide() : show()
    }

    @objc func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "origin")
        if model.shown { hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.show() } }
    }

    func show() {
        guard let button = item.button, let bw = button.window else { return }
        let f = bw.frame, s = DialModel.size
        var x = f.midX - s / 2
        if let screen = bw.screen { x = min(max(x, screen.visibleFrame.minX), screen.visibleFrame.maxX - s) }
        if let o = UserDefaults.standard.array(forKey: "origin") as? [Double], o.count == 2,
           NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(x: o[0], y: o[1], width: s, height: s)) }) {
            panel.setFrameOrigin(NSPoint(x: o[0], y: o[1]))
        } else {
            panel.setFrameOrigin(NSPoint(x: x, y: f.minY - s + 10))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        model.shown = true
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hide() }
        escKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in if e.keyCode == 53 { self?.hide() } }
        // While the dial has keyboard focus, Esc closes an open search box first, then the dial.
        localEsc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self else { return e }
            if self.model.searchOpen { self.model.cancelSearch?() } else { self.hide() }
            return nil
        }
    }

    func hide() {
        model.shown = false
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        if let m = escKey { NSEvent.removeMonitor(m); escKey = nil }
        if let m = localEsc { NSEvent.removeMonitor(m); localEsc = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }
}

// `SunDial --snapshot out.png` renders the dial and the menu bar icon to images, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let m = DialModel(); m.shown = true; m.snapshot = true; m.snapState = ProcessInfo.processInfo.environment["SNAPSTATE"] ?? ""
        let r = ImageRenderer(content: DialView(model: m).background(ProcessInfo.processInfo.environment["SNAPBG"] == "light" ? Color(white: 0.93) : Color(red: 0.22, green: 0.24, blue: 0.2)))
        r.scale = 2
        if let cg = r.cgImage { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out) }
        let icon = menuBarIcon(Date())
        icon.size = NSSize(width: 72, height: 72)
        if let t = icon.tiffRepresentation, let b = NSBitmapImageRep(data: t) {
            try? b.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("icon.png"))
        }
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
    let s = CitySearch()
    s.query = CommandLine.arguments[i + 1]
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    for r in s.results { print("\(r.title) — \(r.subtitle)") }
    if let first = s.results.first {
        var done = false
        s.resolve(first) { p in print("resolved:", p?.name ?? "nil", p?.lon ?? 0); done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
