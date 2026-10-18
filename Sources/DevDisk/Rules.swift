import Foundation

/// Which side of the treemap an item lands on.
enum Group: String, Codable {
    case safe     // regenerated or re-downloaded automatically
    case review   // "let me review first": sessions, models, Docker, anything with user data
}

/// Kinds map 1:1 to the categorical palette slots in the UI, in this fixed order.
enum Kind: String, Codable, CaseIterable {
    case javascript, python, apple, jvm, models, toolchains, sessions, docker
}

/// Single-quote a string for zsh/bash.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

let home = FileManager.default.homeDirectoryForCurrentUser.path

/// A fixed location under the home folder (caches, toolchains, models, sessions).
struct GlobalRule {
    let path: String            // relative to home
    let label: String
    let kind: Kind
    let group: Group
    let effect: String
    /// Tool's own clean command. nil = no such command; the user removes it themself.
    var command: String? = nil
    /// When set, each child folder becomes its own item and this builds its command from the child name.
    var perChild: ((String) -> (label: String, command: String?))? = nil
}

/// A folder found inside a project while walking the home folder.
struct ProjectRule {
    let names: Set<String>
    /// The parent folder must contain one of these (any). Empty = no check.
    var parentMarkers: [String] = []
    /// The folder itself must contain one of these (any).
    var innerMarkers: [String] = []
    let label: String
    let kind: Kind
    var group: Group = .safe
    let effect: String
    /// Builds the command from (folder path, project path). nil = Move to Trash.
    var command: ((String, String) -> String?)? = nil
}

enum Rules {
    static let globals: [GlobalRule] = [
        // JavaScript
        .init(path: ".npm/_cacache", label: "npm cache", kind: .javascript, group: .safe,
              effect: "npm's download cache. Packages re-download on the next install.",
              command: "npm cache clean --force"),
        .init(path: ".npm/_npx", label: "npx cache", kind: .javascript, group: .safe,
              effect: "Packages fetched by npx. Re-downloaded the next time you npx them."),
        .init(path: "Library/Caches/Yarn", label: "Yarn cache", kind: .javascript, group: .safe,
              effect: "Yarn's package cache. Re-downloaded on the next install.",
              command: "yarn cache clean"),
        .init(path: ".yarn/berry/cache", label: "Yarn Berry cache", kind: .javascript, group: .safe,
              effect: "Yarn 2+ global cache. Re-downloaded on the next install.",
              command: "yarn cache clean --all"),
        .init(path: "Library/pnpm/store", label: "pnpm store", kind: .javascript, group: .safe,
              effect: "pnpm removes packages no project references. Packages still in use stay.",
              command: "pnpm store prune"),
        .init(path: ".bun/install/cache", label: "Bun cache", kind: .javascript, group: .safe,
              effect: "Bun's package cache. Re-downloaded on the next install.",
              command: "bun pm cache rm"),
        .init(path: "Library/Caches/ms-playwright", label: "Playwright browsers", kind: .javascript, group: .safe,
              effect: "Test browsers removed. Run `npx playwright install` before the next test run.",
              command: "npx --yes playwright uninstall --all"),
        .init(path: ".cache/puppeteer", label: "Puppeteer browsers", kind: .javascript, group: .safe,
              effect: "Puppeteer's Chrome downloads. Fetched again on the next npm install."),
        .init(path: "Library/Caches/node-gyp", label: "node-gyp headers", kind: .javascript, group: .safe,
              effect: "Node headers for native addons. Re-downloaded on the next native build."),
        .init(path: "Library/Caches/deno", label: "Deno cache", kind: .javascript, group: .safe,
              effect: "Deno's module cache. Re-downloaded on the next run.",
              command: "deno clean"),
        .init(path: ".nvm/versions/node", label: "nvm Node versions", kind: .javascript, group: .review,
              effect: "This Node version is uninstalled. Projects pinned to it (.nvmrc) need `nvm install` again.",
              perChild: { v in ("Node \(v) (nvm)", ". \"$HOME/.nvm/nvm.sh\" && nvm uninstall \(shq(v))") }),

        // Python
        .init(path: "Library/Caches/pip", label: "pip cache", kind: .python, group: .safe,
              effect: "pip's wheel and download cache. Re-downloaded on the next install.",
              command: "python3 -m pip cache purge"),
        .init(path: ".cache/uv", label: "uv cache", kind: .python, group: .safe,
              effect: "uv's package cache. Re-downloaded on the next sync (uv is fast at this).",
              command: "uv cache clean"),
        .init(path: "Library/Caches/pypoetry", label: "Poetry cache", kind: .python, group: .safe,
              effect: "Poetry's PyPI cache. Re-downloaded on the next install.",
              command: "poetry cache clear PyPI --all -n"),
        .init(path: ".cache/pre-commit", label: "pre-commit envs", kind: .python, group: .safe,
              effect: "Hook environments. Rebuilt the next time a hook runs.",
              command: "pre-commit clean"),
        .init(path: ".wdm", label: "webdriver-manager drivers", kind: .python, group: .safe,
              effect: "Downloaded browser drivers. Fetched again the next time they're needed."),
        .init(path: "miniconda3/pkgs", label: "Miniconda package cache", kind: .python, group: .safe,
              effect: "Unused conda package tarballs and caches. Environments keep working.",
              command: "conda clean --all -y"),
        .init(path: "miniforge3/pkgs", label: "Miniforge package cache", kind: .python, group: .safe,
              effect: "Unused conda package tarballs and caches. Environments keep working.",
              command: "conda clean --all -y"),
        .init(path: "anaconda3/pkgs", label: "Anaconda package cache", kind: .python, group: .safe,
              effect: "Unused conda package tarballs and caches. Environments keep working.",
              command: "conda clean --all -y"),
        .init(path: ".pyenv/versions", label: "pyenv versions", kind: .python, group: .review,
              effect: "This Python and every package installed into it are removed. Virtualenvs built on it break.",
              perChild: { v in ("Python \(v) (pyenv)", "pyenv uninstall -f \(shq(v))") }),

        // Xcode & Swift
        .init(path: "Library/Developer/Xcode/DerivedData", label: "Xcode DerivedData", kind: .apple, group: .safe,
              effect: "Build products and indexes. Xcode rebuilds and re-indexes, so the first build is slower."),
        .init(path: "Library/Developer/Xcode/iOS DeviceSupport", label: "iOS DeviceSupport", kind: .apple, group: .safe,
              effect: "Debug symbols copied from your devices. Copied again the next time you connect a device, which takes a few minutes."),
        .init(path: "Library/Developer/Xcode/watchOS DeviceSupport", label: "watchOS DeviceSupport", kind: .apple, group: .safe,
              effect: "Debug symbols copied from your devices. Copied again the next time you connect a device."),
        .init(path: "Library/Developer/Xcode/UserData/Previews", label: "SwiftUI Preview simulators", kind: .apple, group: .safe,
              effect: "Preview simulator devices. Recreated the next time you open a preview.",
              command: "xcrun simctl --set previews delete all"),
        .init(path: "Library/Developer/CoreSimulator/Caches", label: "Simulator caches", kind: .apple, group: .safe,
              effect: "Simulator dyld caches. Regenerated the next time a simulator boots."),
        .init(path: "Library/Caches/com.apple.dt.Xcode", label: "Xcode cache", kind: .apple, group: .safe,
              effect: "Xcode's general cache. Rebuilt as needed."),
        .init(path: "Library/Caches/org.swift.swiftpm", label: "SwiftPM cache", kind: .apple, group: .safe,
              effect: "Cached package checkouts. Re-fetched on the next resolve.",
              command: "swift package purge-cache"),
        .init(path: "Library/Caches/CocoaPods", label: "CocoaPods cache", kind: .apple, group: .safe,
              effect: "Downloaded pods. Re-downloaded on the next `pod install`.",
              command: "pod cache clean --all"),
        .init(path: ".cocoapods/repos", label: "CocoaPods spec repos", kind: .apple, group: .safe,
              effect: "Spec repo clones. Re-fetched by `pod install --repo-update`."),
        .init(path: "Library/Developer/CoreSimulator/Devices", label: "iOS Simulators", kind: .apple, group: .review,
              effect: "Erases every app and its data in this simulator and resets it to factory state. The simulator stays in Xcode, ready to use. If it's running, it's shut down first.",
              command: nil),
        .init(path: "Library/Developer/Xcode/Archives", label: "Xcode Archives", kind: .apple, group: .review,
              effect: "Archived builds and their dSYMs. You can't symbolicate crash reports from those releases afterwards."),

        // Android, JVM & Flutter
        .init(path: ".gradle/caches", label: "Gradle caches", kind: .jvm, group: .safe,
              effect: "Dependency and build cache. Re-downloaded on the next build, which will be slow. Run `gradle --stop` first."),
        .init(path: ".gradle/wrapper/dists", label: "Gradle distributions", kind: .jvm, group: .safe,
              effect: "Gradle versions the wrapper downloaded. Re-downloaded by ./gradlew when needed."),
        .init(path: ".m2/repository", label: "Maven repository", kind: .jvm, group: .safe,
              effect: "Local Maven artifacts. Re-downloaded on the next build. Anything you `mvn install`ed locally is lost."),
        .init(path: ".pub-cache", label: "Dart/Flutter pub cache", kind: .jvm, group: .safe,
              effect: "Downloaded Dart packages. Run `flutter pub get` in each project afterwards.",
              command: "dart pub cache clean --force"),
        .init(path: ".android/cache", label: "Android cache", kind: .jvm, group: .safe,
              effect: "Android tools cache. Rebuilt as needed."),
        .init(path: ".android/avd", label: "Android emulators", kind: .jvm, group: .review,
              effect: "Emulator devices and everything installed on them. Remove individual devices in Android Studio's Device Manager."),
        .init(path: "Library/Android/sdk", label: "Android SDK", kind: .jvm, group: .review,
              effect: "The SDK itself. Android builds stop working. Prefer removing old platforms and system images in the SDK Manager."),

        // Toolchains & editors
        .init(path: "Library/Caches/Homebrew", label: "Homebrew cache", kind: .toolchains, group: .safe,
              effect: "Downloaded bottles and old versions. Installed formulae are untouched.",
              command: "brew cleanup --prune=all"),
        .init(path: ".cargo/registry", label: "Cargo registry", kind: .toolchains, group: .safe,
              effect: "Downloaded crates. Re-fetched on the next cargo build."),
        .init(path: ".cargo/git", label: "Cargo git checkouts", kind: .toolchains, group: .safe,
              effect: "Git dependencies. Re-fetched on the next cargo build."),
        .init(path: "Library/Caches/go-build", label: "Go build cache", kind: .toolchains, group: .safe,
              effect: "Compiled Go packages. Rebuilt on the next build.",
              command: "go clean -cache"),
        .init(path: "go/pkg/mod", label: "Go module cache", kind: .toolchains, group: .safe,
              effect: "Downloaded Go modules. Re-downloaded on the next build.",
              command: "go clean -modcache"),
        .init(path: ".gem", label: "RubyGems (user)", kind: .toolchains, group: .safe,
              effect: "Removes old versions of gems installed in ~/.gem. The newest version of each stays.",
              command: "gem cleanup --user-install"),
        .init(path: "Library/Caches/JetBrains", label: "JetBrains caches", kind: .toolchains, group: .safe,
              effect: "IDE indexes. Rebuilt the next time you open a project, which is slower."),
        .init(path: "Library/Application Support/Code/CachedData", label: "VS Code cached data", kind: .toolchains, group: .safe,
              effect: "Compiled-code cache. Rebuilt on the next launch."),
        .init(path: "Library/Application Support/Code/Cache", label: "VS Code cache", kind: .toolchains, group: .safe,
              effect: "Web cache. Rebuilt as needed."),
        .init(path: "Library/Application Support/Code/CachedExtensionVSIXs", label: "VS Code extension downloads", kind: .toolchains, group: .safe,
              effect: "Downloaded extension packages. Installed extensions stay."),
        .init(path: "Library/Application Support/Cursor/CachedData", label: "Cursor cached data", kind: .toolchains, group: .safe,
              effect: "Compiled-code cache. Rebuilt on the next launch."),
        .init(path: "Library/Application Support/Cursor/Cache", label: "Cursor cache", kind: .toolchains, group: .safe,
              effect: "Web cache. Rebuilt as needed."),
        .init(path: ".rustup/toolchains", label: "Rust toolchains", kind: .toolchains, group: .review,
              effect: "This Rust toolchain is uninstalled. Projects pinned to it need `rustup toolchain install` again.",
              perChild: { t in ("Rust \(t)", "rustup toolchain uninstall \(shq(t))") }),
        .init(path: ".vscode/extensions", label: "VS Code extensions", kind: .toolchains, group: .review,
              effect: "Installed extensions. Remove the ones you don't use from VS Code's Extensions view."),
        .init(path: ".cursor/extensions", label: "Cursor extensions", kind: .toolchains, group: .review,
              effect: "Installed extensions. Remove the ones you don't use from Cursor's Extensions view."),

        // AI models: always review
        .init(path: ".ollama/models", label: "Ollama models", kind: .models, group: .review,
              effect: "Local models are deleted. Use `ollama pull <name>` to get them back, which is often several GB each."),
        // Split per repo by the scanner; `hf cache rm` asks for confirmation before deleting.
        .init(path: ".cache/huggingface/hub", label: "Hugging Face", kind: .models, group: .review,
              effect: "This model is deleted from the Hugging Face cache. Code that uses it re-downloads it on first use."),
        .init(path: ".lmstudio/models", label: "LM Studio models", kind: .models, group: .review,
              effect: "Downloaded models. Delete individual models from LM Studio's My Models tab."),
        .init(path: ".cache/lm-studio/models", label: "LM Studio models (legacy)", kind: .models, group: .review,
              effect: "Downloaded models. Delete individual models from LM Studio's My Models tab."),
        .init(path: ".cache/torch", label: "PyTorch hub cache", kind: .models, group: .review,
              effect: "Pretrained weights from torch.hub and torchvision. Re-downloaded on first use."),
        .init(path: ".cache/whisper", label: "Whisper models", kind: .models, group: .review,
              effect: "Whisper speech models. Re-downloaded on first use."),
        .init(path: ".cache/llama.cpp", label: "llama.cpp models", kind: .models, group: .review,
              effect: "Models llama.cpp fetched with -hf. Re-downloaded on the next run."),
        .init(path: ".keras", label: "Keras models", kind: .models, group: .review,
              effect: "Pretrained Keras weights and datasets. Re-downloaded on first use."),

        // AI sessions: always review
        .init(path: ".claude/projects", label: "Claude Code sessions", kind: .sessions, group: .review,
              effect: "Conversation transcripts. You lose /resume history for those projects. Claude Code also prunes these on its own via `cleanupPeriodDays`."),
        .init(path: ".claude/file-history", label: "Claude Code file history", kind: .sessions, group: .review,
              effect: "File snapshots used to rewind edits. You can't rewind past sessions afterwards."),
        .init(path: ".codex/sessions", label: "Codex sessions", kind: .sessions, group: .review,
              effect: "Codex CLI session logs. You lose resume and history for them."),
        .init(path: ".gemini/tmp", label: "Gemini CLI sessions", kind: .sessions, group: .review,
              effect: "Gemini CLI chat logs and checkpoints. You lose saved chats and restore points."),
        .init(path: "Library/Application Support/Cursor/User/workspaceStorage", label: "Cursor workspace state", kind: .sessions, group: .review,
              effect: "Per-workspace state, including Cursor chat and composer history."),
        .init(path: "Library/Application Support/Code/User/workspaceStorage", label: "VS Code workspace state", kind: .sessions, group: .review,
              effect: "Per-workspace state, including Copilot chat history and editor state."),

        // Docker & VMs: always review
        .init(path: ".colima", label: "Colima VM", kind: .docker, group: .review,
              effect: "Deletes the Colima VM and every image, container and volume inside it.",
              command: "colima delete --force"),
        .init(path: ".lima", label: "Lima VMs", kind: .docker, group: .review,
              effect: "Lima virtual machines and their disks. Delete each one with `limactl delete <name>`."),
        .init(path: ".minikube", label: "minikube", kind: .docker, group: .review,
              effect: "Deletes all minikube clusters and cached images.",
              command: "minikube delete --all --purge"),
        .init(path: ".vagrant.d/boxes", label: "Vagrant boxes", kind: .docker, group: .review,
              effect: "Removes outdated box versions. Boxes in use stay.",
              command: "vagrant box prune"),
        .init(path: "VirtualBox VMs", label: "VirtualBox VMs", kind: .docker, group: .review,
              effect: "Virtual machine disks. Delete VMs from VirtualBox Manager so its registry stays consistent."),
    ]

    static let projectRules: [ProjectRule] = [
        .init(names: ["node_modules"], parentMarkers: ["package.json"], label: "node_modules", kind: .javascript,
              effect: "This project's dependencies. Run npm, yarn, pnpm or bun install to restore them before the project will run."),
        .init(names: [".next"], parentMarkers: ["package.json"], label: "Next.js build", kind: .javascript,
              effect: "Next.js build output and cache. Rebuilt on the next `next dev` or `next build`."),
        .init(names: [".nuxt", ".output"], parentMarkers: ["nuxt.config.ts", "nuxt.config.js"], label: "Nuxt build", kind: .javascript,
              effect: "Nuxt build output. Rebuilt on the next dev or build."),
        .init(names: [".svelte-kit"], parentMarkers: ["package.json"], label: "SvelteKit build", kind: .javascript,
              effect: "Generated SvelteKit files. Rebuilt on the next dev or build."),
        .init(names: [".turbo", ".parcel-cache", ".angular", ".expo"], parentMarkers: ["package.json"], label: "JS build cache", kind: .javascript,
              effect: "Build cache. Regenerated on the next build, which is slower the first time."),
        .init(names: ["target"], parentMarkers: ["Cargo.toml"], label: "Rust target/", kind: .toolchains,
              effect: "Rust build output. The next cargo build recompiles everything.",
              command: { _, p in "cargo clean --manifest-path \(shq(p + "/Cargo.toml"))" }),
        .init(names: ["target"], parentMarkers: ["pom.xml"], label: "Maven target/", kind: .jvm,
              effect: "Maven build output. Rebuilt on the next mvn package.",
              command: { _, p in "mvn -q -f \(shq(p + "/pom.xml")) clean" }),
        .init(names: ["build"], parentMarkers: ["pubspec.yaml"], label: "Flutter build/", kind: .jvm,
              effect: "Flutter build output. Rebuilt on the next flutter run or build.",
              command: { _, p in "(cd \(shq(p)) && flutter clean)" }),
        .init(names: [".dart_tool"], parentMarkers: ["pubspec.yaml"], label: "Dart tool cache", kind: .jvm,
              effect: "Dart tool state. Regenerated by flutter pub get.",
              command: { _, p in "(cd \(shq(p)) && flutter clean)" }),
        .init(names: ["build"], parentMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              label: "Gradle build/", kind: .jvm,
              effect: "Gradle build output. Rebuilt on the next build.",
              command: { _, p in
                  FileManager.default.fileExists(atPath: p + "/gradlew")
                      ? "\(shq(p + "/gradlew")) -p \(shq(p)) clean"
                      : "gradle -p \(shq(p)) clean"
              }),
        .init(names: [".gradle"], parentMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              label: "Gradle project cache", kind: .jvm,
              effect: "Gradle's per-project cache. Regenerated on the next build."),
        .init(names: [".build"], parentMarkers: ["Package.swift"], label: "SwiftPM .build/", kind: .apple,
              effect: "SwiftPM build output and checkouts. Rebuilt and re-resolved on the next swift build.",
              command: { _, p in "swift package --package-path \(shq(p)) reset" }),
        .init(names: ["Pods"], parentMarkers: ["Podfile"], label: "CocoaPods Pods/", kind: .apple,
              effect: "Installed pods. The workspace won't build until you run `pod install`."),
        .init(names: ["DerivedData"], label: "Project DerivedData", kind: .apple,
              effect: "Xcode build output kept next to the project. Rebuilt on the next build."),
        .init(names: [".venv", "venv", "env", ".env"], innerMarkers: ["pyvenv.cfg"], label: "Python virtualenv", kind: .python,
              effect: "This project's installed packages. Recreate the environment with `uv sync` or `python -m venv` plus pip install."),
        .init(names: [".tox", ".nox"], label: "tox/nox envs", kind: .python,
              effect: "Test environments. Rebuilt on the next tox or nox run."),
        .init(names: [".mypy_cache", ".pytest_cache", ".ruff_cache"], label: "Python tool cache", kind: .python,
              effect: "Lint and test caches. Regenerated on the next run."),
        .init(names: [".terraform"], label: "Terraform providers", kind: .toolchains,
              effect: "Provider plugins and modules. Re-downloaded by `terraform init`."),
        .init(names: [".stack-work"], parentMarkers: ["stack.yaml"], label: "Haskell .stack-work", kind: .toolchains,
              effect: "Stack build output. Rebuilt on the next stack build.",
              command: { _, p in "(cd \(shq(p)) && stack clean --full)" }),
        .init(names: ["_build", "deps"], parentMarkers: ["mix.exs"], label: "Elixir build/deps", kind: .toolchains,
              effect: "Compiled code or fetched deps. Restored by `mix deps.get && mix compile`."),
    ]

    /// Top-level folders in ~ the project walk never enters. Library is covered by the fixed rules above;
    /// Pictures holds the Photos library; Music and Movies are media folders.
    static let skipTopLevel: Set<String> = ["Library", "Pictures", "Music", "Movies", "Public", "Applications"]

    /// Folders that macOS guards with a permission prompt. Scanned only if the user opts in.
    static let protectedFolders = ["Desktop", "Documents", "Downloads"]

    /// Cloud-synced folders. Never entered.
    static let cloudPrefixes = ["Dropbox", "Google Drive", "My Drive", "OneDrive", "Box", "iCloud"]
}
