import AppKit
import Observation
import WaypointCore

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case signingIn
        case preparingWindows
        case launching
        case updating(UpdateProgress?)
        case pausing(UpdateProgress?)
        case paused(UpdateProgress?)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.signingIn, .signingIn), (.preparingWindows, .preparingWindows), (.launching, .launching),
                 (.updating, .updating), (.pausing, .pausing), (.paused, .paused): true
            case (.failed(let x), .failed(let y)): x == y
            default: false
            }
        }
    }

    private(set) var games: [Game] = []
    private var discoveredGames: [Game] = []
    private var pendingHeroesInstall: ProductInstall?
    private var heroesPlatform = UserDefaults.standard.string(forKey: "heroesPlatform").flatMap(InstallPlatform.init(rawValue:)) ?? .windows
    @ObservationIgnored private var windowsSessions: [String: WindowsHeroesSession] = [:]
    @ObservationIgnored private var windowsObservers: [Int32: any DispatchSourceProcess] = [:]
    /// Game uid -> phase, so each row shows its own progress.
    private(set) var phases: [String: Phase] = [:]
    /// Each job owns its task and retains the original install/update options.
    private var downloads: [String: DownloadJob] = [:]
    private(set) var running: Set<String> = []
    /// Game uid -> result of the last update check.
    private(set) var updates: [String: UpdateCheck] = [:]
    private var lastUpdateCheck: Date?

    /// nil = use the region each game was installed for.
    var regionOverride: Region? {
        didSet { UserDefaults.standard.set(regionOverride?.rawValue, forKey: "regionOverride") }
    }

    /// Saved Battle.net accounts, each with its own web session and last
    /// tokens, so switching between them needs no sign-in.
    private var accountList = AccountList.load() {
        didSet { accountList.save() }
    }
    var accounts: [Account] { accountList.accounts }
    /// The account games launch with.
    var activeAccount: Account? { accountList.active }
    /// The login window is open to add an account or sign one in again.
    private(set) var isAddingAccount = false
    private(set) var isManagingSavedLogin = false
    private var autoLoginStates = AutoLoginState.load() {
        didSet { AutoLoginState.save(autoLoginStates) }
    }
    private var profileFetches: Set<String> = []

    private let library = GameLibrary()
    private let loginWindow = LoginWindow()
    /// Per bundle id, like the web sessions, so test builds never share
    /// keychain items with the installed app.
    private let tokenVault = TokenVault(service: "\(Bundle.main.bundleIdentifier ?? "Waypoint"): Battle.net login tokens")
    private let credentialVault = CredentialVault(service: "\(Bundle.main.bundleIdentifier ?? "Waypoint"): Battle.net passwords")
    private var observers: [NSObjectProtocol] = []

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        Log.notice(.app, "started", nil, [
            "version": info["CFBundleShortVersionString"] as? String ?? "dev",
            "build": info["CFBundleVersion"] as? String ?? "dev",
            "path": Bundle.main.bundlePath,
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Log.notice(.app, "quitting")
            Diagnostics.shared.flush()
        })
        regionOverride = UserDefaults.standard.string(forKey: "regionOverride").flatMap(Region.init(rawValue:))
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        // Coming back to Waypoint picks up games installed or removed
        // meanwhile, and checks for updates (throttled).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                _ = Task { await self?.checkForUpdates() }
            }
        })
        Task { await checkForUpdates(force: true) }
        Task { await setUpAccounts() }
    }

    func reload() {
        discoveredGames = library.games()
        var all = discoveredGames
        if let pendingHeroesInstall {
            all.removeAll { $0.id == pendingHeroesInstall.key }
            all.append(GameCatalog.game(for: pendingHeroesInstall))
        }
        let heroes = all.filter { $0.install.uid == "heroes" }
        let preferred = WindowsHeroes.isAvailable ? heroesPlatform : .macOS
        let selected = heroes.first { $0.install.platform == preferred } ?? heroes.first
        var addedHeroes = false
        games = all.filter { game in
            guard game.install.uid == "heroes" else { return true }
            guard !addedHeroes, game.id == selected?.id else { return false }
            addedHeroes = true
            return true
        }
        refreshRunning()
        Log.info(.library, "scanned", nil, ["games": games.map { "\($0.install.uid)@\($0.install.version ?? "?")" }.joined(separator: ",")])
    }

    func heroesEdition(_ platform: InstallPlatform) -> Game? {
        discoveredGames.first { $0.install.uid == "heroes" && $0.install.platform == platform }
    }

    func selectHeroesEdition(_ platform: InstallPlatform) {
        heroesPlatform = platform
        UserDefaults.standard.set(platform.rawValue, forKey: "heroesPlatform")
        reload()
    }

    func defaultPlatform(for product: InstallableProduct) -> InstallPlatform {
        if product.productCode == "hero" {
            return pendingHeroesInstall?.platform ?? (WindowsHeroes.isAvailable ? .windows : .macOS)
        }
        return .macOS
    }

    func isRunning(_ game: Game) -> Bool {
        game.install.uid == "heroes" ? (running.contains("heroes") || running.contains("heroes@windows")) : running.contains(game.id)
    }

    // MARK: Updates

    func availableUpdate(for game: Game) -> UpdateCheck? {
        guard let check = updates[game.id], check.isUpdateAvailable else { return nil }
        return check
    }

    func canUpdate(_ game: Game) -> Bool {
        GameUpdate.canUpdate(game.install) && game.isInstalled && !isRunning(game) && !isBusy(game)
    }

    /// Asks Blizzard's version service which build is live. Cheap (one small
    /// request per game), throttled to every 15 minutes unless forced.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 15 * 60 { return }
        lastUpdateCheck = Date()
        for game in discoveredGames where (game.family != .other || GameUpdate.canUpdate(game.install)) && game.isInstalled {
            do {
                let check = try await GameUpdate(install: game.install).check()
                updates[game.id] = check
                Log.info(.gameUpdate, "checked", nil, ["uid": game.id, "installed": game.install.version ?? "?",
                                                       "latest": check.latest.name, "update_available": check.isUpdateAvailable])
            } catch {
                Log.warning(.gameUpdate, "check_failed", nil, ["uid": game.id, "error": error])
            }
        }
    }

    /// Downloads and installs the latest build; with `verify`, re-checks
    /// every file and repairs what's broken.
    func update(_ game: Game, verify: Bool = false) async {
        guard canUpdate(game) else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.info(.gameUpdate, "requested", nil, ["uid": game.id, "verify": verify])
        let target = updates[game.id]?.latest
        let job = DownloadJob(uid: game.id, category: .gameUpdate) { progress in
            try BattleNet.ensureNotRunning() // ask before downloading anything
            let updater = GameUpdate(install: game.install)
            let plan = try await updater.plan(target: target, verify: verify)
            // A CASC game's new build can need no new files and still have to
            // be recorded (configs, .build.info).
            if !plan.isEmpty || plan.target.buildConfig != game.install.buildConfig {
                try await updater.apply(plan, progress: progress)
            }
        }
        phases.removeValue(forKey: game.id)
        downloads[game.id] = job
        await runDownload(job, uid: game.id)
    }

    // MARK: Languages

    /// What switching `game` to `languages` downloads (with the update, when
    /// one is waiting), for the language sheet.
    func languageChangeSize(_ game: Game, to languages: GameLanguages) async throws -> UInt64 {
        defer { ProcessMemory.releaseFreed() }
        do {
            return try await GameUpdate(install: game.install).plan(target: updates[game.id]?.latest, languages: languages).downloadSize
        } catch {
            if !Task.isCancelled {
                Log.warning(.gameUpdate, "language_size_failed", nil, ["uid": game.id, "error": error])
            }
            throw error
        }
    }

    /// Switches `game` to other text and spoken languages: their files come
    /// down like an update's (with the update, when one is waiting), and the
    /// game is told (`.build.info`, WoW's Config.wtf, the launch locale).
    func changeLanguages(_ game: Game, to languages: GameLanguages) async {
        guard canUpdate(game), languages != game.install.languages else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.notice(.gameUpdate, "languages_requested", nil, ["uid": game.id, "text": languages.text, "speech": languages.speech,
                                                            "from_text": game.install.languages.text,
                                                            "from_speech": game.install.languages.speech])
        let target = updates[game.id]?.latest
        let job = DownloadJob(uid: game.id, category: .gameUpdate) { progress in
            try BattleNet.ensureNotRunning() // ask before downloading anything
            let updater = GameUpdate(install: game.install)
            try await updater.apply(try await updater.plan(target: target, languages: languages), progress: progress)
        }
        phases.removeValue(forKey: game.id)
        downloads[game.id] = job
        await runDownload(job, uid: game.id)
    }

    // MARK: Installs

    /// Games Waypoint can install that aren't installed yet.
    var installable: [InstallableProduct] {
        InstallableProduct.all.filter { product in !games.contains { $0.install.uid == product.uid } }
    }

    func phase(of product: InstallableProduct) -> Phase { phase(uid: defaultPlatform(for: product).installKey(uid: product.uid)) }

    /// What an install would download, for the install sheet, and what an
    /// interrupted install into that folder already has.
    func installSize(_ product: InstallableProduct, folder: URL, region: Region,
                     languages: GameLanguages, platform: InstallPlatform = .macOS) async throws -> (download: UInt64, stored: UInt64) {
        defer { ProcessMemory.releaseFreed() }
        do {
            let plan = try await GameInstaller(product: product, folder: folder, region: region, languages: languages, platform: platform).plan()
            return (plan.downloadSize, plan.storedBytes)
        } catch {
            if !Task.isCancelled {
                Log.warning(.install, "size_failed", nil, ["uid": product.uid, "path": folder.path, "error": error])
            }
            throw error
        }
    }

    func install(_ product: InstallableProduct, folder: URL, region: Region, languages: GameLanguages,
                 platform: InstallPlatform = .macOS) async {
        defer { ProcessMemory.releaseFreed() }
        let uid = platform.installKey(uid: product.uid)
        guard !isBusy(uid: uid) else { return }
        if product.productCode == "hero" {
            guard !isBusy(uid: "heroes"), !isBusy(uid: "heroes@windows") else { return }
            pendingHeroesInstall = product.install(at: folder, region: region, languages: languages,
                tagString: "\(platform.manifestTag) \(region.launchOptionValue) \(languages.text) text \(languages.speech) speech", platform: platform)
            selectHeroesEdition(platform)
        }
        Log.notice(.install, "requested", nil, ["uid": product.uid, "path": folder.path, "region": region.rawValue,
                                                "language": languages.text, "speech_language": languages.speech])
        let job = DownloadJob(uid: uid, category: .install) { progress in
            try BattleNet.ensureNotRunning() // ask before downloading anything
            let installer = GameInstaller(product: product, folder: folder, region: region, languages: languages, platform: platform)
            let plan = try await installer.plan()
            try await installer.apply(plan, progress: progress)
            Log.notice(.install, "finished", nil, ["uid": product.uid, "version": plan.version, "path": folder.path])
        }
        phases.removeValue(forKey: uid)
        downloads[uid] = job
        await runDownload(job, uid: uid)
    }

    private func runDownload(_ job: DownloadJob, uid: String) async {
        if await job.run() == .completed, downloads[uid] === job {
            downloads.removeValue(forKey: uid)
            if pendingHeroesInstall?.key == uid { pendingHeroesInstall = nil }
            reload()
            await checkForUpdates(force: true)
        }
    }

    func canPauseDownload(uid: String) -> Bool { downloads[uid]?.canPause == true }

    func pauseDownload(uid: String) { downloads[uid]?.pause() }

    func canCancelDownload(uid: String) -> Bool { downloads[uid]?.canCancel == true }

    /// Stop tracking a paused job. Its verified data stays available for a
    /// later install/update; no writer is active when canCancel is true.
    func cancelDownload(uid: String) {
        guard canCancelDownload(uid: uid) else { return }
        downloads.removeValue(forKey: uid)
        if pendingHeroesInstall?.key == uid { pendingHeroesInstall = nil; reload() }
        phases.removeValue(forKey: uid)
        Log.notice(.cdn, "cancelled", "keeping downloaded data", ["uid": uid])
    }

    func canResumeDownload(uid: String) -> Bool {
        downloads[uid]?.canResume == true && !running.contains(uid)
    }

    func resumeDownload(uid: String) async {
        guard canResumeDownload(uid: uid), let job = downloads[uid] else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.notice(.cdn, "resume_requested", nil, ["uid": uid])
        await runDownload(job, uid: uid)
    }

    private func phase(uid: String) -> Phase {
        guard let job = downloads[uid] else { return phases[uid] ?? .idle }
        switch job.state {
        case .ready, .running: return .updating(job.progress)
        case .pausing: return .pausing(job.progress)
        case .paused: return .paused(job.progress)
        case .failed(let message): return .failed(message)
        case .completed: return .idle
        }
    }

    private func isBusy(uid: String) -> Bool {
        switch phase(uid: uid) {
        case .signingIn, .preparingWindows, .launching, .updating, .pausing, .paused: true
        default: false
        }
    }

    func phase(of game: Game) -> Phase { phase(uid: game.id) }

    func isBusy(_ game: Game) -> Bool { isBusy(uid: game.id) }

    /// Only one sign-in at a time: the login window and the hidden web view
    /// each serve a single request.
    var isSigningIn: Bool { isAddingAccount || isManagingSavedLogin || phases.values.contains(.signingIn) || phases.values.contains(.preparingWindows) }

    func canPlay(_ game: Game) -> Bool {
        game.isSupported && !isRunning(game) && !isBusy(game) && !isSigningIn
    }

    /// `forceSignIn` skips the saved token, for when the game rejects it.
    /// `accountID`: Play As, another saved account for this launch only; the
    /// active one stays active.
    func play(_ game: Game, forceSignIn: Bool = false, as accountID: String? = nil) async {
        guard canPlay(game) else { return }
        let account: Account?
        if let accountID {
            guard let other = accountList[accountID] else { return }
            account = other
        } else {
            account = activeAccount
        }
        Log.info(.launch, "requested", nil, ["uid": game.id, "version": game.install.version ?? "?",
                                             "force_sign_in": forceSignIn, "play_as": accountID != nil])
        downloads.removeValue(forKey: game.id)
        do {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            let mode = CGDisplayCopyDisplayMode(displayID)
            let display = mode.map { WindowsDisplay(width: $0.pixelWidth, height: $0.pixelHeight,
                                                    framesPerSecond: screen?.maximumFramesPerSecond ?? 60) }
            let plan = try GameLauncher.plan(for: game, region: regionOverride, display: display)
            if plan.isWindows { phases[game.id] = .preparingWindows }
            let session = try await GameLauncher.prepareWindows(plan)
            phases[game.id] = .signingIn
            guard let token = await token(for: plan, gameName: game.displayName, account: account,
                                          activate: accountID == nil, forceSignIn: forceSignIn) else {
                Log.notice(.auth, "sign_in_cancelled", nil, ["uid": game.id])
                phases[game.id] = .idle
                return
            }
            phases[game.id] = .launching
            if let session {
                let pid = try await GameLauncher.launchWindows(plan, token: token, session: session, gameName: game.displayName)
                windowsSessions[game.id] = session
                observeWindowsExit(pid: pid, game: game)
            } else {
                try GameLauncher.launch(plan, token: token, gameName: game.displayName)
            }
            UserDefaults.standard.set(game.id, forKey: Self.lastPlayedKey)
            // Keep "launching" until the game shows up in the running list.
            try? await Task.sleep(for: .seconds(4))
            refreshRunning()
            Log.info(.launch, "running_check", nil, ["uid": game.id, "running": running.contains(game.id)])
            phases[game.id] = .idle
        } catch {
            Log.error(.launch, "failed", nil, ["uid": game.id, "error": error])
            phases[game.id] = .failed(errorMessage(error))
        }
    }

    // MARK: Accounts

    var hasSavedLogin: Bool { activeAccount.map { autoLoginStates[$0.id] != nil } ?? false }

    var savedLoginStatus: String {
        guard let account = activeAccount else { return "Sign in to save a Battle.net login." }
        guard let state = autoLoginStates[account.id] else { return "Automatic login is off. Save a login to enable it." }
        if state.isPaused {
            return "Automatic login is paused. Update the saved login to enable it again."
        }
        if let retry = state.retryAfter, retry > Date() {
            return "Automatic login will be available after \(retry.formatted(date: .omitted, time: .shortened))."
        }
        return "Login saved in Keychain. Automatic login is on."
    }

    func editSavedLogin() {
        guard !isSigningIn, let account = activeAccount else { return }
        isManagingSavedLogin = true
        defer { isManagingSavedLogin = false }
        do {
            let old = try? credentialVault.credentials(account: account.id, allowInteraction: true)
            guard let credentials = CredentialEditor.run(account: account, username: old?.username,
                                                          replacing: hasSavedLogin) else { return }
            try credentialVault.save(credentials, account: account.id)
            autoLoginStates[account.id] = AutoLoginState()
            Log.notice(.auth, "saved_login_updated")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func removeSavedLogin() {
        guard !isSigningIn, let account = activeAccount else { return }
        do {
            try credentialVault.remove(account: account.id)
            autoLoginStates.removeValue(forKey: account.id)
            Log.notice(.auth, "saved_login_removed")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Makes another saved account the one games launch with. Nothing is
    /// fetched: its own web session and tokens are already here.
    func switchAccount(to id: String) {
        guard !isSigningIn, id != accountList.activeID else { return }
        accountList.activate(id)
        Log.notice(.auth, "account_switched", nil, ["accounts": accounts.count])
    }

    /// Signs in to another account in the login window, in a web session of
    /// its own. It becomes the active account.
    func addAccount() async {
        await signIn(title: "Add a Battle.net Account", reason: "add_account")
    }

    /// Signs the active account in again, for when a game won't take its
    /// token. A changed password or authenticator voids all of an account's
    /// tokens, so the other games' ones go too and each gets a fresh one on
    /// its next launch.
    func signInAgain() async {
        guard let account = activeAccount else { return }
        await signIn(title: "Sign In to \(account.displayName) Again", reason: "sign_in_again", replacing: account.id,
                     accountName: account.email)
    }

    /// `replacing`: the account whose saved tokens a sign-in to it replaces;
    /// `accountName`: its email or phone, filled in for the user.
    private func signIn(title: String, reason: String, replacing: String? = nil, accountName: String? = nil) async {
        guard !isSigningIn else { return }
        isAddingAccount = true
        defer { isAddingAccount = false }
        let target = loginTarget()
        let session = WebSessionID.fresh()
        Log.notice(.auth, "login_window_shown", nil, ["codename": target.codename, "region": target.region.rawValue, "reason": reason])
        guard let token = await loginWindow.run(BattleNetLogin.url(codename: target.codename, region: target.region),
                                                title: title, session: session, accountName: accountName)
        else {
            Log.notice(.auth, "sign_in_cancelled", nil, ["reason": reason])
            await WebSession.delete(session)
            return
        }
        Log.info(.auth, "token", nil, ["source": "login_window", "codename": target.codename])
        let saved = await adopt(token, codename: target.codename, session: session, typedName: loginWindow.typedAccountName)
        if let replacing, token.accountID == replacing {
            if saved {
                do {
                    try tokenVault.removeAll(account: replacing, except: target.codename)
                    Log.notice(.auth, "other_game_tokens_removed")
                } catch {
                    Log.warning(.auth, "token_remove_failed", nil, ["error": error])
                }
            } else {
                // Better asked again on the next Play than handed a dead token.
                tokenVault.removeAll(account: replacing)
                Log.notice(.auth, "all_tokens_removed")
            }
        }
    }

    /// Signs the active account out: its web session and saved tokens are
    /// deleted, and the next saved account, if any, becomes active.
    func signOut() async {
        guard !isSigningIn, let account = activeAccount else { return }
        // If deletion fails, keep the account and report it rather than
        // silently leaving a password behind after Sign Out.
        do { try credentialVault.remove(account: account.id) } catch {
            NSAlert(error: error).runModal()
            return
        }
        autoLoginStates.removeValue(forKey: account.id)
        accountList.remove(account.id)
        tokenVault.removeAll(account: account.id)
        for codename in Set(InstallableProduct.all.map(\.codename)) {
            let options = LaunchOptions(gameKey: codename)
            if let stored = try? options.storedToken(), LoginToken(stored)?.accountID == account.id {
                options.clearToken()
            }
        }
        await WebSession.delete(account.session)
        Log.notice(.auth, "signed_out", nil, ["accounts": accounts.count])
    }

    /// At launch: deletes web sessions no account uses (a cancelled sign-in
    /// leaves one behind), looks up names still missing, and the first time,
    /// finds out who is signed in to the session from before Waypoint had
    /// accounts.
    private func setUpAccounts() async {
        await WebSession.deleteAll(except: Set(accounts.map(\.session)))
        for account in accounts where account.battleTag == nil {
            await refreshProfile(account.id)
        }
        let adoptedKey = "adoptedSharedWebSession"
        guard accounts.isEmpty, !UserDefaults.standard.bool(forKey: adoptedKey) else { return }
        UserDefaults.standard.set(true, forKey: adoptedKey)
        guard await WebSession.hasCookies(.shared) else { return }
        let target = loginTarget()
        let result = await SilentTokenFetcher().fetch(BattleNetLogin.url(codename: target.codename, region: target.region),
                                                      session: .shared)
        // Someone may have signed in meanwhile.
        guard case .token(let token) = result, accounts.isEmpty else { return }
        Log.info(.auth, "token", nil, ["source": "web_session", "codename": target.codename, "reason": "adopt"])
        await adopt(token, codename: target.codename, session: .shared)
    }

    /// The game launched last: signing in to an account gets the token for
    /// it, since each game needs one of its own.
    private static let lastPlayedKey = "lastPlayedGame"

    /// The login page asks which game it signs in to (`app=`): the game
    /// launched last, else the first that can be played, else Hearthstone,
    /// which every account has.
    private func loginTarget() -> (codename: String, region: Region) {
        let last = UserDefaults.standard.string(forKey: Self.lastPlayedKey)
        let candidates = games.filter { $0.id == last } + games.filter { $0.id != last }
        let plan = candidates.lazy.compactMap { try? GameLauncher.plan(for: $0, region: self.regionOverride) }.first
        return (plan?.codename ?? InstallableProduct.hearthstone.codename, plan?.region ?? regionOverride ?? .us)
    }

    /// Remembers who signed in where: that account, new or saved, becomes
    /// active and keeps the token for next time. A session it no longer uses
    /// is deleted.
    /// `typedName`: the email or phone typed into the login form, which names
    /// the account until (and unless) Blizzard's account page tells the
    /// BattleTag and email.
    /// Returns whether the token made it into the keychain.
    @discardableResult
    private func adopt(_ token: LoginToken, codename: String, session: WebSessionID, typedName: String? = nil,
                       activate: Bool = true) async -> Bool {
        let id = token.accountID
        let isNew = accountList[id] == nil
        let unused = accountList.signedIn(id, session: session, activate: activate)
        if let typedName, accountList[id]?.email == nil { accountList.setProfile(id, battleTag: nil, email: typedName) }
        var saved = true
        do {
            try tokenVault.save(token, codename: codename)
        } catch {
            saved = false
            Log.warning(.auth, "token_save_failed", nil, ["error": error])
        }
        if isNew { Log.notice(.auth, "account_added", nil, ["accounts": accounts.count]) }
        if let unused { await WebSession.delete(unused) }
        if accountList[id]?.battleTag == nil { Task { await refreshProfile(id) } }
        return saved
    }

    /// Looks up the account's BattleTag and email on Blizzard's account page.
    private func refreshProfile(_ id: String) async {
        guard let account = accountList[id], profileFetches.insert(id).inserted else { return }
        defer { profileFetches.remove(id) }
        switch await ProfileFetcher().fetch(session: account.session) {
        case .signedIn(let profile):
            if let other = profile.accountID, other != id {
                Log.warning(.auth, "profile_other_account")
                return
            }
            accountList.setProfile(id, battleTag: profile.battleTag, email: profile.email)
            Log.info(.auth, "profile", nil, ["battletag": profile.battleTag != nil, "email": profile.email != nil])
        case .signedOut:
            Log.info(.auth, "profile_signed_out")
        case .failed:
            Log.info(.auth, "profile_failed")
        }
    }

    /// The account's token for the game, from the keychain. Without one (or
    /// when forced), signs in once with the saved password when opted in, then
    /// opens the login window; a rejected saved login goes to the interactive
    /// window instead. `activate`: whether whoever signs in becomes the
    /// active account.
    private func token(for plan: LaunchPlan, gameName: String, account: Account?, activate: Bool,
                       forceSignIn: Bool) async -> LoginToken? {
        // Only where the token came from is logged, never the token.
        let url = BattleNetLogin.url(codename: plan.codename, region: plan.region)
        let title = "Sign in to play \(gameName)" + (activate ? "" : account.map { " as \($0.displayName)" } ?? "")
        // Only tokens Waypoint got itself. The one Battle.net leaves in the
        // game's Launch Options can be long expired: the game then shows
        // "Closed" and Waypoint can't tell, so it would keep handing it over.
        // Nothing is refreshed first: Battle.net's login page keeps no session
        // that signs in again without the form, and a token lasts for months.
        if !forceSignIn, let account, let token = tokenVault.token(account: account.id, codename: plan.codename) {
            Log.info(.auth, "token", nil, ["source": "keychain", "codename": plan.codename])
            return token
        }

        if let account, var state = autoLoginStates[account.id], state.begin() {
            autoLoginStates[account.id] = state // Persist before reading/submitting the password.
            let session = forceSignIn ? WebSessionID.fresh() : account.session
            let result: CredentialTokenFetcher.Result
            do {
                if let credentials = try credentialVault.credentials(account: account.id) {
                    Log.info(.auth, "automatic_login_started")
                    result = await CredentialTokenFetcher().fetch(url, session: session, credentials: credentials)
                } else {
                    state.requiresSignIn()
                    result = .failed
                }
            } catch {
                // A locked/unavailable Keychain counts as a temporary failure.
                result = .failed
            }
            switch result {
            case .token(let token):
                guard token.accountID == account.id else {
                    state.requiresSignIn()
                    autoLoginStates[account.id] = state
                    if session != account.session { await WebSession.delete(session) }
                    showWrongSavedAccount(account)
                    return nil
                }
                state.succeeded()
                autoLoginStates[account.id] = state
                Log.info(.auth, "token", nil, ["source": "saved_login", "codename": plan.codename])
                await adopt(token, codename: plan.codename, session: session, activate: activate)
                return token
            case .interaction(let view):
                state.requiresSignIn()
                autoLoginStates[account.id] = state
                Log.notice(.auth, "automatic_login_paused")
                let notice = "Automatic login is paused. Complete sign-in below. If your password changed, \(updateSavedLoginHint(account))."
                guard let token = await loginWindow.run(url, title: title, session: session,
                                                       preparedWebView: view, notice: notice) else {
                    if session != account.session { await WebSession.delete(session) }
                    return nil
                }
                guard token.accountID == account.id else {
                    if session != account.session { await WebSession.delete(session) }
                    showWrongSavedAccount(account)
                    return nil
                }
                // Manual sign-in may have used another password: only an
                // explicit Update Saved Login re-enables these credentials.
                await adopt(token, codename: plan.codename, session: session, typedName: loginWindow.typedAccountName,
                            activate: activate)
                return token
            case .failed:
                state.failedTemporarily()
                autoLoginStates[account.id] = state
                if session != account.session { await WebSession.delete(session) }
                Log.notice(.auth, "automatic_login_failed", nil, ["attempts": state.attempts, "paused": state.isPaused])
            }
        }

        var notices: [String] = []
        if let account, autoLoginStates[account.id]?.isPaused == true {
            notices.append("Automatic login is paused. Sign in here, then \(updateSavedLoginHint(account)) to replace the saved password.")
        }
        // Signed in, yet asked again: Battle.net's tokens are per game.
        if account != nil, !forceSignIn {
            notices.append("Battle.net signs in to each game separately, so \(gameName) needs its own sign-in. It’s needed only once.")
        }
        let session = WebSessionID.fresh()
        Log.notice(.auth, "login_window_shown", nil, ["codename": plan.codename, "region": plan.region.rawValue, "forced": forceSignIn])
        guard let token = await loginWindow.run(url, title: title, session: session, accountName: account?.email,
                                               notice: notices.isEmpty ? nil : notices.joined(separator: "\n\n")) else {
            await WebSession.delete(session)
            return nil
        }
        // Play As names the account; launching another one would surprise.
        if !activate, let account, token.accountID != account.id {
            await WebSession.delete(session)
            Log.warning(.auth, "play_as_other_account")
            let alert = NSAlert()
            alert.messageText = "That’s a different account"
            alert.informativeText = "You signed in to a different Battle.net account than \(account.displayName), so \(gameName) wasn’t started. Try again and sign in as \(account.displayName)."
            alert.runModal()
            return nil
        }
        Log.info(.auth, "token", nil, ["source": "login_window", "codename": plan.codename])
        await adopt(token, codename: plan.codename, session: session, typedName: loginWindow.typedAccountName,
                    activate: activate)
        return token
    }

    /// Where to fix an account's saved login: the menus act on the active one.
    private func updateSavedLoginHint(_ account: Account) -> String {
        account.id == activeAccount?.id
            ? "use Update Saved Login in the account menu or Settings"
            : "switch to \(account.displayName), then use Update Saved Login in the account menu or Settings"
    }

    private func showWrongSavedAccount(_ account: Account) {
        Log.warning(.auth, "saved_login_other_account")
        let alert = NSAlert()
        alert.messageText = "The saved login belongs to a different account"
        alert.informativeText = "Automatic login is paused. To enter this account’s login and password, \(updateSavedLoginHint(account))."
        alert.runModal()
    }

    private func refreshRunning() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL }
        running = Set(discoveredGames.filter { game in
            if game.install.platform == .windows {
                return !WineProcesses.heroesAndSwitcher(in: URL(fileURLWithPath: game.install.installPath)).isEmpty
            }
            guard let app = game.appURL?.standardizedFileURL else { return false }
            return runningApps.contains(app)
        }.map(\.id)).union(windowsSessions.keys)
        for game in discoveredGames where game.install.platform == .windows {
            for pid in WineProcesses.heroesAndSwitcher(in: URL(fileURLWithPath: game.install.installPath)) {
                observeWindowsExit(pid: pid, game: game)
            }
        }
    }

    private func observeWindowsExit(pid: Int32, game: Game) {
        guard windowsObservers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windowsObservers.removeValue(forKey: pid)?.cancel()
                if let session = self.windowsSessions[game.id] {
                    Task {
                        let survivors = await session.gameExited()
                        if survivors.isEmpty {
                            if self.windowsSessions[game.id] === session { self.windowsSessions.removeValue(forKey: game.id) }
                        } else {
                            for survivor in survivors { self.observeWindowsExit(pid: survivor, game: game) }
                        }
                        self.refreshRunning()
                    }
                } else {
                    Task { await WindowsHeroes.cleanupAfterExit(install: game.install) }
                }
                self.refreshRunning()
            }
        }
        windowsObservers[pid] = source
        source.activate()
    }
}
