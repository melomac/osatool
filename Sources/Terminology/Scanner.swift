import Extensions
import Foundation

/** What a scan found. */
package struct ScanResult: Sendable {
    /** One dictionary for each application (or other bundle), sorted by name. */
    package var dictionaries: [ScriptingDictionary]
    /** One line for each file that could not be read. */
    package var problems: [String]
}

/**
 Looks for scripting definitions in files and folders, and reads them.

 These kinds of file are read:

 ```
 Name.sdef                                    XML scripting definition
 Name.scriptSuite + Name.scriptTerminology    the older pair of property lists
 any other file                               a file a scan was saved in before
                                              (see `TerminologyStore`), or the
                                              language file (see `LanguageDefinition`)
 ```

 A saved file is read only when it is named: a folder is not searched
 for them. Its dictionaries are taken as they are, before the others.

 A folder is searched to any depth, also inside applications. A symbolic
 link to a folder is followed when it leads out of the folders being
 searched: `/Applications/Safari.app` is such a link. A link that stays
 inside is not followed, because its target is searched anyway. A link
 inside an application, or another bundle, is not followed either: an
 application that anyone made could send the scan to the whole disk
 that way, and what is found there is not a part of it.

 All the files of one application go into one dictionary, named after it:

 ```
 /Applications/Keynote.app/Contents/Resources/Keynote.sdef        →  "Keynote"
 /System/…/System Events.app/Contents/Resources/SystemEvents.sdef  ┐
 /System/…/System Events.app/Contents/Resources/Power.scriptSuite  ┴→ "System Events"
 ```

 Inside one dictionary a code keeps its first meaning: SDEF files are
 read first, then script suites, each in path order.

 A file that an SDEF file includes is read with it, and its words go
 into the same dictionary, after the words of the file itself (see
 `parseSDEFDocument`). Only another `.sdef` file on this computer is
 read that way.

 The dictionary of an application also gets the identifier of the
 application, from its `Info.plist`. When that file names a scripting
 definition (the key `OSAScriptingDefinition`), the system reads only
 that file, and the script suites the application still has are old
 files that nothing uses. The scan leaves them out too: their words
 would not compile.

 Only a file is read, and only up to `maximumDefinitionSize`: a link
 can lead to a device that never ends, and a file can be very large.
 */
package func scanTerminology(paths: [String]) -> ScanResult {
    var (files, problems) = definitionFiles(under: paths)
    let manager = FileManager.default

    /** Reads a file of dictionaries, or the language file, which has no dictionaries of its own. */
    func saved(_ path: String) throws -> [ScriptingDictionary] {
        let data = try path.definitionFileData()
        do {
            return try TerminologyStore(data: data).dictionaries
        } catch {
            guard let language = try? parseLanguageDefinition(data) else {
                throw error
            }
            return [language]
        }
    }

    // The `Info.plist` of an application is read once, not for each of its files.
    var information: [String: (identifier: String, scriptingDefinition: String)] = [:]
    func applicationInfo(_ path: String) -> (identifier: String, scriptingDefinition: String) {
        guard let bundle = path.applicationBundle else {
            return ("", "")
        }
        if let known = information[bundle] {
            return known
        }
        let read = bundle.bundleInfo
        information[bundle] = read
        return read
    }

    // sdef first, then script suites; inside each kind, path order.
    files = Array(Set(files)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    var byOwner: [String: ScriptingDictionary] = [:]
    func add(_ dictionary: ScriptingDictionary) {
        byOwner[dictionary.name, default: ScriptingDictionary(name: dictionary.name)].merge(dictionary)
    }
    // A folder gives only definition files, so any other file was named.
    for path in files where !terminologyExtensions.contains((path as NSString).pathExtension) {
        do {
            try saved(path).forEach(add)
        } catch {
            problems.append("\(path): \(error.message)")
        }
    }
    /**
     Reads an SDEF file, then the files it includes. `seen` holds the
     files read so far for this dictionary: a file is read once.
     */
    func definition(_ path: String, name: String, seen: inout Set<String>) throws -> ScriptingDictionary {
        var (dictionary, includes) = try parseSDEFDocument(name: name, data: path.definitionFileData())
        dictionary.sources = [path]
        for href in includes {
            guard
                let included = href.includedDefinitionPath(from: path),
                seen.count < maximumIncludedDefinitions
            else {
                problems.append("\(path): the included file \(href) is not read")
                continue
            }
            guard seen.insert((included as NSString).resolvingSymlinksInPath).inserted else {
                continue
            }
            do {
                try dictionary.merge(definition(included, name: name, seen: &seen))
            } catch {
                problems.append("\(path): the included file \(included) cannot be read: \(error.message)")
            }
        }
        return dictionary
    }

    for path in files where (path as NSString).pathExtension == "sdef" {
        do {
            var seen: Set = [(path as NSString).resolvingSymlinksInPath]
            var dictionary = try definition(path, name: path.dictionaryName, seen: &seen)
            dictionary.bundleID = applicationInfo(path).identifier
            add(dictionary)
        } catch {
            problems.append("\(path): \(error.message)")
        }
    }
    for path in files where (path as NSString).pathExtension == "scriptSuite" && applicationInfo(path).scriptingDefinition.isEmpty {
        let words = (path as NSString).deletingPathExtension + ".scriptTerminology"
        guard manager.fileExists(atPath: words) else {
            problems.append("\(path): no .scriptTerminology file next to it, so its codes have no names")
            continue
        }
        do {
            var dictionary = try parseScriptSuite(
                name: path.dictionaryName,
                suite: path.definitionFileData(),
                terminology: words.definitionFileData(),
            )
            dictionary.sources = [path, words]
            dictionary.bundleID = applicationInfo(path).identifier
            add(dictionary)
        } catch {
            problems.append("\(path): \(error.message)")
        }
    }
    let dictionaries = byOwner.values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    return ScanResult(dictionaries: dictionaries, problems: problems)
}

/**
 Lists the files a scan reads: each path that is a file, and the
 definition files under each path that is a folder, in the order they
 are found. A path is kept as the user wrote it.

 A link to a folder is followed, unless its target is inside a folder
 that is searched already: this also stops a chain of links that comes
 back. A link inside a bundle is not followed: see `scanTerminology`.

 - Returns: the files, and one line for each path that cannot be read.
 */
func definitionFiles(under paths: [String]) -> (files: [String], problems: [String]) {
    var files: [String] = []
    var problems: [String] = []
    let manager = FileManager.default
    var walked = Set<String>()

    func walk(_ folder: String) {
        let real = (folder as NSString).resolvingSymlinksInPath
        guard walked.insert(real).inserted else {
            return
        }
        // The link flag comes with the folder listing, so no extra call is made for each file.
        // The folder itself can be a link, and a listing does not go through one.
        let base = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
        guard let walker = manager.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            problems.append("\(folder): cannot be read")
            return
        }
        for case let url as URL in walker {
            // Keep the path as the user wrote it: the folder, then the part
            // below it, which is as many names as the listing is deep.
            let path = url.pathComponents.suffix(walker.level).reduce(folder) { ($0 as NSString).appendingPathComponent($1) }
            if terminologyExtensions.contains(url.pathExtension) {
                files.append(path)
            } else if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true, path.owner == nil {
                let target = (path as NSString).resolvingSymlinksInPath
                var isDirectory: ObjCBool = false
                let isSearched = walked.contains { target == $0 || target.hasPrefix($0 + "/") }
                if !isSearched, manager.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(path)
                }
            }
        }
    }

    for path in paths {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            problems.append("\(path): no such file or directory")
            continue
        }
        if !isDirectory.boolValue {
            files.append(path)
            continue
        }
        walk(path)
    }
    return (files, problems)
}

let terminologyExtensions: Set<String> = ["sdef", "scriptSuite", "scriptTerminology"]

/** How many included files are read for one dictionary, at most. */
let maximumIncludedDefinitions = 16

/**
 The largest file that a scan reads, in bytes. The largest definition
 of Apple's software is under one megabyte.
 */
package let maximumDefinitionSize = 64 * 1024 * 1024

/** The kinds of folder that stand for one application, addition or library. */
let ownerExtensions: Set<String> = ["app", "osax", "framework", "prefPane", "appex", "scptd", "action", "bundle", "plugin"]

package extension String {
    /**
     The name of the dictionary that the file at this path belongs to: the
     name of the innermost bundle around it.

     ```
     /Applications/Xcode.app/Contents/Applications/Instruments.app/…/Instruments.sdef  →  Instruments
     /System/Library/ScriptingAdditions/StandardAdditions.osax/…                       →  StandardAdditions
     /System/Library/ScriptingDefinitions/CocoaStandard.sdef                           →  CocoaStandard
     /System/Library/Frameworks/Foundation.framework/…/Intrinsics.sdef                 →  Intrinsics
     ```

     A file outside any bundle is named after itself. So is the file
     `Intrinsics.sdef` of Foundation: the system adds its words to every
     application (see `intrinsicsDictionaryName`), and the other files
     of Foundation are for some applications only.
     */
    var dictionaryName: String {
        let components = (self as NSString).pathComponents
        if components.last == intrinsicsDictionaryName + ".sdef" {
            return intrinsicsDictionaryName
        }
        if let owner = self.owner {
            return ((owner as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return ((components.last ?? self) as NSString).deletingPathExtension
    }

    /**
     The path of the innermost bundle around the file or folder at this
     path, or `nil` when it is in no bundle. The last name of the path
     does not count: a bundle is not around itself.

     ```
     /Applications/Xcode.app/Contents/Applications/Instruments.app/Contents/Resources/Instruments.sdef
         →  /Applications/Xcode.app/Contents/Applications/Instruments.app
     /Applications/Safari.app                                →  nil
     ```
     */
    var owner: String? {
        var components = (self as NSString).pathComponents
        components.removeLast(components.isEmpty ? 0 : 1)
        while let last = components.last {
            if ownerExtensions.contains((last as NSString).pathExtension) {
                return NSString.path(withComponents: components)
            }
            components.removeLast()
        }
        return nil
    }

    /** The innermost bundle around the file at this path, when that bundle is an application. */
    var applicationBundle: String? {
        self.owner.flatMap { ($0 as NSString).pathExtension == "app" ? $0 : nil }
    }

    /**
     What the `Info.plist` of the application at this path says:

     ```
     /System/Library/CoreServices/Finder.app
         identifier             com.apple.finder    (CFBundleIdentifier)
         scriptingDefinition    Finder.sdef         (OSAScriptingDefinition)
     ```

     - Returns: empty texts when the file cannot be read, or has no such key.
     */
    var bundleInfo: (identifier: String, scriptingDefinition: String) {
        let file = (self as NSString).appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? file.definitionFileData(),
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return ("", "")
        }
        return (list["CFBundleIdentifier"] as? String ?? "", list["OSAScriptingDefinition"] as? String ?? "")
    }

    /**
     What the `Info.plist` of the application says, for the application
     that the file at this path belongs to.

     - Returns: empty texts when the innermost bundle around the file
       is not an application, or when its `Info.plist` has no such key.
     */
    var applicationInfo: (identifier: String, scriptingDefinition: String) {
        self.applicationBundle?.bundleInfo ?? ("", "")
    }

    /**
     Reads the file at this path: a file that the scan was sent to, and
     that anyone could have made.

     - Throws: when the path does not lead to a file (a folder, or a
       device like `/dev/zero`, which never ends), when the file is
       larger than `maximumDefinitionSize`, or when it cannot be read.
     */
    func definitionFileData() throws -> Data {
        let real = (self as NSString).resolvingSymlinksInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: real) else {
            throw ScriptError("the file cannot be read")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ScriptError("not a file")
        }
        if let size = attributes[.size] as? Int, size > maximumDefinitionSize {
            throw ScriptError("the file is larger than \(maximumDefinitionSize) bytes")
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: real))
        } catch {
            throw ScriptError(error.localizedDescription)
        }
    }

    /**
     The path of the file that an SDEF file at `path` includes with this
     `href`: a `file:` address, or a path from the folder of the file.

     ```
     file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef
     file://localhost/System/Library/ScriptingDefinitions/CocoaStandard.sdef
     Shared.sdef
     ```

     - Returns: `nil` for anything that is not an `.sdef` file on this
       computer: another kind of address, another kind of file, a
       folder, a device.
     */
    func includedDefinitionPath(from path: String) -> String? {
        var included = self
        if let url = URL(string: self), let scheme = url.scheme {
            guard
                scheme == "file",
                url.host == nil || url.host == "" || url.host == "localhost"
            else {
                return nil
            }
            included = url.path
        } else if !self.hasPrefix("/") {
            included = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(self)
        }
        guard
            (included as NSString).pathExtension == "sdef",
            let kind = try? FileManager.default.attributesOfItem(atPath: (included as NSString).resolvingSymlinksInPath)[.type] as? FileAttributeType,
            kind == .typeRegular
        else {
            return nil
        }
        return included
    }
}
