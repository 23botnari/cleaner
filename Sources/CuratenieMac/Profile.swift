import Foundation

/// Tehnologiile de dezvoltare după care se filtrează scanarea: ce nu folosești nu se caută și nu apare.
enum Tech: String, CaseIterable, Identifiable, Sendable {
    case js, apple, android, flutter, rust, go, java, python, php, ruby, dotnet, docker, tools, ai, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .js: "JavaScript / Node"
        case .apple: "Xcode / iOS"
        case .android: "Android"
        case .flutter: "Flutter / Dart"
        case .rust: "Rust"
        case .go: "Go"
        case .java: "Java / Gradle"
        case .python: "Python"
        case .php: "PHP"
        case .ruby: "Ruby"
        case .dotnet: ".NET"
        case .docker: "Docker"
        case .tools: tr("Homebrew și editoare")
        case .ai: tr("Modele AI locale")
        case .claude: "Claude"
        }
    }

    var icon: String {
        switch self {
        case .js: "shippingbox"
        case .apple: "iphone"
        case .android: "candybarphone"
        case .flutter: "bird"
        case .rust: "gearshape.2"
        case .go: "hare"
        case .java: "cup.and.saucer"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .php: "server.rack"
        case .ruby: "diamond"
        case .dotnet: "number"
        case .docker: "cube.box"
        case .tools: "wrench.and.screwdriver"
        case .ai: "cpu"
        case .claude: "terminal"
        }
    }

    /// Urme pe disc că tehnologia e folosită pe acest Mac.
    func detect() -> Bool {
        func any(_ paths: [String]) -> Bool { !Paths.existing(paths).isEmpty }
        let C = Paths.hp("Library", "Caches")
        let AS = Paths.hp("Library", "Application Support")
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
            return any([Paths.hp(".m2"), Paths.hp(".gradle")])
        case .python:
            return any([Paths.join(C, "pip"), Paths.hp(".cache", "uv"), Paths.join(C, "uv"), Paths.hp(".pyenv"),
                        Paths.hp(".conda"), Paths.hp(".virtualenvs"), Paths.join(C, "pypoetry")])
        case .php:
            return any([Paths.hp(".composer"), Paths.join(C, "composer"), Paths.hp(".config", "composer")])
        case .ruby:
            return any([Paths.hp(".gem"), Paths.hp(".bundle"), Paths.hp(".rbenv"), Paths.hp(".rvm")])
        case .dotnet:
            return any([Paths.hp(".nuget"), Paths.hp(".dotnet")])
        case .docker:
            return Targets.dockerCLI != nil || any([Paths.hp(".docker")])
        case .tools:
            return Targets.brewCLI != nil || any([Paths.join(AS, "Code"), Paths.join(AS, "Cursor"), Paths.join(C, "JetBrains")])
        case .ai:
            return any([Paths.hp(".ollama"), Paths.hp(".lmstudio"), Paths.hp(".cache", "lm-studio"), Paths.hp(".cache", "huggingface")])
        case .claude:
            return any([Paths.hp(".claude"), Paths.join(AS, "Claude")])
        }
    }
}

/// Profilul utilizatorului: dezvoltator sau nu, și cu ce tehnologii lucrează.
enum Profile {
    static let devModeKey = "profileDevMode"
    /// Valorile `Tech.rawValue`, separate prin virgulă (formă compatibilă cu `@AppStorage`).
    static let techsKey = "profileTechs"

    static var devMode: Bool { UserDefaults.standard.bool(forKey: devModeKey) }

    static var techs: Set<Tech> { decode(UserDefaults.standard.string(forKey: techsKey) ?? "") }

    /// Tehnologiile după care se scanează acum (nimic, dacă profilul de dezvoltator e oprit).
    static var active: Set<Tech> { devMode ? techs : [] }

    static func decode(_ s: String) -> Set<Tech> {
        Set(s.split(separator: ",").compactMap { Tech(rawValue: String($0)) })
    }

    static func encode(_ t: Set<Tech>) -> String {
        Tech.allCases.filter(t.contains).map(\.rawValue).joined(separator: ",")
    }

    static func detected() -> Set<Tech> { Set(Tech.allCases.filter { $0.detect() }) }

    /// Prima pornire: profilul se completează singur din ce e instalat; după aceea decide utilizatorul din Setări.
    static func detectOnce() {
        let d = UserDefaults.standard
        guard d.object(forKey: devModeKey) == nil else { return }
        let found = detected()
        d.set(encode(found), forKey: techsKey)
        // Doar Claude, modelele AI, Homebrew sau un editor nu fac pe cineva dezvoltator.
        d.set(!found.subtracting([.claude, .ai, .tools]).isEmpty, forKey: devModeKey)
    }
}

extension Notification.Name {
    /// Profilul s-a schimbat din Setări: recomandările trebuie rescanate.
    static let profileChanged = Notification.Name("profileChanged")
}
