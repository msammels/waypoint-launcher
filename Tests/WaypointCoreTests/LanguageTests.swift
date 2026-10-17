import Foundation
import Testing
@testable import WaypointCore

/// Hearthstone's tags as Battle.net wrote them on this Mac.
private let battleNetTags = "OSX adventure base EU? acct-CZE? geoip-NL? enUS speech?:OSX adventure base EU? acct-CZE? geoip-NL? enUS text?"

@Test func readsLanguagesFromTags() {
    #expect(TagLanguages.text(in: battleNetTags) == "enUS")
    #expect(TagLanguages.speech(in: battleNetTags) == "enUS")
    let mixed = "OSX x86_64 arm64 EU? deDE speech?:OSX x86_64 arm64 EU? ruRU text?"
    #expect(TagLanguages.speech(in: mixed) == "deDE")
    #expect(TagLanguages.text(in: mixed) == "ruRU")
    #expect(TagLanguages.text(in: "OSX EU enUS") == nil)
    for word in ["OSX", "EU", "arm64", "x86_64", "acct-CZE", "geoip-NL", "base"] { #expect(!TagLanguages.isLocale(word)) }
    for word in ["enUS", "zhTW", "ptBR"] { #expect(TagLanguages.isLocale(word)) }
}

@Test func swapsLanguagesKeepingTheOtherTags() {
    let swapped = TagLanguages.replacing(in: battleNetTags, with: GameLanguages(text: "ruRU", speech: "deDE"))
    #expect(swapped == "OSX adventure base EU? acct-CZE? geoip-NL? deDE speech?:OSX adventure base EU? acct-CZE? geoip-NL? ruRU text?")
    // Speech and text sets in the other order, and a set without a locale.
    #expect(TagLanguages.replacing(in: "OSX EU? enUS text?:OSX EU? speech?", with: GameLanguages(text: "frFR", speech: "esES"))
            == "OSX EU? frFR text?:OSX EU? esES speech?")
    // No speech and text sets: both, from the one there is.
    let german = GameLanguages(text: "ruRU", speech: "deDE")
    #expect(TagLanguages.replacing(in: "OSX EU enUS", with: german) == "OSX EU deDE speech?:OSX EU ruRU text?")
    // Odd strings come out as two clean sets too: only a text set, one set
    // naming both, two locales in a set, nothing at all.
    for odd in ["OSX EU enUS text?", "OSX EU enUS speech? text?", "OSX EU enUS frFR"] {
        let fixed = TagLanguages.replacing(in: odd, with: german)
        #expect(fixed == "OSX EU deDE speech?:OSX EU ruRU text?", "\(odd)")
        #expect(TagLanguages.text(in: fixed) == "ruRU" && TagLanguages.speech(in: fixed) == "deDE")
    }
    #expect(TagLanguages.replacing(in: "", with: german) == "deDE speech?:ruRU text?")
}

@Test func buildsTagsForTwoLanguagesLikeTheAgent() throws {
    let config = try ProductConfig(json: Data("""
    {"all":{"config":{"data_dir":"Data/"}},"platform":{"mac":{"config":{"tags":["OSX"],"tags_64bit":["x86_64"]}}}}
    """.utf8))
    #expect(config.tagString(region: .eu, languages: GameLanguages(text: "ruRU", speech: "enUS"))
            == "OSX x86_64 arm64 EU? enUS speech?:OSX x86_64 arm64 EU? ruRU text?")
    #expect(config.tagString(region: .eu, language: "ruRU") == config.tagString(region: .eu, languages: GameLanguages(text: "ruRU")))
}

@Test func installLanguagesComeFromTagsThenRecords() {
    var install = ProductInstall(uid: "wow", productCode: "wow", installPath: "/tmp/wow", region: "eu", textLanguage: "frFR")
    #expect(install.languages == GameLanguages(text: "frFR", speech: "frFR"))
    install.speechLanguage = "enUS"
    #expect(install.languages == GameLanguages(text: "frFR", speech: "enUS"))
    install.tagString = "OSX EU? deDE speech?:OSX EU? ruRU text?"
    #expect(install.languages == GameLanguages(text: "ruRU", speech: "deDE"))

    let changed = install.with(GameLanguages(text: "esES", speech: "esMX"), tags: install.tagString!)
    #expect(changed.tagString == "OSX EU? esMX speech?:OSX EU? esES text?")
    #expect(changed.textLanguage == "esES" && changed.speechLanguage == "esMX")
    #expect(changed.languages == GameLanguages(text: "esES", speech: "esMX"))
}

/// Waypoint's languages win over Battle.net's records only when Waypoint
/// chose them, stay chosen through updates in the same languages, and give
/// way to a language picked in Battle.net afterwards.
@Test func chosenLanguagesOverrideBattleNetsRecord() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = InstallStateStore(file: file)
    let agent = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/Applications/Hearthstone", region: "eu",
                               textLanguage: "enUS", speechLanguage: "enUS", version: "36.6.3", buildConfig: "a", tagString: battleNetTags)

    // A plain update: the build is Waypoint's, the languages Battle.net's.
    var updated = agent
    updated.tagString = "OSX EU? deDE speech?:OSX EU? deDE text?"
    try store.record(uid: "hs_beta", InstalledBuild(buildConfig: "b", version: "36.6.4", install: updated))
    #expect(store.apply(to: agent).version == "36.6.4")
    #expect(store.apply(to: agent).tagString == battleNetTags)

    // A language change in Waypoint: its languages win…
    let german = agent.with(GameLanguages(text: "deDE"), tags: battleNetTags)
    try store.record(uid: "hs_beta", InstalledBuild(buildConfig: "b", version: "36.6.4", install: german,
                                                    chosenLanguages: true, replacedTags: battleNetTags))
    #expect(store.apply(to: agent).languages == GameLanguages(text: "deDE"))
    // …and still do after an update that keeps them…
    try store.record(uid: "hs_beta", InstalledBuild(buildConfig: "c", version: "36.6.5", install: german))
    #expect(store.apply(to: agent).languages == GameLanguages(text: "deDE"))
    #expect(store.apply(to: agent).version == "36.6.5")
    // …and after changing again, measured against Battle.net's original tags.
    let french = german.with(GameLanguages(text: "frFR"), tags: german.tagString!)
    try store.record(uid: "hs_beta", InstalledBuild(buildConfig: "c", version: "36.6.5", install: french,
                                                    chosenLanguages: true, replacedTags: german.tagString))
    #expect(store.load()["hs_beta"]?.replacedTags == battleNetTags)
    #expect(store.apply(to: agent).languages == GameLanguages(text: "frFR"))

    // A language picked in Battle.net afterwards, same build: Battle.net's wins.
    var picked = agent
    picked.tagString = TagLanguages.replacing(in: battleNetTags, with: GameLanguages(text: "ruRU"))
    #expect(store.apply(to: picked).languages == GameLanguages(text: "ruRU"))
    #expect(store.apply(to: picked).version == "36.6.5")
    // Battle.net installing something newer wins outright.
    var newer = agent
    newer.version = "36.7.0"
    #expect(store.apply(to: newer).languages == GameLanguages(text: "enUS"))
    // Another copy of the game elsewhere isn't this record's.
    var elsewhere = agent
    elsewhere.installPath = "/Volumes/Games/Hearthstone"
    #expect(store.apply(to: elsewhere) == elsewhere)
    // An update in other languages than the chosen ones ends the choice.
    try store.record(uid: "hs_beta", InstalledBuild(buildConfig: "d", version: "36.6.6", install: agent))
    #expect(store.load()["hs_beta"]?.chosenLanguages == nil)
}

/// Records written before languages were tracked still load.
@Test func oldInstallRecordsStillDecode() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(#"{"wow":{"buildConfig":"a","version":"12.1.5","installPath":"/x","productCode":"wow","textLanguage":"ruRU"}}"#.utf8)
        .write(to: file)
    let build = try #require(InstallStateStore(file: file).load()["wow"])
    #expect(build.chosenLanguages == nil && build.speechLanguage == nil)
    #expect(build.install(uid: "wow")?.languages == GameLanguages(text: "ruRU"))
}

@Test func writesWoWLanguagesIntoConfigWTF() throws {
    let flavor = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-wow-\(UUID().uuidString)/_retail_")
    defer { try? FileManager.default.removeItem(at: flavor.deletingLastPathComponent()) }
    let config = flavor.appendingPathComponent("WTF/Config.wtf")

    // A new install in one language leaves the first launch to the game.
    try WoWConfig.setLanguages(GameLanguages(text: "ruRU"), flavorFolder: flavor)
    #expect(!FileManager.default.fileExists(atPath: config.path))
    // No Config.wtf yet and another spoken language: just the two lines.
    try WoWConfig.setLanguages(GameLanguages(text: "ruRU", speech: "enUS"), flavorFolder: flavor)
    #expect(try String(contentsOf: config, encoding: .utf8) == "SET textLocale \"ruRU\"\nSET audioLocale \"enUS\"\n")

    // The game's own file: those lines change (whatever their case), the rest stays, CRLF too.
    try Data("SET portal \"EU\"\r\nSET TEXTLOCALE \"enUS\"\r\nSET gxWindow \"1\"\r\n".utf8).write(to: config)
    try WoWConfig.setLanguages(GameLanguages(text: "deDE"), flavorFolder: flavor)
    #expect(try String(contentsOf: config, encoding: .utf8)
            == "SET portal \"EU\"\r\nSET textLocale \"deDE\"\r\nSET gxWindow \"1\"\r\nSET audioLocale \"deDE\"\r\n")

    // Not UTF-8: every other byte survives.
    try (Data("SET accountName \"".utf8) + Data([0xE9]) + Data("\"\nSET textLocale \"enUS\"\n".utf8)).write(to: config)
    try WoWConfig.setLanguages(GameLanguages(text: "frFR"), flavorFolder: flavor)
    #expect(try Data(contentsOf: config)
            == Data("SET accountName \"".utf8) + Data([0xE9]) + Data("\"\nSET textLocale \"frFR\"\nSET audioLocale \"frFR\"\n".utf8))

    // Unreadable: an error, and the file as it was (not two lines).
    try Data("SET portal \"EU\"\n".utf8).write(to: config)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path) }
    #expect(throws: (any Error).self) { try WoWConfig.setLanguages(GameLanguages(text: "deDE"), flavorFolder: flavor) }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
    #expect(try String(contentsOf: config, encoding: .utf8) == "SET portal \"EU\"\n")

    // A symlinked Config.wtf stays a symlink; its target changes.
    let target = flavor.deletingLastPathComponent().appendingPathComponent("shared-config.wtf")
    try Data("SET textLocale \"enUS\"\n".utf8).write(to: target)
    try FileManager.default.removeItem(at: config)
    try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
    try WoWConfig.setLanguages(GameLanguages(text: "esES"), flavorFolder: flavor)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "SET textLocale \"esES\"\nSET audioLocale \"esES\"\n")
}
