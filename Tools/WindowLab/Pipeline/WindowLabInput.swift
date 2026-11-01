import Foundation

enum LabMode: String {
    case observe, minimizeRestore, closeTarget, replay, placementReplay, transitionReplay
}

enum WindowLabInputError: Error {
    case invalidMode, invalidScenarioName, invalidGeometry, invalidScenario, duplicateWindowID
}

enum WindowLabInput {
    static func mode(_ arguments: [String]) throws -> LabMode {
        guard let value = arguments.first, let mode = LabMode(rawValue: value) else { throw WindowLabInputError.invalidMode }
        return mode
    }

    static func scenarioURL(root: URL, name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw WindowLabInputError.invalidScenarioName
        }
        return root.appendingPathComponent("Tools/WindowLab/Scenarios/\(name).json")
    }

    static func bounds(_ raw: String?) throws -> CGRect? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { Double($0) }
        guard parts.count == 4, values.count == 4 else { throw WindowLabInputError.invalidGeometry }
        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard WindowFrameMatchPolicy.isValid(frame) else { throw WindowLabInputError.invalidGeometry }
        return frame
    }
}


extension WindowLabInput {
    static func requireUniqueWindowIDs(_ ids: [String]) throws {
        guard ids.count <= 10_000, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw WindowLabInputError.duplicateWindowID
        }
    }

    static func decode<Scenario: Decodable>(_ type: Scenario.Type, from url: URL) throws -> Scenario {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else { throw WindowLabInputError.invalidScenario }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
