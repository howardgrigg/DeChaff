import Foundation

/// One-time updates to saved settings. DeChaff used to assume one church's setup —
/// City On a Hill's YouTube channel, day-first dates — as built-in defaults; those are
/// now settings a new church fills in. Installs that were already relying on the old
/// defaults get them written down, so nothing changes for them.
public enum SettingsMigration {
    public static let channelKey = "dechaff.youtube.channelURL"
    /// The channel DeChaff used to fall back to when none was set.
    public static let legacyChannelURL = "https://www.youtube.com/@cityonahillnz"

    /// Keys that only exist once DeChaff has been used — so their presence means this
    /// isn't a fresh install.
    static let usageKeys = ["dechaff.ytdlp.version", "dechaff.preacher", "dechaff.series", "dechaff.artwork",
                            "dechaff.date", "dechaff.titleFormat", "dechaff.filenameTemplate"]

    static let doneKey = "dechaff.migrations.formatDefaults"

    /// Call at launch, before settings are read. Runs once: on the first launch of a fresh
    /// install it just records that it ran, so the old defaults never reach a new church.
    public static func run(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        let usedBefore = usageKeys.contains { defaults.object(forKey: $0) != nil }
        guard usedBefore else { return }
        if defaults.object(forKey: channelKey) == nil {
            defaults.set(legacyChannelURL, forKey: channelKey)
        }
        // Numeric dates in titles were always read day-first.
        if defaults.object(forKey: TitleDateOrder.key) == nil {
            defaults.set(TitleDateOrder.dayFirst.rawValue, forKey: TitleDateOrder.key)
        }
    }
}
