import CoreGraphics
import EchoNylaCore
import Foundation

/// One file to ask the on-device model about.
public struct LocalQuestion: Sendable {
    public var facts: FileFacts
    /// A picture of the file: the image itself, a PDF's first page, or a document's preview.
    public var picture: RGBImage?
    public var destinations: [Destination]
    public var locked: Set<String>
    /// For Check This Folder: the folder the file is in now.
    public var currentFolderName: String?
    /// How the person filed similar files before ("“name” → Folder").
    public var examples: [String]
    /// When a picture was taken, for its new name's date.
    public var captured: Date?

    public init(facts: FileFacts, picture: RGBImage?, destinations: [Destination], locked: Set<String>,
                currentFolderName: String? = nil, examples: [String] = [], captured: Date? = nil) {
        self.facts = facts
        self.picture = picture
        self.destinations = destinations
        self.locked = locked
        self.currentFolderName = currentFolderName
        self.examples = examples
        self.captured = captured
    }
}

public struct LocalResult: Sendable {
    public var decision: LocalDecision
    public var answer: LocalAnswer
    public var reply: EngineReply
}

/// Asks the on-device model about one file and runs every check on its answer.
public enum LocalFileModel {
    public static func ask(_ question: LocalQuestion, paths: ModelPaths, bar: ConfidenceBar,
                           engine: LlamaEngine = .shared) async throws -> LocalResult {
        let allowed = AIFolders.choosable(question.destinations, locked: question.locked)
        let text = LocalPrompt.question(facts: question.facts, destinations: question.destinations, locked: question.locked,
                                        currentFolderName: question.currentFolderName, examples: question.examples,
                                        imageMarker: question.picture == nil ? nil : LlamaEngine.marker)
        let reply = try await engine.generate(paths: paths, prompt: LocalPrompt.conversation(question: text),
                                              image: question.picture, grammar: LocalPrompt.grammar(folderNames: allowed.map(\.name)))
        guard let answer = LocalAnswer.parse(reply.text) else { throw EngineError.evaluationFailed(-100) }
        let decision = LocalDecisionCheck.check(answer, facts: question.facts, destinations: question.destinations,
                                                locked: question.locked, bar: bar, captured: question.captured)
        return LocalResult(decision: decision, answer: answer, reply: reply)
    }
}
