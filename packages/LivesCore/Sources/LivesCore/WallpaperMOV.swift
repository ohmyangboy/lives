import Foundation

/// 仅处理本应用固定 HEVC 编码器输出的非分片 MOV；不解析任意导入素材。
/// 逐字段生成 G08–G11 的 mebx，不读取原片、模板或私有框架。
enum WallpaperMOV {
    static let infoKey = "com.apple.quicktime.live-photo-info"
    static let stillKey = "com.apple.quicktime.still-image-time"
    static let transformKey = "com.apple.quicktime.live-photo-still-image-transform"
    static let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    static func fail() -> LivesCoreError { .renderFailed("动态锁屏容器或定时元数据不符合固定配置") }
    static func be(_ n: Int, _ count: Int = 4) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    static func le(_ n: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    static func zero(_ n: Int) -> Data { Data(repeating: 0, count: n) }
    static func box(_ key: String, _ payload: Data) -> Data { box(Data(key.utf8), payload) }
    static func box(_ key: Data, _ payload: Data) -> Data { be(payload.count + 8) + key + payload }
    static func number(_ data: Data, _ at: Int, _ count: Int = 4) throws -> Int {
        guard count <= 8, at >= 0, at <= data.count - count else { throw fail() }
        var value: UInt64 = 0
        for byte in data[at..<at + count] { value = value << 8 | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw fail() }
        return Int(value)
    }
    struct Atom { let key: String; let data: Data; let offset: Int; let header: Int }
    static func atoms(_ data: Data, start: Int = 8) throws -> [Atom] {
        var offset = start; var result: [Atom] = []
        while offset < data.count {
            guard offset <= data.count - 8 else { throw fail() }
            var size = try number(data, offset); var header = 8
            if size == 1 { size = try number(data, offset + 8, 8); header = 16 }
            if size == 0 { size = data.count - offset }
            guard size >= header, size <= data.count - offset else { throw fail() }
            result.append(Atom(key: String(decoding: data[offset + 4..<offset + 8], as: UTF8.self),
                               data: Data(data[offset..<offset + size]), offset: offset, header: header))
            offset += size
        }
        return result
    }
    static func child(_ data: Data, _ key: String, start: Int = 8) throws -> Data {
        let found = try atoms(data, start: start).filter { $0.key == key }
        guard found.count == 1 else { throw fail() }; return found[0].data
    }
    static func table(_ track: Data) throws -> Data { try child(child(child(track, "mdia"), "minf"), "stbl") }
    static func samples(_ data: Data, _ track: Data) throws -> [Data] {
        let t = try table(track), sz = try child(t, "stsz"), sc = try child(t, "stsc")
        let count = try number(sz, 16), constant = try number(sz, 12)
        guard count > 0, count <= WallpaperExportProfile.frameCount else { throw fail() }
        let sizes = try (0..<count).map { constant == 0 ? try number(sz, 20 + $0 * 4) : constant }
        let maps = try number(sc, 12)
        guard maps > 0, maps <= WallpaperExportProfile.frameCount, sc.count == 16 + maps * 12 else { throw fail() }
        let mapping = try (0..<maps).map { (try number(sc, 16 + $0 * 12), try number(sc, 20 + $0 * 12), try number(sc, 24 + $0 * 12)) }
        guard mapping.first?.0 == 1, mapping.allSatisfy({ $0.1 > 0 && $0.2 == 1 }) else { throw fail() }
        let offsets = try atoms(t).filter { ["stco", "co64"].contains($0.key) }
        guard offsets.count == 1 else { throw fail() }
        let entry = offsets[0], chunks = try number(entry.data, 12), width = entry.key == "co64" ? 8 : 4
        guard chunks > 0, chunks <= WallpaperExportProfile.frameCount, entry.data.count == 16 + chunks * width else { throw fail() }
        let media = try atoms(data, start: 0).filter { $0.key == "mdat" }
        var result: [Data] = []
        for index in 0..<chunks {
            var offset = try number(entry.data, 16 + index * width, width)
            guard let row = mapping.last(where: { $0.0 <= index + 1 }) else { throw fail() }
            for _ in 0..<row.1 {
                guard result.count < sizes.count else { throw fail() }
                let length = sizes[result.count]
                guard length > 0, media.contains(where: { offset >= $0.offset + $0.header && offset <= $0.offset + $0.data.count - length }) else { throw fail() }
                result.append(Data(data[offset..<offset + length])); offset += length
            }
        }
        guard result.count == count else { throw fail() }; return result
    }
    static func stts(_ durations: [Int64]) -> Data {
        var entries: [(Int, Int)] = []
        for duration in durations {
            if entries.last?.1 == Int(duration) { entries[entries.count - 1].0 += 1 }
            else { entries.append((1, Int(duration))) }
        }
        return box("stts", zero(4) + be(entries.count) + entries.reduce(Data()) { $0 + be($1.0) + be($1.1) })
    }
    static func sampleTable(_ description: Data, _ samples: [Data], _ durations: [Int64], _ offset: Int) -> Data {
        box("stbl", description + stts(durations)
            + box("stsc", zero(4) + be(1) + be(1) + be(samples.count) + be(1))
            + box("stsz", zero(8) + be(samples.count) + samples.reduce(Data()) { $0 + be($1.count) })
            + box("stco", zero(4) + be(1) + be(offset)))
    }
    static func description(_ entries: [(String, Data, Data)]) -> Data {
        var keys = Data()
        for (index, entry) in entries.enumerated() {
            keys += box(be(index + 1), box("keyd", Data("mdta".utf8) + Data(entry.0.utf8)) + box("dtyp", entry.1) + entry.2)
        }
        return box("stsd", zero(4) + be(1) + box("mebx", zero(6) + be(1, 2) + box("keys", keys)))
    }
    static func coverDescription() -> Data {
        description([(stillKey, be(0) + be(65), Data()), (transformKey, be(0) + be(83), Data()),
                     (transformKey + "-reference-dimensions", be(0) + be(71), Data())])
    }
    static func coverSample(size: CanvasSize = WallpaperExportProfile.videoSize) -> Data {
        box(be(1), Data([255])) + box(be(2), identity.reduce(Data()) { $0 + be(Int(Double($1).bitPattern), 8) })
            + box(be(3), be(Int(Float(size.width).bitPattern)) + be(Int(Float(size.height).bitPattern)))
    }
    static func infoDescription(size: CanvasSize = WallpaperExportProfile.videoSize) throws -> Data {
        let config = try PropertyListSerialization.data(fromPropertyList: ["LivePhotoMetadataSetupDataVersion": 1], format: .binary, options: 0)
        let setup = box("setu", box("cfgv", config) + box("dims", be(size.width) + be(size.height)))
        let extra = box("sdpd", box("sdpi", be(0))) + setup + box("ctps", box("dtyp", zero(8)))
        return description([(infoKey, be(1) + Data(("com.apple.quicktime." + infoKey).utf8), extra)])
    }
    static func infoSample(tick: Int64) -> Data {
        var raw = zero(136)
        func put(_ at: Int, _ value: Data) { raw.replaceSubrange(at..<at + value.count, with: value) }
        put(0, le(3, 4)); put(4, le(UInt64(Float(1.0 / 60).bitPattern), 4))
        put(42, le(9, 2)); put(64, le(7, 2))
        put(68, identity.reduce(Data()) { $0 + le(UInt64($1.bitPattern), 4) })
        let ns = UInt64(((600 + tick) * 1_000_000_000 + 300) / 600)
        put(104, le(ns, 8)); put(112, le(ns, 8))
        return box(be(1), raw)
    }
    static var matrix: Data { [65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30].reduce(Data()) { $0 + be($1) } }
    static func edit(_ duration: Int, _ start: Int = 0) -> Data {
        let blank = start == 0 ? Data() : be(start) + be(-1) + be(1, 2) + be(0, 2)
        return box("edts", box("elst", zero(4) + be(start == 0 ? 1 : 2) + blank + be(duration) + zero(4) + be(1, 2) + zero(2)))
    }
    static func metadataTrack(info: Bool, samples: [Data], offset: Int, size: CanvasSize = WallpaperExportProfile.videoSize) throws -> Data {
        let duration = info ? Int(WallpaperExportProfile.durationTicks) : 1
        let start = info ? 0 : Int(WallpaperExportProfile.coverTick)
        let tkhd = box("tkhd", be(info ? 15 : 3) + zero(8) + be(info ? 3 : 4) + zero(4) + be(start + duration) + zero(16) + matrix + zero(8))
        let mdhd = box("mdhd", zero(12) + be(600) + be(duration) + be(info ? 0x55c4 : 0, 2) + zero(2))
        func handler(_ component: String, _ subtype: String, _ flags: Int, _ name: String) -> Data {
            box("hdlr", zero(4) + Data((component + subtype + "appl").utf8) + be(flags) + zero(4) + Data([UInt8(name.utf8.count)]) + Data(name.utf8))
        }
        let hdlr = info ? handler("mhlr", "meta", 1, "Core Media Metadata") : box("hdlr", zero(4) + Data("mhlrmeta".utf8) + zero(13))
        let gmhd = box("gmhd", box("gmin", zero(4) + [64, 32768, 32768, 32768, 0, 0].reduce(Data()) { $0 + be($1, 2) }) )
        let dinf = box("dinf", box("dref", zero(4) + be(1) + box(info ? "alis" : "url ", be(1))))
        let table = sampleTable(try info ? infoDescription(size: size) : coverDescription(), samples, info ? WallpaperExportProfile.frameDurations : [1], offset)
        let minf = box("minf", (info ? gmhd + handler("dhlr", "alis", 0, "Core Media Data Handler") : box("nmhd", zero(4))) + dinf + table)
        return box("trak", tkhd + edit(duration, start) + (info ? box("tref", box("cdsc", be(1))) : Data()) + box("mdia", mdhd + hdlr + minf))
    }
    static func identifier(_ id: String) -> Data {
        let keys = box("keys", zero(4) + be(1) + box("mdta", Data("com.apple.quicktime.content.identifier".utf8)))
        let list = box("ilst", box(be(1), box("data", be(1) + zero(4) + Data(id.utf8))))
        return box("meta", box("hdlr", zero(8) + Data("mdta".utf8) + zero(13)) + keys + list)
    }
    static func rewriteVideo(_ track: Data, samples: [Data], offset: Int) throws -> Data {
        var out = Data()
        for atom in try atoms(track) {
            var value = atom.data
            switch atom.key {
            case "mdia", "minf": value = try rewriteVideo(value, samples: samples, offset: offset)
            case "stbl":
                // HEVC sync/dependency tables refer to the same sample sequence. No B frames are accepted.
                if let ctts = try atoms(value).first(where: { $0.key == "ctts" }) {
                    let count = try number(ctts.data, 12)
                    guard count <= WallpaperExportProfile.frameCount else { throw fail() }
                    for i in 0..<count { guard try number(ctts.data, 20 + i * 8) == 0 else { throw fail() } }
                }
                let extra = try atoms(value).filter { ["stss", "sdtp"].contains($0.key) }.reduce(Data()) { $0 + $1.data }
                var rebuilt = sampleTable(try child(value, "stsd"), samples, WallpaperExportProfile.frameDurations, offset)
                rebuilt = box("stbl", Data(rebuilt.dropFirst(8)) + extra); value = rebuilt
            case "tkhd", "mdhd":
                guard value.count >= 32, value[8] == 0 else { throw fail() }
                if atom.key == "mdhd" { guard try number(value, 20) == 600 else { throw fail() } }
                if atom.key == "tkhd" { guard try number(value, 20) == 1 else { throw fail() } }
                value.replaceSubrange(12..<20, with: zero(8))
                let at = atom.key == "tkhd" ? 28 : 24
                value.replaceSubrange(at..<at + 4, with: be(Int(WallpaperExportProfile.durationTicks)))
            case "edts": value = edit(Int(WallpaperExportProfile.durationTicks))
            case "udta", "meta", "tref": continue
            default: break
            }
            out += value
        }
        return box(Data(track[4..<8]), out)
    }
    static func mux(_ base: Data, id: String, size: CanvasSize = WallpaperExportProfile.videoSize) throws -> Data {
        let moov = try child(base, "moov", start: 0)
        let tracks = try atoms(moov).filter { $0.key == "trak" }
        let video = try tracks.filter { try child(child($0.data, "mdia"), "hdlr")[16..<20] == Data("vide".utf8) }
        guard video.count == 1 else { throw fail() }
        let frames = try samples(base, video[0].data)
        guard frames.count == WallpaperExportProfile.frameCount else { throw fail() }
        let ftyp = try child(base, "ftyp", start: 0)
        let cover = [coverSample(size: size)], info = WallpaperExportProfile.frameTicks.map { infoSample(tick: $0) }
        let videoOffset = ftyp.count + 8, coverOffset = videoOffset + frames.reduce(0) { $0 + $1.count }
        let infoOffset = coverOffset + cover[0].count
        let vt = try rewriteVideo(video[0].data, samples: frames, offset: videoOffset)
        let ct = try metadataTrack(info: false, samples: cover, offset: coverOffset, size: size)
        let it = try metadataTrack(info: true, samples: info, offset: infoOffset, size: size)
        var header = try child(moov, "mvhd")
        guard header.count >= 108, header[8] == 0, try number(header, 20) == 600 else { throw fail() }
        header.replaceSubrange(12..<20, with: zero(8)); header.replaceSubrange(24..<28, with: be(Int(WallpaperExportProfile.durationTicks)))
        header.replaceSubrange(header.count - 4..<header.count, with: be(5))
        return ftyp + box("mdat", (frames + cover + info).reduce(Data(), +)) + box("moov", header + vt + ct + it + identifier(id))
    }
    static func validate(_ data: Data, id: String, size: CanvasSize = WallpaperExportProfile.videoSize) throws {
        let moov = try child(data, "moov", start: 0), tracks = try atoms(moov).filter { $0.key == "trak" }
        guard tracks.count == 3, try child(moov, "meta") == identifier(id) else { throw fail() }
        let expected = [WallpaperExportProfile.frameCount, 1, WallpaperExportProfile.frameCount]
        var payload = Data()
        for (i, track) in tracks.enumerated() {
            let content = try samples(data, track.data)
            guard content.count == expected[i] else { throw fail() }
            payload += content.reduce(Data(), +)
            if i > 0 {
                let canonical = i == 1 ? [coverSample(size: size)] : WallpaperExportProfile.frameTicks.map { infoSample(tick: $0) }
                guard content == canonical else { throw fail() }
                let offsets = try child(table(track.data), "stco")
                guard track.data == (try metadataTrack(info: i == 2, samples: content, offset: number(offsets, 16), size: size)) else { throw fail() }
            } else {
                guard try child(table(track.data), "stts") == stts(WallpaperExportProfile.frameDurations) else { throw fail() }
            }
        }
        guard try child(data, "mdat", start: 0).dropFirst(8) == payload else { throw fail() }
    }
}
