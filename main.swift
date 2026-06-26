//
//  main.swift
//  RenameMP4ByCreationDate
//
//  Outil en ligne de commande (macOS) qui :
//   1. Demande à l'utilisateur de choisir un répertoire via une boîte de
//      dialogue native (NSOpenPanel).
//   2. Recherche dans ce répertoire tous les fichiers correspondant au
//      motif "D*.MP4" (nom commençant par "D", extension .MP4, insensible
//      à la casse pour l'extension).
//   3. Pour chaque fichier trouvé, extrait la date de création depuis les
//      métadonnées vidéo via `ffprobe` (balise TAG:creation_time).
//   4. Renomme le fichier en le préfixant par la date au format
//      JJ-MM-AAAA : "JJ-MM-AAAA_NomOriginal.MP4"
//   5. Si la date de création est introuvable dans les métadonnées,
//      le fichier est ignoré (aucun renommage, aucun repli sur la date
//      de modification du fichier).
//
//  Compilation :
//      swiftc -O main.swift -o RenameMP4ByCreationDate \
//          -framework Cocoa
//
//  Exécution :
//      ./RenameMP4ByCreationDate
//
//  Prérequis :
//      - macOS (utilise AppKit / NSOpenPanel)
//      - ffprobe doit être installé et accessible (Homebrew : `brew install ffmpeg`)
//

import Cocoa
import Foundation

// MARK: - Configuration

/// Motif de recherche : fichiers dont le nom commence par "D" et dont
/// l'extension est "MP4" (comparaison insensible à la casse sur l'extension,
/// mais la lettre initiale "D" est vérifiée en majuscule comme dans le script
/// d'origine).
let searchPrefix = "D"
let searchExtension = "mp4" // comparé en minuscule après lowercased()

// MARK: - Sélection du répertoire (NSOpenPanel)

/// Affiche une boîte de dialogue native permettant à l'utilisateur de
/// choisir un répertoire. Retourne le chemin choisi, ou nil si l'utilisateur
/// annule.
func chooseDirectory() -> String? {
    // NSOpenPanel nécessite une app/run loop Cocoa, même pour un outil CLI.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let panel = NSOpenPanel()
    panel.title = "Choisissez le répertoire contenant les vidéos"
    panel.message = "Sélectionnez le dossier à analyser (fichiers D*.MP4)"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    // Force la fenêtre au premier plan.
    app.activate(ignoringOtherApps: true)

    let response = panel.runModal()
    if response == .OK, let url = panel.url {
        return url.path
    }
    return nil
}

// MARK: - Extraction des métadonnées via ffprobe

/// Exécute `ffprobe` en demandant explicitement le format et les flux,
/// avec une sortie structurée en JSON (plus robuste qu'un parsing texte
/// ligne par ligne). Retourne la chaîne de date ISO trouvée
/// (ex: "2026-06-21T10:32:11.000000Z"), en cherchant d'abord dans les tags
/// du format (conteneur), puis, si absente, dans les tags de chaque flux.
/// Retourne nil si la balise est introuvable partout ou en cas d'erreur.
func getCreationTime(forFile filePath: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "ffprobe",
        "-v", "error",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        filePath
    ]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        print("⚠️  Impossible de lancer ffprobe pour \(filePath) : \(error.localizedDescription)")
        return nil
    }

    // Lecture asynchrone pour éviter tout blocage si la sortie est volumineuse
    // (gros fichiers avec beaucoup de flux/métadonnées peuvent saturer le
    // buffer du Pipe si on attend la fin du process avant de lire).
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        print("⚠️  ffprobe a renvoyé une erreur pour \(filePath) : \(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }

    return extractCreationTime(fromJSONData: stdoutData)
}

/// Parse la sortie JSON de ffprobe et recherche la balise "creation_time"
/// d'abord dans format.tags, puis, à défaut, dans streams[].tags.
func extractCreationTime(fromJSONData data: Data) -> String? {
    guard
        let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }

    // 1. Priorité aux tags du format (conteneur).
    if let format = json["format"] as? [String: Any],
       let tags = format["tags"] as? [String: Any],
       let creationTime = (tags["creation_time"] ?? tags["CREATION_TIME"]) as? String {
        return creationTime
    }

    // 2. Repli : on parcourt les flux (vidéo en priorité, puis les autres).
    if let streams = json["streams"] as? [[String: Any]] {
        // Trie pour regarder le flux vidéo d'abord, s'il existe.
        let sortedStreams = streams.sorted { lhs, rhs in
            let lhsIsVideo = (lhs["codec_type"] as? String) == "video"
            let rhsIsVideo = (rhs["codec_type"] as? String) == "video"
            return lhsIsVideo && !rhsIsVideo
        }

        for stream in sortedStreams {
            if let tags = stream["tags"] as? [String: Any],
               let creationTime = (tags["creation_time"] ?? tags["CREATION_TIME"]) as? String {
                return creationTime
            }
        }
    }

    return nil
}

// MARK: - Parsing de la date ISO et formatage JJ-MM-AAAA

/// Convertit une chaîne de date ISO (telle que renvoyée par ffprobe,
/// ex: "2026-06-21T10:32:11.000000Z") en préfixe "JJ-MM-AAAA".
/// Retourne nil si le parsing échoue.
func formatDatePrefix(fromISODate isoDate: String) -> String? {
    // ffprobe peut renvoyer des microsecondes (6 chiffres) que
    // ISO8601DateFormatter standard ne gère pas toujours nativement.
    // On essaie plusieurs stratégies de parsing.

    // 1. Essai avec ISO8601DateFormatter (gère "...Z" et fractions de seconde
    //    si l'option .withFractionalSeconds est activée — mais celle-ci ne
    //    supporte que les millisecondes, donc on normalise d'abord la chaîne).
    let normalized = normalizeFractionalSeconds(isoDate)

    let isoFormatterWithFraction = ISO8601DateFormatter()
    isoFormatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let isoFormatterPlain = ISO8601DateFormatter()
    isoFormatterPlain.formatOptions = [.withInternetDateTime]

    var parsedDate: Date?

    if let date = isoFormatterWithFraction.date(from: normalized) {
        parsedDate = date
    } else if let date = isoFormatterPlain.date(from: normalized) {
        parsedDate = date
    } else {
        // 2. Repli : DateFormatter manuel pour plus de tolérance.
        let manualFormatter = DateFormatter()
        manualFormatter.locale = Locale(identifier: "en_US_POSIX")
        manualFormatter.timeZone = TimeZone(identifier: "UTC")

        let candidateFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd HH:mm:ss"
        ]

        for format in candidateFormats {
            manualFormatter.dateFormat = format
            if let date = manualFormatter.date(from: isoDate) {
                parsedDate = date
                break
            }
        }
    }

    guard let date = parsedDate else {
        return nil
    }

    let outputFormatter = DateFormatter()
    outputFormatter.locale = Locale(identifier: "en_US_POSIX")
    outputFormatter.dateFormat = "dd-MM-yyyy"
    return outputFormatter.string(from: date)
}

/// ISO8601DateFormatter avec .withFractionalSeconds n'accepte que jusqu'à
/// 3 chiffres de fraction de seconde (millisecondes). ffprobe renvoie
/// souvent 6 chiffres (microsecondes). Cette fonction tronque la fraction
/// de seconde à 3 chiffres si nécessaire.
func normalizeFractionalSeconds(_ isoDate: String) -> String {
    guard let dotIndex = isoDate.firstIndex(of: ".") else {
        return isoDate
    }
    let afterDot = isoDate.index(after: dotIndex)
    guard let zIndex = isoDate[afterDot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
        return isoDate
    }

    let fraction = isoDate[afterDot..<zIndex]
    let truncatedFraction = String(fraction.prefix(3))

    var result = String(isoDate[..<dotIndex])
    result += "."
    result += truncatedFraction
    result += String(isoDate[zIndex...])
    return result
}

// MARK: - Vérification "déjà traité"

/// Vérifie si un nom de fichier commence déjà par un préfixe de date au
/// format "JJ-MM-AAAA_" (pour éviter de re-renommer un fichier déjà traité).
func alreadyHasDatePrefix(_ filename: String) -> Bool {
    // Motif attendu : ^\d{2}-\d{2}-\d{4}_
    let pattern = "^[0-9]{2}-[0-9]{2}-[0-9]{4}_"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return false
    }
    let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
    return regex.firstMatch(in: filename, options: [], range: range) != nil
}

// MARK: - Renommage du fichier

/// Tente de renommer un fichier MP4 en se basant sur sa date de création
/// extraite des métadonnées vidéo (ffprobe). Si la date de création est
/// introuvable, le fichier est ignoré.
func renameFile(at directory: String, filename: String) {
    let fullPath = (directory as NSString).appendingPathComponent(filename)

    // Évite de re-traiter un fichier déjà renommé avec le préfixe de date.
    if alreadyHasDatePrefix(filename) {
        print("⏭️  Ignoré (déjà traité) : \(filename)")
        return
    }

    guard let creationTimeISO = getCreationTime(forFile: fullPath) else {
        print("⏭️  Ignoré (date de création introuvable dans les métadonnées) : \(filename)")
        return
    }

    guard let datePrefix = formatDatePrefix(fromISODate: creationTimeISO) else {
        print("⏭️  Ignoré (date de création illisible \"\(creationTimeISO)\") : \(filename)")
        return
    }

    let newFilename = "\(datePrefix)_\(filename)"
    let newFullPath = (directory as NSString).appendingPathComponent(newFilename)

    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: newFullPath) {
        print("⚠️  Ignoré (un fichier nommé \"\(newFilename)\" existe déjà) : \(filename)")
        return
    }

    do {
        try fileManager.moveItem(atPath: fullPath, toPath: newFullPath)
        print("✅  Renommé : \(filename)  →  \(newFilename)")
    } catch {
        print("❌  Erreur lors du renommage de \(filename) : \(error.localizedDescription)")
    }
}

// MARK: - Filtrage selon le motif D*.MP4

/// Vérifie si un nom de fichier correspond au motif "D*.MP4" :
/// commence par "D" (majuscule) et se termine par ".MP4"
/// (extension comparée de façon insensible à la casse).
func matchesSearchPattern(_ filename: String) -> Bool {
    guard filename.hasPrefix(searchPrefix) else {
        return false
    }
    let ext = (filename as NSString).pathExtension.lowercased()
    return ext == searchExtension
}

// MARK: - Programme principal

func runMain() {
    print("=== Renommage de fichiers vidéo D*.MP4 selon leur date de création ===\n")

    guard let targetDir = chooseDirectory() else {
        print("Aucun répertoire sélectionné. Arrêt du programme.")
        return
    }

    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: targetDir, isDirectory: &isDirectory), isDirectory.boolValue else {
        print("❌  Le répertoire \"\(targetDir)\" n'existe pas ou n'est pas un dossier valide.")
        return
    }

    print("📁 Répertoire ciblé : \(targetDir)\n")

    let allFiles: [String]
    do {
        allFiles = try fileManager.contentsOfDirectory(atPath: targetDir)
    } catch {
        print("❌  Impossible de lister le contenu du répertoire : \(error.localizedDescription)")
        return
    }

    let matchingFiles = allFiles.filter { matchesSearchPattern($0) }.sorted()

    if matchingFiles.isEmpty {
        print("Aucun fichier correspondant au motif \"D*.MP4\" n'a été trouvé.")
        return
    }

    print("🔎 \(matchingFiles.count) fichier(s) correspondant(s) trouvé(s) :")
    for f in matchingFiles {
        print("   - \(f)")
    }
    print("")

    for filename in matchingFiles {
        renameFile(at: targetDir, filename: filename)
    }

    print("\n=== Terminé ===")
}

runMain()

