import SwiftUI
import AppKit
import CryptoKit
import CoreImage

// MARK: - Data

struct Track: Equatable {
    var title, artist, album: String
    var duration: Double
    var source: String   // display name
    var app: String      // bundle id, used for seeking/controls
    var artURL = ""      // from Spotify / YouTube; empty → iTunes Search lookup
    var key: String { "\(artist)|\(title)".lowercased() }
}

struct Line: Identifiable { let id: Int; let time: Double; let text: String }

func parseLRC(_ s: String) -> [Line] {
    let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
    var out: [(Double, String)] = []
    for raw in s.components(separatedBy: .newlines) {
        let ns = raw as NSString
        let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard let last = ms.last else { continue }
        let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
        for m in ms {
            let min = Double(ns.substring(with: m.range(at: 1)))!
            let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: "."))!
            out.append((min * 60 + sec, text))
        }
    }
    return out.sorted { $0.0 < $1.0 }.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
}

/// Strip "(Official Video)", "[Lyrics]", "feat. X", "- Remastered 2011" noise for searching.
func clean(_ s: String) -> String {
    var t = s
    for p in [#"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|remaster|mv|live)[^\)\]]*[\)\]]"#,
              #"\s*[\(\[]?\b(feat|ft)\.?\s.*$"#,
              #"\s+-\s+.*(remaster|version|edit|mix).*$"#] {
        t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
    }
    return t.trimmingCharacters(in: .whitespaces)
}

/// YouTube titles are usually "Artist - Song (Official Video)"; channel is a fallback artist.
func ytTrack(title: String, channel: String, album: String, duration: Double, app: String, source: String) -> Track {
    let t = clean(title)
    if let r = t.range(of: " - ") ?? t.range(of: " – ") ?? t.range(of: " — ") {
        return Track(title: clean(String(t[r.upperBound...])), artist: String(t[..<r.lowerBound]),
                     album: album, duration: duration, source: source, app: app)
    }
    let a = channel.replacingOccurrences(of: #"\s*-\s*Topic$|VEVO$"#, with: "", options: .regularExpression)
    return Track(title: t, artist: a, album: album, duration: duration, source: source, app: app)
}

// MARK: - Players (AppleScript)

func runAS(_ src: String) -> String? {
    var err: NSDictionary?
    return NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
}

func isRunning(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

/// Shuffle / repeat / volume. nil = this player doesn't support it (the button is hidden).
struct Extras: Equatable { var shuffle: Bool?; var repeatMode: String?; var volume: Double? }

// (bundle id, name, duration divisor, artwork URL expression, "shuffle, repeat, volume" expression)
let nativePlayers = [
    ("com.apple.Music", "Music", 1.0, "\"\"",
     "(shuffle enabled as text) & linefeed & (song repeat as text) & linefeed & (sound volume as text)"),
    ("com.spotify.client", "Spotify", 1000.0, "artwork url of t",
     "(shuffling as text) & linefeed & (repeating as text) & linefeed & (sound volume as text)"),
]
let chromiums = [("com.google.Chrome", "Chrome"), ("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Edge")]

func nativeScript(_ id: String, art: String, extras: String) -> String {
    """
    tell application id "\(id)"
      try
        if player state is not playing then return ""
        set t to current track
        return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as text) & linefeed & ((player position) as text) & linefeed & (\(art)) & linefeed & \(extras)
      end try
      return ""
    end tell
    """
}

// Only answers for a YouTube tab whose video is actually playing. No double quotes/backslashes (embedded in AppleScript).
let ytInfoJS = "(()=>{const v=document.querySelector('video');if(!v||v.paused)return '';const m=navigator.mediaSession&&navigator.mediaSession.metadata;return [(m&&m.title)||document.title.replace(/ - YouTube$/,''),(m&&m.artist)||'',(m&&m.album)||'',v.duration,v.currentTime,(m&&m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'',Math.round(v.volume*100)].join(String.fromCharCode(10))})()"
/// Runs `action` (JS using `v`, the video element) in the first YouTube tab with a video, paused or not.
// ponytail: first YouTube tab wins; track the matched tab id if multiple YouTube tabs cause wrong-tab control.
func ytJS(_ action: String) -> String { "(()=>{const v=document.querySelector('video');if(!v)return '';\(action);return 'ok'})()" }

func browserScript(_ id: String, _ js: String) -> String {
    let exec = id == "com.apple.Safari" ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
    return """
    tell application id "\(id)"
      repeat with w in windows
        repeat with t in tabs of w
          try
            if URL of t contains "youtube.com/watch" then
              set r to \(exec)
              if r is not missing value and r is not "" then return r
            end if
          end try
        end repeat
      end repeat
      return ""
    end tell
    """
}

/// Returns the currently *playing* track and its position, or nil if nothing is playing.
func detect() -> (Track, Double, Extras)? {
    for (id, name, durScale, art, extras) in nativePlayers where isRunning(id) {
        guard let r = runAS(nativeScript(id, art: art, extras: extras)), !r.isEmpty else { continue }
        let f = r.components(separatedBy: "\n")
        guard f.count >= 9 else { continue }
        let rep = f[7] == "true" ? "all" : f[7] == "false" ? "off" : f[7]   // Spotify's repeat is a boolean
        return (Track(title: f[0], artist: f[1], album: f[2], duration: num(f[3]) / durScale, source: name, app: id, artURL: f[5]),
                num(f[4]), Extras(shuffle: f[6] == "true", repeatMode: rep, volume: num(f[8])))
    }
    for (id, name) in chromiums + [("com.apple.Safari", "Safari")] where isRunning(id) {
        guard let r = runAS(browserScript(id, ytInfoJS)), !r.isEmpty else { continue }
        let f = r.components(separatedBy: "\n")
        guard f.count >= 7 else { continue }
        var t = ytTrack(title: f[0], channel: f[1], album: f[2], duration: num(f[3]), app: id, source: "YouTube · \(name)")
        t.artURL = f[5]
        return (t, num(f[4]), Extras(volume: num(f[6])))
    }
    return nil
}

enum Cmd { case playPause, next, previous, seek(Double), shuffle(Bool), repeatMode(String), volume(Int) }

func commandScript(_ app: String, _ c: Cmd) -> String {
    if nativePlayers.contains(where: { $0.0 == app }) {
        let music = app == "com.apple.Music"
        let verb: String
        switch c {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .seek(let t): verb = "set player position to \(t)"
        case .shuffle(let b): verb = music ? "set shuffle enabled to \(b)" : "set shuffling to \(b)"
        case .repeatMode(let r): verb = music ? "set song repeat to \(r)" : "set repeating to \(r != "off")"
        case .volume(let v): verb = "set sound volume to \(v)"
        }
        return "tell application id \"\(app)\" to \(verb)"
    }
    let js: String   // YouTube buttons: .ytp-* on youtube.com, plain class names on music.youtube.com
    switch c {
    case .playPause: js = "v.paused?v.play():v.pause()"
    case .next: js = "const b=document.querySelector('.ytp-next-button,.next-button');if(b)b.click()"
    case .previous: js = "const b=document.querySelector('.previous-button,.ytp-prev-button');if(b)b.click();else v.currentTime=0"
    case .seek(let t): js = "v.currentTime=\(t)"
    case .volume(let v): js = "v.volume=\(Double(v) / 100)"
    case .shuffle, .repeatMode: js = "0"   // not supported on YouTube; buttons are hidden
    }
    return browserScript(app, ytJS(js))
}

/// Accent color for an album: the art's average color, kept light and soft so it reads on the dark blurred background.
/// Returns hue/saturation/brightness; grey art gives near-white.
func artTintHSB(_ img: NSImage) -> (h: CGFloat, s: CGFloat, b: CGFloat)? {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let ci = CIImage(cgImage: cg)
    guard let out = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])?.outputImage
    else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    CIContext().render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
    return (h, min(s * 1.3, 0.55), 0.92)
}

/// Album art URL via the public iTunes Search API (no key) when the player doesn't give one.
func itunesArt(_ t: Track) async -> String? {
    var c = URLComponents(string: "https://itunes.apple.com/search")!
    c.queryItems = [.init(name: "term", value: "\(t.artist) \(clean(t.title))"), .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
    struct R: Decodable { struct I: Decodable { let artworkUrl100: String? }; let results: [I] }
    guard let (d, _) = try? await URLSession.shared.data(from: c.url!),
          let u = (try? JSONDecoder().decode(R.self, from: d))?.results.first?.artworkUrl100 else { return nil }
    return u.replacingOccurrences(of: "100x100bb", with: "600x600bb")
}

// MARK: - Lyrics (LRCLIB)

struct LR: Decodable { let duration: Double?; let syncedLyrics: String?; let plainLyrics: String? }

func lrclib(_ path: String, _ q: [String: String]) async -> Data? {
    var c = URLComponents(string: "https://lrclib.net/api/" + path)!
    c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
    var req = URLRequest(url: c.url!)
    req.setValue("LyricsSync/1.0", forHTTPHeaderField: "User-Agent")
    guard let (d, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return d
}

func fetchLyrics(_ t: Track) async -> LR? {
    var q = ["track_name": t.title, "artist_name": t.artist]
    if !t.album.isEmpty { q["album_name"] = t.album }
    if t.duration > 0 { q["duration"] = String(Int(t.duration.rounded())) }
    if let d = await lrclib("get", q), let r = try? JSONDecoder().decode(LR.self, from: d), r.syncedLyrics != nil { return r }

    var plainHit: LR?
    for q in [["track_name": clean(t.title), "artist_name": t.artist], ["q": "\(t.artist) \(clean(t.title))"]] {
        guard let d = await lrclib("search", q), let rs = try? JSONDecoder().decode([LR].self, from: d) else { continue }
        let diff = { (r: LR) in abs((r.duration ?? 0) - t.duration) }
        if let best = rs.filter({ $0.syncedLyrics != nil }).min(by: { diff($0) < diff($1) }) { return best }
        plainHit = plainHit ?? rs.first { $0.plainLyrics != nil }
    }
    return plainHit
}

// MARK: - Model

@MainActor final class Model: ObservableObject {
    @Published var track: Track?
    @Published var lines: [Line] = []
    @Published var plain: String?
    @Published var status = "Play something in Music, Spotify or YouTube…"
    @Published var current = -1
    @Published var offset = 0.0
    @Published var art: NSImage?
    @Published var artTint: Color?   // sliders in the wide layout match the album
    @Published private(set) var playing = false
    @Published var extras = Extras()

    private var basePos = 0.0, baseAt = Date(), polling = false
    private var gen = 0   // bumped on every command; polls from before it are ignored
    // After play/pause, Music can keep reporting the old state for 0.35s+ (seen in logs). Hold the state the user
    // asked for until the player confirms it, or this deadline passes.
    private var expect: (playing: Bool, until: Date)?
    private var cache: [String: LR?] = [:]
    private var stash: (lines: [Line], plain: String?, offset: Double)?   // real lyrics, saved during a draft preview

    /// Show a draft in the main view; `endPreview` puts the real lyrics back.
    func preview(_ synced: String) {
        if stash == nil { stash = (lines, plain, offset) }
        lines = parseLRC(synced); plain = nil; offset = 0
    }

    func endPreview() {
        guard let s = stash else { return }
        (lines, plain, offset) = s; stash = nil
    }
    private let q = DispatchQueue(label: "poll")   // all AppleScript runs on this one thread

    init() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    var position: Double { playing ? basePos + Date().timeIntervalSince(baseAt) : basePos }

    func poll() {
        guard !polling else { return }
        polling = true
        let g = gen
        q.async {
            let r = detect()
            DispatchQueue.main.async { self.apply(r, gen: g) }
        }
    }

    private func apply(_ r: (Track, Double, Extras)?, gen g: Int) {
        polling = false
        guard g == gen else { return }   // started before the last command: stale, would undo the optimistic UI
        if let e = expect {
            if (r != nil) == e.playing || Date() > e.until { expect = nil } else { return }   // player hasn't caught up yet
        }
        guard let (t, pos, x) = r else {      // paused / nothing: freeze, keep lyrics on screen
            if playing { basePos = position; playing = false }
            return
        }
        basePos = pos; baseAt = Date(); playing = true
        if extras != x { extras = x }
        if track?.key != t.key { track = t; load(t) }
    }

    private func load(_ t: Track) {
        lines = []; plain = nil; current = -1; offset = 0; art = nil; artTint = nil
        stash = nil   // song changed mid-preview: don't restore the old song's lyrics later
        status = "Searching lyrics…"
        Task {
            let u = t.artURL.isEmpty ? await itunesArt(t) : t.artURL
            guard let u, let url = URL(string: u), let (d, _) = try? await URLSession.shared.data(from: url),
                  track?.key == t.key else { return }
            art = NSImage(data: d)
            artTint = art.flatMap(artTintHSB).map { Color(hue: $0.h, saturation: $0.s, brightness: $0.b) }
        }
        Task {
            let r: LR?
            if let c = cache[t.key] { r = c } else { r = await fetchLyrics(t); cache[t.key] = r }
            guard track?.key == t.key else { return }
            lines = r?.syncedLyrics.map(parseLRC) ?? []
            plain = lines.isEmpty ? r?.plainLyrics : nil
            status = r == nil ? "No lyrics found for \(t.artist) – \(t.title)" : ""
        }
    }

    private func tick() {
        let p = position + offset
        let i = lines.lastIndex { $0.time <= p } ?? -1
        if i != current { current = i }
    }

    /// Show freshly made lyrics right away (and cache them) without waiting for LRCLIB.
    func useLyrics(key: String, synced: String, plain: String) {
        cache[key] = LR(duration: track?.duration, syncedLyrics: synced, plainLyrics: plain)
        guard track?.key == key else { return }
        lines = parseLRC(synced); self.plain = nil; status = ""
    }

    /// off → all → one → off (Spotify has no "one", so off ↔ all).
    var nextRepeat: String {
        switch extras.repeatMode {
        case "off": return "all"
        case "all": return track?.app == "com.apple.Music" ? "one" : "off"
        default: return "off"
        }
    }

    /// Seek so that lyric time `time` lines up (accounts for the offset).
    func seekLyric(_ time: Double) { send(.seek(max(0, time - offset))) }

    func send(_ c: Cmd) {
        guard let app = track?.app else { return }
        gen += 1
        switch c {   // optimistic UI, the next poll corrects it
        case .seek(let t): basePos = t; baseAt = Date()
        case .playPause:
            basePos = position; baseAt = Date(); playing.toggle()
            expect = (playing, Date().addingTimeInterval(1.5))
        case .shuffle(let b): extras.shuffle = b
        case .repeatMode(let r): extras.repeatMode = r
        case .volume(let v): extras.volume = Double(v)
        default: break
        }
        q.async {
            _ = runAS(commandScript(app, c))
            DispatchQueue.main.async { self.poll() }
        }
    }
}

// MARK: - UI

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @StateObject var m = Model()
    @AppStorage("onTop") var onTop = true
    @State var editor: Editor?
    @State var previewing = false

    var body: some View {
        GeometryReader { geo in
            // Big window / full screen: Apple Music-style art + controls on the left, lyrics on the right.
            if geo.size.width >= 900 && (editor == nil || previewing) {
                wide(geo.size)
            } else {
                compact.frame(width: geo.size.width, height: geo.size.height).background(Blur().ignoresSafeArea())
            }
        }
        .frame(minWidth: 300, minHeight: 320)
        .onAppear {
            setupWindows()
            Task { await Updater.shared.check() }
        }
        .onChange(of: onTop) { _, _ in setupWindows() }
    }

    // MARK: pieces shared by both layouts

    var artView: some View {
        Group {
            if let a = m.art { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary) }
        }
        .background(.quaternary)
    }

    var toolbarButtons: some View {
        HStack(spacing: 12) {
            Button {
                if editor == nil { editor = Editor(m) } else { m.endPreview(); previewing = false; editor = nil }
            } label: { Image(systemName: editor == nil ? "pencil" : "xmark") }
                .help(editor == nil ? "Sync editor: make synced lyrics for this song" : "Close editor")
                .disabled(m.track == nil)
            Button { toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Full screen")
            Button { onTop.toggle() } label: { Image(systemName: onTop ? "pin.fill" : "pin") }
                .help(onTop ? "Stay on top: on" : "Stay on top: off")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder var previewBanner: some View {
        if previewing {
            HStack {
                Label("Previewing your draft", systemImage: "eye").font(.caption.bold())
                Spacer()
                Button("Back to editor") { m.endPreview(); previewing = false; editor?.resume() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15))
        }
    }

    @ViewBuilder func lyricsBody(size: CGFloat, vPad: CGFloat) -> some View {
        if !m.lines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: size * 0.6) {
                        ForEach(m.lines) { l in
                            Text(l.text.isEmpty ? "♪" : l.text)
                                .font(.system(size: size, weight: .bold))
                                .foregroundStyle(l.id == m.current ? Color.primary : Color.secondary)
                                .opacity(l.id == m.current ? 1 : 0.45)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { m.seekLyric(l.time) }
                                .id(l.id)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, vPad)
                    .animation(.easeOut(duration: 0.2), value: m.current)
                }
                .scrollIndicators(.never)
                .onChange(of: m.current) { _, i in
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(max(i, 0), anchor: .center) }
                }
            }
        } else if let p = m.plain {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Synced lyrics not available").font(.caption).foregroundStyle(.secondary)
                    Text(p).font(.system(size: size * 0.8, weight: .semibold)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } else {
            VStack {
                Spacer()
                Text(m.status).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: layouts

    var compact: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                artView.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.track?.title ?? "Lyrics").font(.headline).lineLimit(1)
                    Text(m.track?.artist ?? "").font(.subheadline).lineLimit(1)
                    Text(m.track?.source ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                toolbarButtons
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 8)

            UpdateBanner()
            previewBanner
            if let e = editor, !previewing {
                EditorView(e: e, m: m, close: { editor = nil }, preview: { m.preview(e.lrc); previewing = true })
            } else {
                lyricsBody(size: 22, vPad: 200)
            }

            if m.track != nil { Controls(m: m, spaceKey: editor == nil || previewing).padding(.horizontal, 16).padding(.vertical, 10) }
        }
    }

    func wide(_ s: CGSize) -> some View {
        let side = min(s.height * 0.5, s.width * 0.3)
        let subtitle = [m.track?.artist, m.track?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        return HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 24) {
                artView.frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.track?.title ?? "Lyrics").font(.title2.bold()).lineLimit(1)
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                if m.track != nil { Controls(m: m, spaceKey: editor == nil || previewing, big: true, tint: m.artTint ?? .white) }
            }
            .frame(width: side)
            .frame(maxWidth: .infinity)
            lyricsBody(size: 34, vPad: s.height * 0.4)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 56)
        .frame(width: s.width, height: s.height)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                HStack { Spacer(); toolbarButtons }.padding(.horizontal, 20).padding(.top, 12)
                UpdateBanner()
                previewBanner
            }
        }
        .background(artBackground)
        .environment(\.colorScheme, .dark)
    }

    /// Apple Music-style background: the album art blown up, blurred and darkened, so the colors come from the art.
    var artBackground: some View {
        ZStack {
            Color.black
            if let a = m.art {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 90).saturation(1.3).opacity(0.85)
                    .id(m.track?.key)
                    .transition(.opacity)
            }
            Color.black.opacity(0.3)
        }
        .animation(.easeInOut(duration: 0.8), value: m.art)
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: window

    func toggleFullScreen() {
        if onTop { onTop = false; setupWindows() }   // floating windows can't go full screen
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }

    func setupWindows() {
        for w in NSApp.windows {
            w.level = onTop ? .floating : .normal
            w.isOpaque = false
            w.backgroundColor = .clear
            if onTop {
                w.collectionBehavior.remove(.fullScreenPrimary)
                w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            } else {
                w.collectionBehavior.subtract([.canJoinAllSpaces, .fullScreenAuxiliary])
                w.collectionBehavior.insert(.fullScreenPrimary)
            }
        }
    }
}

struct Controls: View {
    @ObservedObject var m: Model
    var spaceKey = true                // off while the editor is open so typing spaces works
    var big = false                    // Apple Music-style: shuffle, repeat, volume, remaining time
    var tint: Color?                   // slider color; nil = system accent
    @State private var drag: Double?   // scrub position while dragging; seek only on release
    @State private var vol: Double?    // volume while dragging; set only on release

    func scrubber(_ pos: Double, _ dur: Double) -> some View {
        Slider(value: Binding(get: { pos }, set: { drag = $0 }), in: 0...(dur.isFinite ? dur : 1)) { editing in
            if !editing, let d = drag { m.send(.seek(d)); drag = nil }
        }
        .controlSize(.small)
        .tint(tint)
    }

    var offsetControl: some View {
        HStack(spacing: 2) {
            Button("−") { m.offset -= 0.25 }.help("Lyrics earlier")
            Text(String(format: "%+.2f", m.offset)).frame(width: 40)
            Button("+") { m.offset += 0.25 }.help("Lyrics later")
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }

    @ViewBuilder var shuffleButton: some View {
        if let s = m.extras.shuffle {
            Button { m.send(.shuffle(!s)) } label: { Image(systemName: "shuffle") }
                .foregroundStyle(s ? Color.primary : Color.secondary).opacity(s ? 1 : 0.6)
                .help(s ? "Shuffle: on" : "Shuffle: off")
        } else { Color.clear.frame(width: 24, height: 1) }
    }

    @ViewBuilder var repeatButton: some View {
        if let r = m.extras.repeatMode {
            Button { m.send(.repeatMode(m.nextRepeat)) } label: { Image(systemName: r == "one" ? "repeat.1" : "repeat") }
                .foregroundStyle(r != "off" ? Color.primary : Color.secondary).opacity(r != "off" ? 1 : 0.6)
                .help("Repeat: \(r)")
        } else { Color.clear.frame(width: 24, height: 1) }
    }

    var body: some View {
        let dur = max(m.track?.duration ?? 0, 1)
        VStack(spacing: big ? 18 : 6) {
            // Redraws only this bar twice a second instead of the whole window.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let pos = drag ?? min(m.position, dur)
                if big {
                    VStack(spacing: 4) {
                        scrubber(pos, dur)
                        HStack { Text(fmt(pos)); Spacer(); Text("-" + fmt(max(dur - pos, 0))) }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(fmt(pos)).frame(width: 40, alignment: .leading)
                        scrubber(pos, dur)
                        Text(fmt(dur)).frame(width: 40, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: big ? 0 : 24) {
                if big { shuffleButton; Spacer() }
                else if !m.lines.isEmpty { offsetControl.frame(width: 80, alignment: .leading) }
                else { Spacer().frame(width: 80) }

                Button { m.send(.previous) } label: { Image(systemName: "backward.fill") }
                if big { Spacer() }
                Button { m.send(.playPause) } label: {
                    // Fixed frame: the play and pause symbols differ in size, which nudged the layout on every toggle.
                    Image(systemName: m.playing ? "pause.fill" : "play.fill").font(big ? .system(size: 40) : .title)
                        .frame(width: big ? 48 : 32, height: big ? 48 : 32)
                }
                .keyboardShortcut(spaceKey ? KeyboardShortcut(.space, modifiers: []) : nil)
                if big { Spacer() }
                Button { m.send(.next) } label: { Image(systemName: "forward.fill") }

                if big { Spacer(); repeatButton } else { Spacer().frame(width: 80) }
            }
            .font(big ? .title : .title3)
            .buttonStyle(.borderless)

            if big {
                if let v = m.extras.volume {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                        Slider(value: Binding(get: { vol ?? v }, set: { vol = $0 }), in: 0...100) { editing in
                            if !editing, let x = vol { m.send(.volume(Int(x))); vol = nil }
                        }
                        .controlSize(.small)
                        .tint(tint)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !m.lines.isEmpty { offsetControl }
            }
        }
    }
}

struct LyricsApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 420, height: 620)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Task { await Updater.shared.check(manual: true) } }
                }
            }
    }
}

// MARK: - Sync editor

func fmt(_ s: Double) -> String { s.isFinite ? String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) : "--:--" }

func lrcTime(_ t: Double) -> String {
    let cs = Int((max(0, t) * 100).rounded())   // round once so 59.996 → 01:00.00, not 00:60.00
    return String(format: "[%02d:%02d.%02d]", cs / 6000, cs / 100 % 60, cs % 100)
}

let sectionHeader = #"^\s*\[[^\]]*\]\s*$"#   // "[Chorus]", "[Verse 1]" from pasted lyrics

/// Lyrics text → lines to sync: drops blank lines and section headers.
func syncableLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0.range(of: sectionHeader, options: .regularExpression) == nil }
}

/// LRCLIB proof-of-work (per LRCGET's solver): smallest decimal nonce where sha256(prefix+nonce) <= target, compared as bytes.
func solveChallenge(prefix: String, target: String) -> String? {
    var t: [UInt8] = [], i = target.startIndex
    while i < target.endIndex {
        let j = target.index(i, offsetBy: 2, limitedBy: target.endIndex) ?? target.endIndex
        guard let b = UInt8(target[i..<j], radix: 16) else { return nil }
        t.append(b); i = j
    }
    guard t.count == 32 else { return nil }
    let p = Array(prefix.utf8)
    // ponytail: single-threaded, ~5s avg at LRCLIB's usual difficulty; split nonce ranges across cores if it gets slow
    for n in 0... {
        let s = String(n)
        if !t.lexicographicallyPrecedes(SHA256.hash(data: p + Array(s.utf8))) { return s }
    }
    return nil
}

struct Msg: LocalizedError { let errorDescription: String? }

func lrclibPost(_ path: String, body: [String: Any]?, token: String?) async throws -> Data {
    var req = URLRequest(url: URL(string: "https://lrclib.net/api/" + path)!)
    req.httpMethod = "POST"
    req.setValue("LyricsSync/1.0", forHTTPHeaderField: "User-Agent")
    if let token { req.setValue(token, forHTTPHeaderField: "X-Publish-Token") }
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (d, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
        let m = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["message"] as? String
        throw Msg(errorDescription: m ?? "HTTP \(code)")
    }
    return d
}

@MainActor final class Editor: ObservableObject {
    enum Phase { case text, sync, review }
    @Published var phase = Phase.text
    @Published var text: String
    @Published var lines: [String] = []
    @Published var stamps: [Double] = []   // stamps[i] = start time of lines[i]; count = lines synced so far
    @Published var fixing: Int?            // re-stamping one line from review
    @Published var title: String
    @Published var artist: String
    @Published var album: String
    @Published var status = ""
    @Published var busy = false
    @Published var published = false
    let track: Track                       // frozen: the song this sync belongs to
    let m: Model

    init(_ m: Model) {
        self.m = m
        track = m.track!
        title = track.title; artist = track.artist; album = track.album
        text = m.plain ?? m.lines.map { $0.text.isEmpty ? note : $0.text }.joined(separator: "\n")
    }

    var idx: Int { fixing ?? stamps.count }
    var songChanged: Bool { m.track?.key != track.key }
    var done: Bool { fixing == nil && stamps.count == lines.count }
    // ♪ lines become empty timestamped lines: the standard LRC "vocals stop here" marker.
    var lrc: String { zip(lines, stamps).map { lrcTime($1) + " " + ($0 == note ? "" : $0) }.joined(separator: "\n") }
    var plainText: String {
        text.components(separatedBy: .newlines)
            .filter { $0.range(of: sectionHeader, options: .regularExpression) == nil && $0.trimmingCharacters(in: .whitespaces) != note }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        lines = syncableLines(text); stamps = []; fixing = nil; published = false; status = ""
        phase = .sync
        m.send(.seek(0))
        if !m.playing { m.send(.playPause) }
    }

    func tap() {
        guard !songChanged, idx < lines.count else { return }
        let t = m.position
        if let f = fixing { stamps[f] = t; fixing = nil; phase = done ? .review : .sync; return }
        stamps.append(t)
    }

    /// Vocals just stopped: stamp a ♪ break now, before the next line.
    func instrumental() {
        guard !songChanged, fixing == nil else { return }
        lines.insert(note, at: stamps.count)
        stamps.append(m.position)
    }

    /// Unstamp the last line and rewind to just before the line before it, so you can tap again.
    /// A ♪ break is removed entirely (the ♪ button adds it back).
    func undo() {
        guard fixing == nil, !stamps.isEmpty else { return }
        stamps.removeLast()
        if lines[stamps.count] == note { lines.remove(at: stamps.count) }
        m.send(.seek(max(0, (stamps.last ?? 0) - 1)))
    }

    /// Move one line's start and play from the new time, to hear if it lands on the first syllable.
    func nudge(_ i: Int, _ d: Double) {
        stamps[i] = max(0, stamps[i] + d)
        m.send(.seek(stamps[i]))
        if !m.playing { m.send(.playPause) }
    }

    /// Back from a mid-sync preview: rewind to just before the last tapped line so tapping can continue.
    func resume() {
        guard phase == .sync, fixing == nil, !done else { return }
        m.send(.seek(max(0, (stamps.last ?? 0) - 1)))
    }

    func fix(_ i: Int) { fixing = i; phase = .sync; m.send(.seek(max(0, stamps[i] - 3))) }
    func back() { if fixing != nil { fixing = nil; phase = done ? .review : .sync } else { phase = .text } }

    // Line fixes mid-sync. Each one also updates `text` so the plain lyrics stay in step.
    private func textLine(_ i: Int) -> Int? {
        guard lines[i] != note else { return nil }   // live ♪ breaks aren't in the text
        return nthLine(in: text, equalTo: lines[i], occurrence: lines[..<i].filter { $0 == lines[i] }.count)
    }

    private func editText(_ f: (inout [String]) -> Void) {
        var tl = text.components(separatedBy: "\n"); f(&tl); text = tl.joined(separator: "\n")
    }

    func editLine(_ i: Int, to s: String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if let j = textLine(i) { editText { $0[j] = s } }
        lines[i] = s
    }

    func deleteLine(_ i: Int) {
        if let j = textLine(i) { editText { $0.remove(at: j) } }
        lines.remove(at: i)
        if i < stamps.count { stamps.remove(at: i) }
    }

    /// Insert after line i. Inside the synced part it borrows i's time, then asks you to tap its real start.
    func insertLine(after i: Int, _ s: String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if let j = textLine(i) { editText { $0.insert(s, at: j + 1) } }
        let p = i + 1
        lines.insert(s, at: p)
        if p < stamps.count || phase == .review { stamps.insert(stamps[i], at: p); fix(p) }
    }
    func shift(_ d: Double) { stamps = stamps.map { max(0, $0 + d) } }

    func publish() {
        let body: [String: Any] = ["trackName": title, "artistName": artist, "albumName": album,
                                   "duration": Int(track.duration.rounded()), "plainLyrics": plainText, "syncedLyrics": lrc]
        busy = true; status = "Getting challenge…"
        Task {
            defer { busy = false }
            do {
                let d = try await lrclibPost("request-challenge", body: nil, token: nil)
                guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let p = o["prefix"] as? String, let tg = o["target"] as? String else { throw Msg(errorDescription: "bad challenge") }
                status = "Solving anti-spam challenge (usually a few seconds)…"
                guard let nonce = await Task.detached(operation: { solveChallenge(prefix: p, target: tg) }).value
                else { throw Msg(errorDescription: "couldn't solve challenge") }
                status = "Publishing…"
                _ = try await lrclibPost("publish", body: body, token: "\(p):\(nonce)")
                published = true
                status = "Published to LRCLIB ✓"
                m.useLyrics(key: track.key, synced: lrc, plain: plainText)
            } catch { status = "Publish failed: \(error.localizedDescription)" }
        }
    }
}

let note = "♪"

/// Index (in `text` split by newline) of the `occurrence`-th line equal to `s` after trimming. Handles repeated chorus lines.
func nthLine(in text: String, equalTo s: String, occurrence: Int) -> Int? {
    var seen = 0
    for (j, raw) in text.components(separatedBy: "\n").enumerated() where raw.trimmingCharacters(in: .whitespaces) == s {
        if seen == occurrence { return j }
        seen += 1
    }
    return nil
}

/// Insert a ♪ line at the cursor of the focused text editor, or append if nothing is focused.
func insertNote(into text: inout String) {
    guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else {
        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + note + "\n"; return
    }
    let r = tv.selectedRange(), s = tv.string as NSString
    let atLineStart = r.location == 0 || s.character(at: r.location - 1) == 10
    tv.insertText((atLineStart ? "" : "\n") + note + "\n", replacementRange: r)
}

struct EditorView: View {
    @ObservedObject var e: Editor
    @ObservedObject var m: Model
    var close: () -> Void
    var preview: () -> Void
    @State private var showTips = false
    @State private var editIndex: Int?      // line being edited (or inserted after)
    @State private var inserting = false
    @State private var draft = ""

    func lineMenu(_ i: Int) -> some View {
        Group {
            Button("Edit text…") { draft = e.lines[i]; inserting = false; editIndex = i }
            Button("Insert line below…") { draft = ""; inserting = true; editIndex = i }
            Divider()
            Button("Delete line", role: .destructive) { e.deleteLine(i) }
        }
        .disabled(e.fixing != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { showTips.toggle() } label: { Label("Style tips", systemImage: "questionmark.circle") }
                    .buttonStyle(.borderless).font(.caption)
                    .popover(isPresented: $showTips, arrowEdge: .bottom) { TipsView() }
            }
            if e.songChanged {
                Text("⚠️ Song changed. Go back to “\(e.track.title)” to keep syncing.").font(.caption).foregroundStyle(.orange)
            }
            switch e.phase {
            case .text: textPhase
            case .sync: syncPhase
            case .review: reviewPhase
            }
        }
        .padding(.horizontal, 16)
        .alert(inserting ? "Insert line below" : "Edit line",
               isPresented: Binding(get: { editIndex != nil }, set: { if !$0 { editIndex = nil } })) {
            TextField("Lyric", text: $draft)
            Button(inserting ? "Insert" : "Save") {
                if let i = editIndex { inserting ? e.insertLine(after: i, draft) : e.editLine(i, to: draft) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inserting ? "The new line keeps its place, and you'll tap when it starts." : "Timing stays the same.")
        }
    }

    func hint(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }

    var textPhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            hint("Step 1: paste the lyrics, one line each. Headers like [Chorus] are skipped. You can also add ♪ breaks live while syncing.")
            TextEditor(text: $e.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(4).background(.quaternary.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Cancel", action: close)
                Button("Insert ♪") { insertNote(into: &e.text) }.help("Instrumental break at the cursor")
                Spacer()
                Text("\(syncableLines(e.text).count) lines").font(.caption).foregroundStyle(.secondary)
                Button("Start syncing ▶") { e.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncableLines(e.text).isEmpty || e.songChanged)
            }
        }
    }

    func row(_ i: Int, stamp: Double?, highlight: Bool, nudge: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 0) {
                if nudge {
                    Button("«") { e.nudge(i, -0.5) }.help("0.5s earlier")
                    Button("‹") { e.nudge(i, -0.1) }.help("0.1s earlier")
                }
                Text(stamp.map(lrcTime) ?? "[--:--.--]").padding(.horizontal, 2)
                if nudge {
                    Button("›") { e.nudge(i, 0.1) }.help("0.1s later")
                    Button("»") { e.nudge(i, 0.5) }.help("0.5s later")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            Text(e.lines[i])
                .font(.system(size: 16, weight: highlight ? .bold : .regular))
                .foregroundStyle(highlight ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(i)
    }

    var syncPhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            hint(e.fixing != nil ? "Re-syncing one line. Press ↩ when it starts."
                 : e.done ? "All lines synced. Press ♪ (M) when the singing ends if the song finishes with music, then Review."
                 : "Step 2: press ↩ (or Tap) the moment each line starts. Press ♪ (M) when singing stops for a break. ⌫ undoes and rewinds. Right-click a line to fix its text.")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(e.lines.indices, id: \.self) { i in
                            row(i, stamp: i < e.stamps.count && i != e.fixing ? e.stamps[i] : nil, highlight: i == e.idx)
                                .contextMenu { lineMenu(i) }
                        }
                    }
                    .padding(.vertical, 120)
                }
                .onAppear { proxy.scrollTo(e.idx, anchor: .center) }
                .onChange(of: e.idx) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
            }
            HStack {
                Button("Back") { e.back() }
                Button("Undo ⌫") { e.undo() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(e.stamps.isEmpty || e.fixing != nil)
                Button("Preview") { preview() }
                    .help("See the lines you've synced so far in the full lyrics view")
                    .disabled(e.stamps.isEmpty || e.fixing != nil)
                Spacer()
                Text("\(min(e.idx + 1, e.lines.count))/\(e.lines.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("♪") { e.instrumental() }
                    .keyboardShortcut("m", modifiers: [])
                    .help("Singing stopped: mark an instrumental break now (M)")
                    .disabled(e.songChanged || e.fixing != nil)
                if e.done {
                    Button { e.phase = .review } label: { Text("Review ▶").frame(width: 80) }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { e.tap() } label: { Text("Tap ↩").frame(width: 80) }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .disabled(e.songChanged)
                }
            }
        }
    }

    var reviewPhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            hint("Step 3: play it back and watch. Click any line to re-sync just that one, right-click to fix its text.")
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let cur = e.stamps.lastIndex { $0 <= m.position } ?? -1
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(e.lines.indices, id: \.self) { i in
                            row(i, stamp: e.stamps[i], highlight: i == cur, nudge: true)
                                .contentShape(Rectangle())
                                .onTapGesture { e.fix(i) }
                                .contextMenu { lineMenu(i) }
                                .help("Click to re-sync, right-click to edit")
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Shift all:").font(.caption).foregroundStyle(.secondary)
                Button("−0.1s") { e.shift(-0.1) }
                Button("+0.1s") { e.shift(0.1) }
                Spacer()
                Button("Preview") { preview() }.help("See your draft in the full lyrics view")
                Button("Copy LRC") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.lrc, forType: .string)
                }
            }
            .controlSize(.small)

            Divider()
            TextField("Title", text: $e.title)
            TextField("Artist", text: $e.artist)
            TextField("Album (required, use the single's name for singles)", text: $e.album)
            hint("Duration \(fmt(e.track.duration)) from \(e.track.source)"
                 + (e.track.app.hasPrefix("com.apple.Music") || e.track.app == "com.spotify.client" ? ""
                    : ". ⚠️ YouTube length may not match the official release; sync from Music or Spotify if you can."))

            HStack {
                Button("Start over") { e.phase = .text }
                Spacer()
                if !e.status.isEmpty { Text(e.status).font(.caption).lineLimit(2) }
                if e.published {
                    Button("Done", action: close).buttonStyle(.borderedProminent)
                } else {
                    Button("Publish to LRCLIB") { e.publish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(e.busy || [e.title, e.artist, e.album].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct TipsView: View {
    let sections: [(String, [String])] = [
        ("Lyrics", [
            "One line per sung phrase, short enough to read at a glance.",
            "Write out every repeat. No “x2” or “[Chorus]” shortcuts.",
            "Capitalize the first word of each line.",
            "No commas or periods at the end of a line (? and ! are fine).",
            "Background vocals and ad-libs go in parentheses: I'm alright (alright)",
            "Write what's actually sung: “gonna”, “'cause”, slang and all. Don't censor unless it's the clean version.",
        ]),
        ("Syncing", [
            "Tap on the first syllable, not the breath before it.",
            "Press ♪ when singing stops for a solo or outro, so the last line doesn't stay lit.",
            "Most people tap 0.1–0.2s late. If every line feels behind in review, use Shift all −0.1s.",
        ]),
        ("Song info", [
            "Sync from Apple Music or Spotify, not YouTube, so the length matches the official release.",
            "Keep title, artist and album exactly as your player shows them; that's how the app finds lyrics.",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections, id: \.0) { title, tips in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        ForEach(tips, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Text("Based on Musixmatch's style guide, the most widely followed convention for synced lyrics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(16)
        }
        .frame(width: 340, height: 420)
    }
}

// MARK: - Updates (GitHub Releases)

let repo = "hlqGit/lyrics-sync"

/// "v0.3.0" vs "0.2.0", compared numerically per component.
func isNewer(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

func runTool(_ exe: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Msg(errorDescription: "\((exe as NSString).lastPathComponent) failed") }
}

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var available: String?   // newer version, e.g. "0.3.0"
    @Published var status = ""
    private var zipURL: URL?
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func check(manual: Bool = false) async {
        struct Rel: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String; let assets: [Asset]
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("LyricsSync", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let r = try? JSONDecoder().decode(Rel.self, from: d) else {
            if manual { status = "Couldn't check for updates" }
            return
        }
        if isNewer(r.tag_name, than: current), let a = r.assets.first(where: { $0.name.hasSuffix(".zip") }) {
            available = r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            zipURL = a.browser_download_url
            status = ""
        } else if manual {
            status = "You're up to date (\(current))"
        }
    }

    /// Download, unzip, check it's really Lyrics, then quit; a tiny shell script swaps the bundle and relaunches.
    func install() async {
        guard let zipURL else { return }
        let target = Bundle.main.bundlePath
        guard FileManager.default.isWritableFile(atPath: (target as NSString).deletingLastPathComponent) else {
            status = "Can't write to \((target as NSString).deletingLastPathComponent)"; return
        }
        status = "Downloading…"
        do {
            let (zip, _) = try await URLSession.shared.download(from: zipURL)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            let newApp = dir.appendingPathComponent("Lyrics.app")
            guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw Msg(errorDescription: "download didn't contain Lyrics.app")
            }
            // Wait for this process to exit, move the old app aside, move the new one in (restore the old one if
            // that fails), then reopen.
            let script = """
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf "$1.old"
            if mv "$1" "$1.old" && mv "$2" "$1"; then rm -rf "$1.old"; else [ -e "$1" ] || mv "$1.old" "$1"; fi
            open "$1"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh", target, newApp.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
        }
    }
}

struct UpdateBanner: View {
    @ObservedObject var u = Updater.shared

    var body: some View {
        if u.available != nil || !u.status.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text(u.available.map { "Lyrics \($0) is available" } ?? u.status).font(.caption.bold())
                Spacer()
                if u.available != nil {
                    if !u.status.isEmpty { Text(u.status).font(.caption).lineLimit(1) }
                    Button("Update & Restart") { Task { await u.install() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(u.status == "Downloading…")
                } else {
                    Button("OK") { u.status = "" }.controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15))
        }
    }
}

// MARK: - Entry + self-check

func selfTest() {
    let l = parseLRC("[ar:X]\n[00:01.50]Hello\n[00:10.00][01:02.25]Chorus\n[00:05.00]\n")
    precondition(l.map(\.time) == [1.5, 5, 10, 62.25], "times \(l.map(\.time))")
    precondition(l.map(\.text) == ["Hello", "", "Chorus", "Chorus"])
    precondition(clean("Song (Official Music Video)") == "Song")
    precondition(clean("Song (feat. Someone)") == "Song")
    precondition(clean("Song - Remastered 2011") == "Song")
    precondition(clean("Left Behind") == "Left Behind")
    let y = ytTrack(title: "Daft Punk - Get Lucky (Official Audio) ft. Pharrell", channel: "DaftPunkVEVO", album: "", duration: 0, app: "", source: "")
    precondition(y.artist == "Daft Punk" && y.title == "Get Lucky", "\(y)")
    let z = ytTrack(title: "Get Lucky", channel: "Daft Punk - Topic", album: "", duration: 0, app: "", source: "")
    precondition(z.artist == "Daft Punk" && z.title == "Get Lucky")
    precondition(lrcTime(62.25) == "[01:02.25]" && lrcTime(59.996) == "[01:00.00]" && lrcTime(-1) == "[00:00.00]")
    precondition(syncableLines("[Chorus]\n  Hello \n\nWorld\n[Verse 2]") == ["Hello", "World"])
    precondition(parseLRC(lrcTime(12.34) + " Hi").first.map { abs($0.time - 12.34) < 0.001 && $0.text == "Hi" } == true)
    // Easy target (first byte must be 0) to check the solver's comparison rule.
    let easy = "00" + String(repeating: "F", count: 62)
    let nonce = solveChallenge(prefix: "abc", target: easy)!
    precondition(Array(SHA256.hash(data: Data(("abc" + nonce).utf8))).first == 0)
    precondition(solveChallenge(prefix: "abc", target: "zz") == nil)
    let song = "Intro line\n\n[Chorus]\nLa la\n  La la \nEnd"
    precondition(nthLine(in: song, equalTo: "La la", occurrence: 0) == 3)
    precondition(nthLine(in: song, equalTo: "La la", occurrence: 1) == 4)   // second chorus line, not the first
    precondition(nthLine(in: song, equalTo: "La la", occurrence: 2) == nil)
    // Tint: a solid red image → red-ish hue, softened; solid grey → near white.
    func solid(_ c: NSColor) -> NSImage { NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in c.setFill(); r.fill(); return true } }
    let red = artTintHSB(solid(.red))!
    precondition((red.h < 0.03 || red.h > 0.97) && red.s > 0.4 && red.b > 0.9, "\(red)")
    precondition(artTintHSB(solid(.gray))!.s < 0.05)
    precondition(isNewer("v0.3.0", than: "0.2.0") && isNewer("0.10.0", than: "0.9.1") && isNewer("1.0", than: "0.9.9"))
    precondition(!isNewer("v0.2.0", than: "0.2.0") && !isNewer("0.2", than: "0.2.0") && !isNewer("0.1.9", than: "0.2.0"))
    print("all tests passed")
}

@main enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--test") { selfTest(); return }
        LyricsApp.main()
    }
}
