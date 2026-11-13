import Foundation

/// Ecosistemele de dezvoltare. Servesc la grupare și filtrare în secțiunea Dezvoltator; se caută toate, iar
/// ce nu există pe Mac nu apare. Utilizatorul poate ascunde un ecosistem (nu se mai caută deloc).
enum Tech: String, CaseIterable, Identifiable, Sendable {
    case js, python, rust, go, java, apple, android, flutter, php, ruby, dotnet, cpp, elixir, haskell, other,
         gamedev, infra, docker, tools, ai, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .js: "JavaScript / Node"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        case .java: "Java / Kotlin / Scala"
        case .apple: "Xcode / Swift"
        case .android: "Android"
        case .flutter: "Flutter / Dart"
        case .php: "PHP"
        case .ruby: "Ruby"
        case .dotnet: ".NET"
        case .cpp: "C / C++"
        case .elixir: "Elixir / Erlang"
        case .haskell: "Haskell"
        case .other: tr("Alte limbaje")
        case .gamedev: tr("Jocuri (Unity, Unreal, Godot)")
        case .infra: tr("Infrastructură")
        case .docker: tr("Containere și VM-uri")
        case .tools: tr("Homebrew și editoare")
        case .ai: tr("Modele AI locale")
        case .claude: "Claude"
        }
    }

    var icon: String {
        switch self {
        case .js: "shippingbox"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .rust: "gearshape.2"
        case .go: "hare"
        case .java: "cup.and.saucer"
        case .apple: "swift"
        case .android: "candybarphone"
        case .flutter: "bird"
        case .php: "server.rack"
        case .ruby: "diamond"
        case .dotnet: "number"
        case .cpp: "c.square"
        case .elixir: "drop"
        case .haskell: "function"
        case .other: "curlybraces"
        case .gamedev: "gamecontroller"
        case .infra: "network"
        case .docker: "cube.box"
        case .tools: "wrench.and.screwdriver"
        case .ai: "cpu"
        case .claude: "terminal"
        }
    }

    /// Urme pe disc că ecosistemul e folosit (doar pentru răspunsul implicit la „ești dezvoltator?”).
    func detect() -> Bool {
        func any(_ paths: [String]) -> Bool { !Paths.existing(paths).isEmpty }
        let C = Paths.hp("Library", "Caches")
        switch self {
        case .js:
            return any([Paths.hp(".npm"), Paths.hp(".bun"), Paths.hp("Library", "pnpm"), Paths.hp(".nvm"), Paths.hp(".yarn"),
                        Paths.join(C, "Yarn"), Paths.hp(".volta"), Paths.hp(".fnm")])
        case .apple:
            return any([Paths.hp("Library", "Developer", "Xcode"), Paths.hp("Library", "Developer", "CoreSimulator")])
        case .android:
            return any([Paths.hp(".android"), Paths.hp("Library", "Android")])
        case .flutter:
            return any([Paths.hp(".pub-cache"), Paths.hp(".flutter")])
        case .rust:
            return any([Paths.hp(".cargo"), Paths.hp(".rustup")])
        case .go:
            return Targets.goCLI != nil || any([Paths.hp("go", "pkg"), Paths.join(C, "go-build")])
        case .java:
            return any([Paths.hp(".m2"), Paths.hp(".gradle"), Paths.hp(".sbt"), Paths.hp(".sdkman")])
        case .python:
            return any([Paths.join(C, "pip"), Paths.hp(".cache", "uv"), Paths.join(C, "uv"), Paths.hp(".pyenv"),
                        Paths.hp(".conda"), Paths.hp(".virtualenvs"), Paths.join(C, "pypoetry")])
        case .php:
            return any([Paths.hp(".composer"), Paths.join(C, "composer"), Paths.hp(".config", "composer")])
        case .ruby:
            return any([Paths.hp(".gem"), Paths.hp(".bundle"), Paths.hp(".rbenv"), Paths.hp(".rvm")])
        case .dotnet:
            return any([Paths.hp(".nuget"), Paths.hp(".dotnet")])
        case .cpp:
            return any([Paths.hp(".conan2"), Paths.hp(".conan"), Paths.join(C, "ccache"), Paths.hp(".ccache")])
        case .elixir:
            return any([Paths.hp(".hex"), Paths.hp(".mix"), Paths.hp(".cache", "rebar3")])
        case .haskell:
            return any([Paths.hp(".stack"), Paths.hp(".cabal"), Paths.hp(".ghcup")])
        case .gamedev:
            return any([Paths.hp("Library", "Unity"), Paths.hp("Library", "Application Support", "Godot")])
        case .infra:
            return any([Paths.hp(".terraform.d"), Paths.hp(".vagrant.d"), Paths.hp(".minikube")])
        case .other, .docker, .tools, .ai, .claude:
            return false
        }
    }
}

/// Dezvoltator sau nu (întrebat o dată, la prima pornire) și ecosistemele ascunse din secțiunea Dezvoltator.
enum Profile {
    static let devModeKey = "profileDevMode"
    /// Utilizatorul a răspuns la întrebarea de la prima pornire.
    static let askedKey = "profileDevModeAsked"
    /// Valorile `Tech.rawValue` ascunse, separate prin virgulă (formă compatibilă cu `@AppStorage`).
    static let hiddenKey = "profileHiddenTechs"

    /// Până la răspuns: ghicit din ce e instalat, ca prima scanare să arate deja ce trebuie.
    static var devMode: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: devModeKey) == nil { return guess() }
        return d.bool(forKey: devModeKey)
    }

    static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    static var hidden: Set<Tech> { decode(UserDefaults.standard.string(forKey: hiddenKey) ?? "") }

    /// Ecosistemele care se caută acum: toate, fără cele ascunse; nimic dacă nu ești dezvoltator.
    static var active: Set<Tech> { devMode ? Set(Tech.allCases).subtracting(hidden) : [] }

    static func decode(_ s: String) -> Set<Tech> {
        Set(s.split(separator: ",").compactMap { Tech(rawValue: String($0)) })
    }

    static func encode(_ t: Set<Tech>) -> String {
        Tech.allCases.filter(t.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Doar Claude, modelele AI, Homebrew sau un editor nu fac pe cineva dezvoltator.
    static func guess() -> Bool { Tech.allCases.contains { $0.detect() } }

    static func answer(developer: Bool) {
        let changed = developer != devMode
        let d = UserDefaults.standard
        d.set(developer, forKey: devModeKey)
        d.set(true, forKey: askedKey)
        if changed { NotificationCenter.default.post(name: .profileChanged, object: nil) }
    }

    static func setHidden(_ t: Tech, _ hide: Bool) {
        var h = hidden
        if hide { h.insert(t) } else { h.remove(t) }
        UserDefaults.standard.set(encode(h), forKey: hiddenKey)
        NotificationCenter.default.post(name: .profileChanged, object: nil)
    }

    /// Versiunea veche alegea tehnologiile manual: lista aceea nu mai are sens.
    /// Până la răspuns, valoarea ghicită se salvează, ca `@AppStorage` să vadă același lucru ca scanarea.
    static func migrate() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "profileTechs")
        if d.object(forKey: devModeKey) == nil { d.set(guess(), forKey: devModeKey) }
    }
}

extension Notification.Name {
    /// Profilul s-a schimbat: recomandările trebuie rescanate.
    static let profileChanged = Notification.Name("profileChanged")
}
