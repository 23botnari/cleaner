import Foundation
import CryptoKit

extension Targets {
    static let brewCLI: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// „…would free approximately 222MB of disk space.” → bytes.
    static func parseBrewFree(_ out: String) -> Int64 {
        guard let r = out.range(of: "approximately ") else { return 0 }
        return parseDockerSize(String(out[r.upperBound...]))
    }

    static func homebrewTargets() -> [CleanTarget] {
        guard let brew = brewCLI else { return [] }
        let r = Shell.run(brew, ["cleanup", "-n", "-s", "--prune=all"], timeout: 120)
        return [CleanTarget(
            id: "brew", tech: .tools, group: "Dezvoltare", name: tr("Homebrew: versiuni vechi și descărcări"),
            desc: tr("Rulează „brew cleanup -s --prune=all”: șterge versiunile vechi ale pachetelor și kit-urile descărcate. Versiunile curente rămân."),
            cmds: [[brew, "cleanup", "-s", "--prune=all"]],
            fixedSize: parseBrewFree(r.out + r.err))]
    }

    static let goCLI: String? = ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let jetBrainsProcs = ["IntelliJ IDEA.app/Contents/MacOS", "WebStorm.app/Contents/MacOS", "PyCharm.app/Contents/MacOS",
                                 "GoLand.app/Contents/MacOS", "RustRover.app/Contents/MacOS", "CLion.app/Contents/MacOS",
                                 "PhpStorm.app/Contents/MacOS", "Rider.app/Contents/MacOS", "DataGrip.app/Contents/MacOS",
                                 "RubyMine.app/Contents/MacOS", "Fleet.app/Contents/MacOS", "Android Studio.app/Contents/MacOS"]

    static func devCacheTargets() -> [CleanTarget] {
        let g = "Dezvoltare"
        let C = Paths.hp("Library", "Caches")
        let tmp = Paths.realTmp
        var L: [CleanTarget] = []
        if let go = goCLI {
            // Modulele Go sunt read-only: le șterge doar `go clean`, nu rm.
            L.append(CleanTarget(id: "gomod", tech: .go, group: g, name: tr("Go: module descărcate"),
                                 desc: tr("Rulează „go clean -modcache”. Modulele se redescarcă la următorul go build."),
                                 cmds: [[go, "clean", "-modcache"]],
                                 sizePaths: [Paths.hp("go", "pkg", "mod")]))
        }
        return L + [
            CleanTarget(id: "cargo", tech: .rust, group: g, name: tr("Rust: cache Cargo"),
                        desc: tr("Crate-uri descărcate și surse dezarhivate. Se redescarcă la următorul cargo build. Indexul registrului rămâne."),
                        procs: ["=cargo"], appName: "cargo",
                        resolve: { Paths.existing([Paths.hp(".cargo", "registry", "cache"), Paths.hp(".cargo", "registry", "src"),
                                                   Paths.hp(".cargo", "git", "checkouts")]) }),
            CleanTarget(id: "gobuild", tech: .go, group: g, name: tr("Go: cache de build"),
                        desc: tr("Rezultate de compilare refolosite. Se refac la următorul go build."),
                        resolve: { Paths.existing([Paths.join(C, "go-build")]) }),
            CleanTarget(id: "maven", tech: .java, group: g, name: tr("Maven: depozit local (~/.m2)"),
                        desc: tr("Dependențe Java descărcate. Se redescarcă la următorul build. Pachetele publicate doar local (mvn install) trebuie reconstruite."),
                        risk: .care, procs: ["org.codehaus.plexus.classworlds"], appName: "Maven",
                        resolve: { Paths.existing([Paths.hp(".m2", "repository")]) }),
            CleanTarget(id: "jetbrains", tech: .tools, group: g, name: tr("JetBrains / Android Studio: cache și log-uri"),
                        desc: tr("Indexuri și log-uri ale IDE-urilor. Setările, pluginurile și proiectele rămân; la prima deschidere IDE-ul reindexează."),
                        procs: jetBrainsProcs, appName: tr("IDE-urile JetBrains / Android Studio"),
                        resolve: {
                            Paths.children(Paths.join(C, "JetBrains")) + Paths.children(Paths.hp("Library", "Logs", "JetBrains"))
                                + (Paths.children(Paths.join(C, "Google")) + Paths.children(Paths.hp("Library", "Logs", "Google")))
                                    .filter { ($0 as NSString).lastPathComponent.hasPrefix("AndroidStudio") }
                        }),
            CleanTarget(id: "yarn", tech: .js, group: g, name: tr("Yarn: cache"),
                        desc: tr("Pachete descărcate de Yarn. Se redescarcă la următorul yarn install."),
                        resolve: { Paths.existing([Paths.join(C, "Yarn"), Paths.hp(".yarn", "berry", "cache")]) }),
            CleanTarget(id: "bun", tech: .js, group: g, name: tr("Bun: cache"),
                        desc: tr("Pachete descărcate de Bun. Se redescarcă la următorul bun install."),
                        resolve: { Paths.existing([Paths.hp(".bun", "install", "cache")]) }),
            CleanTarget(id: "cocoapods", tech: .apple, group: g, name: tr("CocoaPods: cache"),
                        desc: tr("Pod-uri descărcate. Se redescarcă la următorul pod install."),
                        resolve: { Paths.existing([Paths.join(C, "CocoaPods")]) }),
            CleanTarget(id: "pip", tech: .python, group: g, name: tr("Python: cache pip / uv"),
                        desc: tr("Pachete Python descărcate. Se redescarcă la următoarea instalare."),
                        resolve: { Paths.existing([Paths.join(C, "pip"), Paths.hp(".cache", "uv"), Paths.join(C, "uv")]) }),
            CleanTarget(id: "metro", tech: .js, group: g, name: tr("React Native / Expo: cache Metro"),
                        desc: tr("Cache-ul bundler-ului Metro din folderul temporar. Se reface la următorul start (echivalent cu --clear)."),
                        procs: ["expo start", "react-native start", "@expo/cli"], appName: tr("serverul Metro / Expo"),
                        resolve: { Paths.children(tmp).filter { p in
                            let n = (p as NSString).lastPathComponent
                            return n.hasPrefix("metro-") || n.hasPrefix("haste-map-") || n.hasPrefix("react-native-packager-cache-")
                        } }),
            CleanTarget(id: "testbrowsers", tech: .js, group: g, name: tr("Browsere de test (Playwright, Cypress, Puppeteer)"),
                        desc: tr("Browserele descărcate pentru teste automate. Se descarcă din nou la următoarea instalare sau rulare."),
                        resolve: { Paths.existing([Paths.join(C, "ms-playwright"), Paths.join(C, "Cypress"), Paths.hp(".cache", "puppeteer")]) }),
            CleanTarget(id: "nodetooling", tech: .js, group: g, name: tr("Node: cache Electron, node-gyp, TypeScript, Prisma"),
                        desc: tr("Binare și tipuri descărcate de uneltele Node. Se redescarcă la nevoie."),
                        resolve: { Paths.existing([Paths.join(C, "electron"), Paths.join(C, "electron-builder"), Paths.join(C, "node-gyp"),
                                                   Paths.join(C, "typescript"), Paths.hp(".cache", "prisma")]) }),
            CleanTarget(id: "deno", tech: .js, group: g, name: tr("Deno: cache"),
                        desc: tr("Module descărcate de Deno. Se redescarcă la următoarea rulare."),
                        resolve: { Paths.existing([Paths.join(C, "deno")]) }),
            CleanTarget(id: "composer", tech: .php, group: g, name: tr("PHP: cache Composer"),
                        desc: tr("Pachete PHP descărcate. Se redescarcă la următorul composer install."),
                        resolve: { Paths.existing([Paths.join(C, "composer"), Paths.hp(".composer", "cache")]) }),
            CleanTarget(id: "gems", tech: .ruby, group: g, name: tr("Ruby: cache gem-uri"),
                        desc: tr("Arhivele gem-urilor descărcate. Gem-urile instalate rămân."),
                        resolve: { Paths.existing(Paths.children(Paths.hp(".gem", "ruby")).map { Paths.join($0, "cache") }
                            + [Paths.hp(".bundle", "cache")]) }),
            CleanTarget(id: "nuget", tech: .dotnet, group: g, name: tr(".NET: pachete NuGet"),
                        desc: tr("Pachetele NuGet descărcate. Se redescarcă la următorul dotnet restore."),
                        risk: .care,
                        resolve: { Paths.existing([Paths.hp(".nuget", "packages")]) }),
            CleanTarget(id: "pubcache", tech: .flutter, group: g, name: tr("Flutter / Dart: pachete pub"),
                        desc: tr("Pachetele descărcate de pub. Se redescarcă la următorul flutter pub get; uneltele instalate cu „dart pub global activate” trebuie reactivate."),
                        risk: .care,
                        resolve: { Paths.existing([Paths.hp(".pub-cache")]) }),
            CleanTarget(id: "xcodecache", tech: .apple, group: g, name: tr("Xcode: cache și Previews"),
                        desc: tr("Cache-ul Xcode și simulatoarele folosite de SwiftUI Previews. Se refac automat."),
                        procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
                        resolve: { Paths.existing([Paths.join(C, "com.apple.dt.Xcode"),
                                                   Paths.hp("Library", "Developer", "Xcode", "UserData", "Previews")]) }),
            CleanTarget(id: "cursor", tech: .tools, group: g, name: tr("Cursor: cache"),
                        desc: tr("Cache-uri și log-uri. Setările, extensiile și proiectele nu sunt atinse."),
                        procs: ["Cursor.app/Contents/MacOS"], appName: "Cursor",
                        resolve: { Paths.existing(["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                            .map { Paths.hp("Library", "Application Support", "Cursor", $0) }) }),
            CleanTarget(id: "windsurf", tech: .tools, group: g, name: tr("Windsurf: cache"),
                        desc: tr("Cache-uri și log-uri. Setările, extensiile și proiectele nu sunt atinse."),
                        procs: ["Windsurf.app/Contents/MacOS"], appName: "Windsurf",
                        resolve: { Paths.existing(["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                            .map { Paths.hp("Library", "Application Support", "Windsurf", $0) }) }),
            CleanTarget(id: "zed", tech: .tools, group: g, name: tr("Zed: cache"),
                        desc: tr("Cache-ul editorului Zed. Setările și extensiile rămân."),
                        procs: ["Zed.app/Contents/MacOS"], appName: "Zed",
                        resolve: { Paths.existing([Paths.join(C, "dev.zed.Zed"), Paths.join(C, "Zed")]) }),
            CleanTarget(id: "pyextra", tech: .python, group: g, name: tr("Python: cache Poetry / Pipenv"),
                        desc: tr("Pachete descărcate de Poetry și Pipenv. Se redescarcă la următoarea instalare. Mediile virtuale rămân."),
                        resolve: { Paths.existing([Paths.join(C, "pypoetry", "cache"), Paths.join(C, "pypoetry", "artifacts"), Paths.join(C, "pipenv")]) }),
            CleanTarget(id: "condapkgs", tech: .python, group: g, name: tr("Conda: pachete descărcate"),
                        desc: tr("Arhivele și pachetele dezarhivate din care conda creează medii (echivalent cu „conda clean --all”). Mediile existente rămân, dar unele pot depinde de ele dacă ai activat legăturile simbolice."),
                        risk: .care,
                        resolve: { Paths.existing(["miniconda3", "anaconda3", "miniforge3", "mambaforge", ".conda"].map { Paths.hp($0, "pkgs") }) }),
            CleanTarget(id: "ccache", tech: .cpp, group: g, name: tr("C / C++: ccache"),
                        desc: tr("Rezultate de compilare refolosite de ccache. Se refac la următoarele build-uri (primul va fi mai lent)."),
                        resolve: { Paths.existing([Paths.join(C, "ccache"), Paths.hp(".ccache"), Paths.hp(".cache", "ccache")]) }),
            CleanTarget(id: "vcpkg", tech: .cpp, group: g, name: tr("C / C++: cache vcpkg"),
                        desc: tr("Pachete binare compilate de vcpkg. Se recompilează la următoarea instalare."),
                        resolve: { Paths.existing([Paths.hp(".cache", "vcpkg", "archives"), Paths.join(C, "vcpkg")]) }),
            CleanTarget(id: "conan", tech: .cpp, group: g, name: tr("C / C++: pachete Conan"),
                        desc: tr("Pachetele descărcate și compilate de Conan. Se refac la următorul conan install; pachetele create doar local (conan create) trebuie refăcute."),
                        risk: .care,
                        resolve: { Paths.existing([Paths.hp(".conan2", "p"), Paths.hp(".conan", "data")]) }),
            CleanTarget(id: "sccache", tech: .rust, group: g, name: tr("Rust: sccache"),
                        desc: tr("Rezultate de compilare refolosite de sccache. Se refac la următoarele build-uri."),
                        procs: ["=sccache"], appName: "sccache",
                        resolve: { Paths.existing([Paths.join(C, "Mozilla.sccache")]) }),
            CleanTarget(id: "swiftpm", tech: .apple, group: g, name: tr("Swift Package Manager: cache"),
                        desc: tr("Pachete Swift descărcate. Se redescarcă la următoarea rezolvare a dependențelor."),
                        resolve: { Paths.existing([Paths.join(C, "org.swift.swiftpm"), Paths.hp("Library", "org.swift.swiftpm", "repositories")]) }),
            CleanTarget(id: "jvmextra", tech: .java, group: g, name: tr("Scala / sbt: cache Ivy și Coursier"),
                        desc: tr("Dependențe JVM descărcate de sbt, Mill și Coursier. Se redescarcă la următorul build."),
                        resolve: { Paths.existing([Paths.hp(".ivy2", "cache"), Paths.join(C, "Coursier"), Paths.hp(".cache", "coursier")]) }),
            CleanTarget(id: "konan", tech: .java, group: g, name: tr("Kotlin/Native: compilatoare și dependențe"),
                        desc: tr("Toolchain-uri Kotlin/Native descărcate. Se redescarcă la următorul build multiplatform."),
                        risk: .care,
                        resolve: { Paths.existing([Paths.hp(".konan", "dependencies"), Paths.hp(".konan", "cache")]
                            + Paths.children(Paths.hp(".konan")).filter { ($0 as NSString).lastPathComponent.hasPrefix("kotlin-native-prebuilt") }) }),
            CleanTarget(id: "hex", tech: .elixir, group: g, name: tr("Elixir / Erlang: cache Hex și rebar3"),
                        desc: tr("Pachete descărcate. Se redescarcă la următorul mix deps.get / rebar3 compile."),
                        resolve: { Paths.existing([Paths.hp(".hex", "packages"), Paths.hp(".cache", "rebar3")]) }),
            CleanTarget(id: "haskellcache", tech: .haskell, group: g, name: tr("Haskell: cache Cabal și GHCup"),
                        desc: tr("Pachete și instalatoare descărcate. Se redescarcă la nevoie. Compilatoarele instalate rămân."),
                        resolve: { Paths.existing([Paths.hp(".cabal", "packages"), Paths.hp(".ghcup", "cache"), Paths.hp(".ghcup", "tmp")]) }),
            CleanTarget(id: "stacksnap", tech: .haskell, group: g, name: tr("Haskell: snapshot-uri Stack"),
                        desc: tr("Pachetele compilate pentru fiecare snapshot Stackage. Se recompilează la următorul stack build (durează)."),
                        risk: .care,
                        resolve: { Paths.existing([Paths.hp(".stack", "snapshots")]) }),
            CleanTarget(id: "othercaches", tech: .other, group: g, name: tr("Zig, Julia, OCaml: cache-uri"),
                        desc: tr("Compilări și descărcări refolosite. Se refac la următoarea rulare."),
                        resolve: { Paths.existing([Paths.hp(".cache", "zig"), Paths.join(C, "zig"), Paths.hp(".julia", "compiled"),
                                                   Paths.hp(".opam", "download-cache")]) }),
            CleanTarget(id: "renvcache", tech: .other, group: g, name: tr("R: cache renv"),
                        desc: tr("Pachete R partajate între proiectele renv. Se reinstalează cu renv::restore()."),
                        risk: .care,
                        resolve: { Paths.existing([Paths.join(C, "org.R-project.R", "R", "renv")]) }),
            CleanTarget(id: "unity", tech: .gamedev, group: g, name: tr("Unity: cache de pachete"),
                        desc: tr("Pachetele descărcate de Unity Package Manager. Se redescarcă la deschiderea proiectelor."),
                        procs: ["Unity.app/Contents/MacOS", "Unity Hub.app/Contents/MacOS"], appName: "Unity",
                        resolve: { Paths.existing([Paths.hp("Library", "Unity", "cache"), Paths.join(C, "com.unity3d.UnityEditor")]) }),
            CleanTarget(id: "unreal", tech: .gamedev, group: g, name: tr("Unreal: Derived Data Cache comun"),
                        desc: tr("Date compilate partajate de proiectele Unreal. Se refac la deschidere (poate dura)."),
                        procs: ["UnrealEditor"], appName: "Unreal Editor",
                        resolve: { Paths.existing([Paths.hp("Library", "Application Support", "Epic", "UnrealEngine", "Common", "DerivedDataCache")]) }),
            CleanTarget(id: "godot", tech: .gamedev, group: g, name: tr("Godot: cache"),
                        desc: tr("Cache-ul editorului Godot. Se reface la următoarea deschidere."),
                        procs: ["Godot.app/Contents/MacOS"], appName: "Godot",
                        resolve: { Paths.existing([Paths.join(C, "Godot")]) }),
            CleanTarget(id: "terraform", tech: .infra, group: g, name: tr("Terraform: cache de provideri"),
                        desc: tr("Providerii descărcați în cache-ul comun. Se redescarcă la următorul terraform init."),
                        resolve: { Paths.existing([Paths.hp(".terraform.d", "plugin-cache")]) }),
            CleanTarget(id: "bazelisk", tech: .infra, group: g, name: tr("Bazel: versiuni descărcate de Bazelisk"),
                        desc: tr("Binarele Bazel descărcate. Se redescarcă la nevoie."),
                        resolve: { Paths.existing([Paths.join(C, "bazelisk"), Paths.hp(".cache", "bazelisk")]) }),
            CleanTarget(id: "minikube", tech: .infra, group: g, name: tr("minikube: imagini descărcate"),
                        desc: tr("Imagini și binare descărcate de minikube. Clusterele existente rămân."),
                        resolve: { Paths.existing([Paths.hp(".minikube", "cache")]) }),
            CleanTarget(id: "vagrant", tech: .infra, group: g, name: tr("Vagrant: box-uri"),
                        desc: tr("Imaginile de bază ale mașinilor virtuale. Se descarcă din nou la următorul vagrant up; mașinile create din ele rămân."),
                        risk: .care,
                        resolve: { Paths.children(Paths.hp(".vagrant.d", "boxes")) }),
        ]
    }

    // MARK: - Versiuni vechi ale uneltelor

    /// Versiunile instalate dintr-un manager (nvm, pyenv, rustup…): păstrez implicita și cea mai nouă, restul se pot șterge.
    private static func versions(id: String, tech: Tech, tool: String, root: String, keep: Set<String> = [],
                                 keepNewest: Bool = true, regen: String) -> [CleanTarget] {
        let dirs = Paths.children(root).filter { Paths.isDir($0) && !Paths.isSymlink($0) && !($0 as NSString).lastPathComponent.hasPrefix(".") }
        guard dirs.count > 1 else { return [] }
        func name(_ p: String) -> String { (p as NSString).lastPathComponent }
        var kept = Set(dirs.filter { keep.contains(name($0)) || keep.contains(Paths.realpath($0)) })
        if keepNewest, let newest = dirs.max(by: { version(name($0)).compare(version(name($1)), options: .numeric) == .orderedAscending }) {
            kept.insert(newest)
        }
        guard !kept.isEmpty else { return [] }
        return dirs.filter { !kept.contains($0) }.sorted().map { d in
            CleanTarget(
                id: "ver:\(id):" + d, tech: tech, group: "Versiuni de unelte", name: "\(tool) \(name(d))",
                desc: tr("Versiune mai veche, care nu e cea implicită. Proiectele care o cer explicit nu mai pornesc până o reinstalezi. \(regen)"),
                risk: .care,
                resolve: { Paths.existing([d]) })
        }
    }

    private static func version(_ s: String) -> String { s.hasPrefix("v") ? String(s.dropFirst()) : s }

    private static func firstLine(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func toolVersionTargets() -> [CleanTarget] {
        var L: [CleanTarget] = []
        // nvm: alias implicit „20”, „v20.11.0” sau „lts/*”.
        let nvmRoot = Paths.hp(".nvm", "versions", "node")
        if let alias = firstLine(Paths.hp(".nvm", "alias", "default")) {
            let a = version(alias)
            let keep = Set(Paths.children(nvmRoot).map { ($0 as NSString).lastPathComponent }
                .filter { let v = version($0); return v == a || v.hasPrefix(a + ".") })
            L += versions(id: "nvm", tech: .js, tool: "Node (nvm)", root: nvmRoot, keep: keep, regen: tr("Se reinstalează cu nvm install."))
        } else {
            L += versions(id: "nvm", tech: .js, tool: "Node (nvm)", root: nvmRoot, regen: tr("Se reinstalează cu nvm install."))
        }
        for base in [Paths.hp(".local", "share", "fnm"), Paths.hp("Library", "Application Support", "fnm"), Paths.hp(".fnm")] {
            let def = Paths.realpath(Paths.join(base, "aliases", "default"))
            let keep = Set(Paths.children(Paths.join(base, "node-versions")).filter { def.hasPrefix(Paths.realpath($0) + "/") || def == Paths.realpath($0) })
            L += versions(id: "fnm", tech: .js, tool: "Node (fnm)", root: Paths.join(base, "node-versions"), keep: keep,
                          regen: tr("Se reinstalează cu fnm install."))
        }
        var voltaKeep: Set<String> = []
        if let data = FileManager.default.contents(atPath: Paths.hp(".volta", "tools", "user", "platform.json")),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let node = o["node"] as? [String: Any], let rt = node["runtime"] as? String {
            voltaKeep.insert(rt)
        }
        L += versions(id: "volta", tech: .js, tool: "Node (Volta)", root: Paths.hp(".volta", "tools", "image", "node"), keep: voltaKeep,
                      regen: tr("Se reinstalează cu volta install."))
        L += versions(id: "pyenv", tech: .python, tool: "Python (pyenv)", root: Paths.hp(".pyenv", "versions"),
                      keep: Set([firstLine(Paths.hp(".pyenv", "version"))].compactMap { $0 }), regen: tr("Se reinstalează cu pyenv install."))
        L += versions(id: "rbenv", tech: .ruby, tool: "Ruby (rbenv)", root: Paths.hp(".rbenv", "versions"),
                      keep: Set([firstLine(Paths.hp(".rbenv", "version"))].compactMap { $0 }), regen: tr("Se reinstalează cu rbenv install."))
        // rustup: implicitul din settings.toml și toate canalele „stable-…” rămân; nightly / versiuni fixe vechi se pot șterge.
        let rustRoot = Paths.hp(".rustup", "toolchains")
        let settings = (try? String(contentsOfFile: Paths.hp(".rustup", "settings.toml"), encoding: .utf8)) ?? ""
        let def = settings.split(separator: "\n").first { $0.hasPrefix("default_toolchain") }?
            .split(separator: "\"").dropFirst().first.map(String.init)
        let rustKeep = Set(Paths.children(rustRoot).map { ($0 as NSString).lastPathComponent }
            .filter { n in n.hasPrefix("stable-") || (def.map { d in n == d || n.hasPrefix(d + "-") } ?? false) })
        L += versions(id: "rustup", tech: .rust, tool: "Rust", root: rustRoot, keep: rustKeep, keepNewest: false,
                      regen: tr("Se reinstalează cu rustup toolchain install."))
        for cand in Paths.children(Paths.hp(".sdkman", "candidates")) where Paths.isDir(cand) {
            let cur = Paths.realpath(Paths.join(cand, "current"))
            L += versions(id: "sdkman", tech: .java, tool: "\((cand as NSString).lastPathComponent) (SDKMAN)", root: cand, keep: [cur],
                          regen: tr("Se reinstalează cu sdk install."))
        }
        L += versions(id: "ndk", tech: .android, tool: "Android NDK", root: Paths.hp("Library", "Android", "sdk", "ndk"),
                      regen: tr("Se reinstalează din Android Studio → SDK Manager."))
        return L
    }

    static func aiModelTargets() -> [CleanTarget] {
        let g = "Modele AI locale"
        var L: [CleanTarget] = []
        // Ollama împarte blob-urile între modele: doar tot folderul se poate șterge sigur din afară.
        L.append(CleanTarget(
            id: "ollama", tech: .ai, group: g, name: tr("Ollama: toate modelele"),
            desc: tr("Modelele descărcate cu ollama pull. Se descarcă din nou la nevoie (adesea câțiva GB fiecare)."),
            risk: .care, procs: ["=ollama", "Ollama.app/Contents/MacOS"], appName: tr("Ollama (inclusiv din bara de meniu)"),
            resolve: { Paths.existing([Paths.hp(".ollama", "models")]) }))
        // LM Studio: models/<editor>/<model>.
        for root in [Paths.hp(".lmstudio", "models"), Paths.hp(".cache", "lm-studio", "models")] {
            for pub in Paths.children(root) where Paths.isDir(pub) {
                for model in Paths.children(pub) where Paths.isDir(model) {
                    L.append(CleanTarget(
                        id: "lmstudio:" + model, tech: .ai, group: g, name: tr("LM Studio: \(Paths.relative(model, to: root))"),
                        desc: tr("Model descărcat în LM Studio. Se descarcă din nou din tab-ul Discover."),
                        risk: .care, procs: ["LM Studio.app/Contents/MacOS"], appName: "LM Studio",
                        resolve: { Paths.existing([model]) }))
                }
            }
        }
        // Hugging Face: hub/models--<org>--<nume>, hub/datasets--…
        let hf = ProcessInfo.processInfo.environment["HF_HOME"].map { Paths.join($0, "hub") } ?? Paths.hp(".cache", "huggingface", "hub")
        for d in Paths.children(hf) where Paths.isDir(d) {
            let n = (d as NSString).lastPathComponent
            guard let kind = ["models--": tr("Model"), "datasets--": tr("Set de date"), "spaces--": tr("Space")]
                .first(where: { n.hasPrefix($0.key) }) else { continue }
            let name = n.dropFirst(kind.key.count).replacingOccurrences(of: "--", with: "/")
            L.append(CleanTarget(
                id: "hf:" + d, tech: .ai, group: g, name: tr("Hugging Face: \(name)"),
                desc: tr("\(kind.value) din cache-ul Hugging Face. Se descarcă din nou la prima folosire."),
                risk: .care,
                resolve: { Paths.existing([d]) }))
        }
        return L
    }

    static func iosDeviceTargets() -> [CleanTarget] {
        let g = "iPhone / iPad"
        var L: [CleanTarget] = []
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        for b in Paths.children(Paths.hp("Library", "Application Support", "MobileSync", "Backup")) where Paths.isDir(b) {
            let info = NSDictionary(contentsOfFile: Paths.join(b, "Info.plist"))
            let device = info?["Device Name"] as? String ?? tr("dispozitiv necunoscut")
            let date = (info?["Last Backup Date"] as? Date).map { df.string(from: $0) } ?? "?"
            L.append(CleanTarget(
                id: "iosbackup:" + b, group: g, name: tr("Backup \(device) (\(date))"),
                desc: tr("Backup local făcut din Finder. Șterge-l doar dacă ai backup în iCloud sau unul mai nou; altfel datele din el se pierd."),
                risk: .care, procs: ["AMPDeviceDiscoveryAgent", "AMPDevicesAgent"], appName: tr("sincronizarea iPhone (deconectează telefonul)"),
                resolve: { Paths.existing([b]) }))
        }
        L.append(CleanTarget(
            id: "ipsw", group: g, name: tr("Firmware iOS descărcat (.ipsw)"),
            desc: tr("Imagini de sistem pentru restaurarea iPhone / iPad. Se descarcă din nou la nevoie."),
            resolve: {
                let dirs = ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"].map { Paths.hp("Library", "iTunes", $0) }
                return (dirs + [Paths.hp("Downloads")]).flatMap(Paths.children).filter { $0.lowercased().hasSuffix(".ipsw") }
            }))
        return L
    }

    /// Fișiere din ~/Downloads (primul nivel) cu extensia dată, adăugate acum mai mult de `days` zile.
    static func oldDownloads(_ exts: Set<String>, days: Double) -> [String] {
        let cutoff = Date().addingTimeInterval(-days * 24 * 3600)
        return Paths.children(Paths.hp("Downloads")).filter { p in
            guard exts.contains((p as NSString).pathExtension.lowercased()), !Paths.isSymlink(p) else { return false }
            let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            guard let d = v?.addedToDirectoryDate ?? v?.creationDate else { return false }
            return d < cutoff
        }
    }

    static func downloadsTargets() -> [CleanTarget] {
        let g = "Descărcări"
        return [
            CleanTarget(id: "dl-installers", group: g, name: tr("Kit-uri de instalare mai vechi de 5 zile"),
                        desc: tr("Fișiere .dmg, .pkg și .xip din Descărcări. Aplicațiile instalate nu sunt atinse. Se mută la Coș."),
                        trash: true,
                        resolve: { oldDownloads(["dmg", "pkg", "mpkg", "xip"], days: 5) }),
            CleanTarget(id: "dl-archives", group: g, name: tr("Arhive mai vechi de 5 zile"),
                        desc: tr("Fișiere .zip, .rar, .7z, .tar.gz din Descărcări. Verifică să le fi dezarhivat dacă ai nevoie de conținut. Se mută la Coș."),
                        risk: .care, trash: true,
                        resolve: { oldDownloads(["zip", "rar", "7z", "tgz", "gz", "bz2", "xz"], days: 5) }),
        ]
    }

    static func timeMachineTargets() -> [CleanTarget] {
        let r = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30)
        let snaps = r.out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }
        guard !snaps.isEmpty else { return [] }
        // Mărimea exactă nu se poate citi fără root; spațiul „purgeable” al volumului e cea mai bună estimare.
        let v = try? URL(fileURLWithPath: Paths.home).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let purgeable = (v?.volumeAvailableCapacityForImportantUsage ?? 0) - Int64(v?.volumeAvailableCapacity ?? 0)
        let cmd = "/usr/bin/tmutil deletelocalsnapshots /"
        return [CleanTarget(
            id: "tmsnap", group: "Sistem și altele", name: tr("Time Machine: \(snaps.count) snapshot-uri locale"),
            desc: tr("Copii locale păstrate de Time Machine până la următorul backup pe disc. Backup-urile de pe discul extern nu sunt atinse. Mărimea e estimată (spațiu „purgeable”). Cere parola de administrator."),
            risk: .care,
            cmds: [["/usr/bin/osascript", "-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                    "-e", "end run", cmd]],
            fixedSize: max(purgeable, 1))]
    }

    static func browserTargets() -> [CleanTarget] {
        let AS = Paths.hp("Library", "Application Support")
        let C = Paths.hp("Library", "Caches")
        let chromium: [(id: String, name: String, proc: String, support: String, caches: [String])] = [
            ("brave", "Brave", "Brave Browser.app/Contents/MacOS", "BraveSoftware/Brave-Browser", ["BraveSoftware/Brave-Browser"]),
            ("chrome", "Chrome", "Google Chrome.app/Contents/MacOS", "Google/Chrome", ["Google/Chrome"]),
            ("edge", "Edge", "Microsoft Edge.app/Contents/MacOS", "Microsoft Edge", ["Microsoft Edge"]),
        ]
        let perProfile = ["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                          "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
        var L: [CleanTarget] = chromium.map { b in
            CleanTarget(
                id: "browser-" + b.id, group: "Browsere", name: tr("\(b.name): cache"),
                desc: tr("Imagini și fișiere ale site-urilor, păstrate ca paginile să se încarce mai repede. Istoricul, parolele, tab-urile și login-urile rămân."),
                procs: [b.proc], appName: b.name,
                resolve: {
                    let profiles = Paths.children(Paths.join(AS, b.support)).filter { p in
                        let n = (p as NSString).lastPathComponent
                        return n == "Default" || n.hasPrefix("Profile ") || n == "Guest Profile"
                    }
                    return Paths.existing(b.caches.map { Paths.join(C, $0) }
                        + profiles.flatMap { p in perProfile.map { Paths.join(p, $0) } })
                })
        }
        L.append(CleanTarget(
            id: "browser-firefox", group: "Browsere", name: tr("Firefox: cache"),
            desc: tr("Cache-ul paginilor. Istoricul, parolele și login-urile rămân."),
            procs: ["firefox"], appName: "Firefox",
            resolve: { Paths.existing([Paths.join(C, "Firefox", "Profiles")]) }))
        L.append(CleanTarget(
            id: "browser-safari", group: "Browsere", name: tr("Safari: cache"),
            desc: tr("Cache-ul paginilor (necesită Full Disk Access). Istoricul și login-urile rămân."),
            procs: ["Safari.app/Contents/MacOS"], appName: "Safari",
            resolve: { Paths.existing([Paths.join(C, "com.apple.Safari"), Paths.join(C, "com.apple.WebKit.Networking")]) }))
        return L
    }

    /// Fișiere identice (≥ 1 MB) în Descărcări, Desktop și Documente. Păstrează cea mai veche copie, restul la Coș.
    static func duplicateTargets() -> [CleanTarget] {
        let fm = FileManager.default
        var bySize: [Int64: [String]] = [:]
        let skipDirs: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", "build", ".build"]

        func walk(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") && !skipDirs.contains(n) {
                let p = Paths.join(dir, n)
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                // Fișierele din iCloud nedescărcate (dataless) nu se citesc: ar porni descărcarea.
                if st.st_flags & 0x4000_0000 != 0 { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    // Pachetele (.app, .photoslibrary…) au extensie: nu intrăm în ele.
                    if depth < 6, (n as NSString).pathExtension.isEmpty { walk(p, depth: depth + 1) }
                case S_IFREG where st.st_size >= 1_000_000:
                    bySize[Int64(st.st_size), default: []].append(p)
                default: break
                }
            }
        }
        for root in ["Downloads", "Desktop", "Documents"] { walk(Paths.hp(root), depth: 0) }

        func hash(_ p: String, limit: Int?) -> String? {
            guard let h = FileHandle(forReadingAtPath: p) else { return nil }
            defer { try? h.close() }
            var sha = SHA256()
            var read = 0
            while true {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                sha.update(data: chunk)
                read += chunk.count
                if let limit, read >= limit { break }
            }
            return sha.finalize().map { String(format: "%02x", $0) }.joined()
        }

        var groups: [(size: Int64, files: [String])] = []
        for (size, files) in bySize where files.count > 1 {
            // Întâi primul MB, apoi tot fișierul doar pentru cele care încă se potrivesc.
            let quick = Dictionary(grouping: files) { hash($0, limit: 1 << 20) ?? UUID().uuidString }
            for cand in quick.values where cand.count > 1 {
                let full = Dictionary(grouping: cand) { hash($0, limit: nil) ?? UUID().uuidString }
                for same in full.values where same.count > 1 { groups.append((size, same)) }
            }
        }
        func created(_ p: String) -> Date {
            (try? fm.attributesOfItem(atPath: p)[.creationDate] as? Date) ?? .distantFuture
        }
        return groups.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }.prefix(200).map { g in
            let sorted = g.files.sorted { created($0) < created($1) }
            let keep = sorted[0], extra = Array(sorted.dropFirst())
            return CleanTarget(
                id: "dup:" + keep, group: "Fișiere duplicate",
                name: extra.count == 1 ? tr("„\((keep as NSString).lastPathComponent)” — 1 copie") : tr("„\((keep as NSString).lastPathComponent)” — \(extra.count) copii"),
                desc: tr("Păstrez originalul (cel mai vechi): \(Paths.relative(keep)). La Coș: ") + extra.map { Paths.relative($0) }.joined(separator: ", "),
                risk: .care, trash: true,
                resolve: { Paths.existing(extra) })
        }
    }
}
