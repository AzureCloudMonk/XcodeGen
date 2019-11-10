import Foundation
import PathKit
import ProjectSpec
import SwiftCLI
import XcodeGenKit
import XcodeProj

class GenerateCommand: ProjectCommand {

    let quiet = Flag(
        "-q",
        "--quiet",
        description: "Suppress all informational and success output",
        defaultValue: false
    )

    let useCache = Flag(
        "-c",
        "--use-cache",
        description: "Use a cache for the xcodegen spec. This will prevent unnecessarily generating the project if nothing has changed",
        defaultValue: false
    )

    let cacheFilePath = Key<Path>(
        "--cache-path",
        description: "Where the cache file will be loaded from and save to. Defaults to ~/.xcodegen/cache/{SPEC_PATH_HASH}"
    )

    let projectDirectory = Key<Path>(
        "-p",
        "--project",
        description: "The path to the directory where the project should be generated. Defaults to the directory the spec is in. The filename is defined in the project spec"
    )

    init(version: Version) {
        super.init(version: version,
                   name: "generate",
                   shortDescription: "Generate an Xcode project from a spec"
        )
    }

    override func execute(specLoader: SpecLoader, projectSpecPath: Path, project: Project) throws {

        let projectDirectory = self.projectDirectory.value?.absolute() ?? projectSpecPath.parent()

        // validate project dictionary
        do {
            try specLoader.validateProjectDictionaryWarnings()
        } catch {
            warning("\(error)")
        }

        let projectPath = projectDirectory + "\(project.name).xcodeproj"

        let cacheFilePath = self.cacheFilePath.value ??
            Path("~/.xcodegen/cache/\(projectSpecPath.absolute().string.md5)").absolute()
        var cacheFile: CacheFile?

        // read cache
        if useCache.value || self.cacheFilePath.value != nil {
            do {
                cacheFile = try specLoader.generateCacheFile()
            } catch {
                throw GenerationError.projectSpecParsingError(error)
            }
        }

        let projectExists = XcodeProj.pbxprojPath(projectPath).exists

        // check cache
        if let cacheFile = cacheFile,
            projectExists,
            cacheFilePath.exists {
            do {
                let existingCacheFile: String = try cacheFilePath.read()
                if cacheFile.string == existingCacheFile {
                    info("Project has not changed since cache was written")
                    return
                }
            } catch {
                info("Couldn't load cache at \(cacheFile)")
            }
        }

        // validate project
        do {
            try project.validateMinimumXcodeGenVersion(version)
            try project.validate()
        } catch let error as SpecValidationError {
            throw GenerationError.validationError(error)
        }

        // generate plists
        info("⚙️  Generating plists...")
        let fileWriter = FileWriter(project: project)
        do {
            try fileWriter.writePlists()
        } catch {
            throw GenerationError.writingError(error)
        }

        // generate project
        info("⚙️  Generating project...")
        let xcodeProject: XcodeProj
        do {
            let projectGenerator = ProjectGenerator(project: project)
            xcodeProject = try projectGenerator.generateXcodeProject(in: projectDirectory)
        } catch {
            throw GenerationError.generationError(error)
        }

        // write project
        info("⚙️  Writing project...")
        do {
            try fileWriter.writeXcodeProject(xcodeProject, to: projectPath)
            success("Created project at \(projectPath)")
        } catch {
            throw GenerationError.writingError(error)
        }

        // write cache
        if let cacheFile = cacheFile {
            do {
                try cacheFilePath.parent().mkpath()
                try cacheFilePath.write(cacheFile.string)
            } catch {
                info("Failed to write cache: \(error.localizedDescription)")
            }
        }
    }

    func info(_ string: String) {
        if !quiet.value {
            stdout.print(string)
        }
    }

    func warning(_ string: String) {
        if !quiet.value {
            stdout.print(string.yellow)
        }
    }

    func success(_ string: String) {
        if !quiet.value {
            stdout.print(string.green)
        }
    }
}
