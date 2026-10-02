// The key, the config file and the model list: where each comes from,
// and what is written to disk. Every test has a home folder of its own
// (`OPENROUTER_HOME` in the environment it passes), never the real one.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

/// An environment whose home is a new, empty folder, and that folder.
private func home(_ variables: [String: String] = [:]) throws -> (environment: [String: String], directory: URL) {
    let directory = try scratch().appendingPathComponent("home")
    return (variables.merging(["OPENROUTER_HOME": directory.path]) { given, _ in given }, directory)
}

private func permissions(_ url: URL) throws -> Int {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

// MARK: The key

@Test func theKeyComesFromTheEnvironmentAndThenTheConfig() throws {
    let (environment, _) = try home()
    #expect(ORConfig.resolvedKey(environment: environment) == nil)
    #expect(ORConfig.keySource(environment: environment) == nil)

    try ORConfig(apiKey: " sk-or-file \n").save(environment: environment)
    #expect(ORConfig.resolvedKey(environment: environment) == "sk-or-file")
    #expect(ORConfig.keySource(environment: environment) == ORConfig.file(environment: environment).path)

    // A variable wins over the file, and the first variable over the second.
    let second = environment.merging(["OPEN_ROUTER_API_KEY": "sk-or-b"]) { $1 }
    #expect(ORConfig.resolvedKey(environment: second) == "sk-or-b")
    #expect(ORConfig.keySource(environment: second) == "environment (OPEN_ROUTER_API_KEY)")
    let both = second.merging(["OPENROUTER_API_KEY": " sk-or-a "]) { $1 }
    #expect(ORConfig.resolvedKey(environment: both) == "sk-or-a")
    #expect(ORConfig.keySource(environment: both) == "environment (OPENROUTER_API_KEY)")
}

/// A variable holding only white space is no key, to the key and to what
/// says where the key came from alike.
@Test func aBlankVariableIsNoKey() throws {
    let (environment, _) = try home(["OPENROUTER_API_KEY": "  \n", "OPEN_ROUTER_API_KEY": ""])
    #expect(ORConfig.resolvedKey(environment: environment) == nil)
    #expect(ORConfig.keySource(environment: environment) == nil)
    try ORConfig(apiKey: "sk-or-file").save(environment: environment)
    #expect(ORConfig.resolvedKey(environment: environment) == "sk-or-file")
    #expect(ORConfig.keySource(environment: environment) == ORConfig.file(environment: environment).path)
    // And a blank key in the file is none either.
    try ORConfig(apiKey: "   ").save(environment: environment)
    #expect(ORConfig.resolvedKey(environment: environment) == nil)
    #expect(ORConfig.keySource(environment: environment) == nil)
}

// MARK: The config file

@Test func theConfigIsTheOwnersAloneFromTheStart() throws {
    let (environment, directory) = try home()
    let file = ORConfig.file(environment: environment)
    #expect(file == directory.appendingPathComponent("config.json"))
    try ORConfig(apiKey: "sk-or-one", model: "a/b").save(environment: environment)
    #expect(try permissions(file) == 0o600)
    #expect(try ORConfig.read(environment: environment) == ORConfig(apiKey: "sk-or-one", model: "a/b"))

    // Written over a file that was readable by all, it is still the owner's alone.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try ORConfig(apiKey: "sk-or-two").save(environment: environment)
    #expect(try permissions(file) == 0o600)
    #expect(try ORConfig.read(environment: environment) == ORConfig(apiKey: "sk-or-two"))
    // Nothing is left beside it.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])
}

@Test func aMissingConfigIsEmptyAndAnUnreadableOneIsNotTakenForEmpty() throws {
    let (environment, directory) = try home()
    #expect(try ORConfig.read(environment: environment) == ORConfig())
    #expect(ORConfig.load(environment: environment) == ORConfig())

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"model": "a/b", "apiKey": "#.utf8).write(to: ORConfig.file(environment: environment))
    // To run with, there is no config; to whoever would write it back, there is a file that must not be replaced.
    #expect(ORConfig.load(environment: environment) == ORConfig())
    #expect(throws: DecodingError.self) { try ORConfig.read(environment: environment) }
}

@Test func theModelIsTheOneAskedForThenTheConfigsThenTheDefault() throws {
    let (environment, _) = try home()
    #expect(ORConfig.model(requested: nil, environment: environment) == ORConfig.defaultModel)
    #expect(ORConfig.model(requested: "", environment: environment) == ORConfig.defaultModel)
    try ORConfig(model: "configured/model").save(environment: environment)
    #expect(ORConfig.model(requested: nil, environment: environment) == "configured/model")
    #expect(ORConfig.model(requested: "asked/for", environment: environment) == "asked/for")
}

@Test func theHomeFolderCanBeMoved() {
    #expect(ORConfig.directory(environment: ["OPENROUTER_HOME": "/tmp/elsewhere"]).path == "/tmp/elsewhere")
    #expect(ORConfig.directory(environment: ["OPENROUTER_HOME": "~/elsewhere"]).path == NSHomeDirectory() + "/elsewhere")
    #expect(ORConfig.directory(environment: ["OPENROUTER_HOME": ""]).path == NSHomeDirectory() + "/.openrouter")
    #expect(ORConfig.directory(environment: [:]).path == NSHomeDirectory() + "/.openrouter")
}

// MARK: Checking a key

/// The model list answers any key, so a key is checked where OpenRouter
/// does look at it.
@Test func aKeyIsCheckedWhereOpenRouterLooksAtIt() async throws {
    let knows = MockTransport(answers: ["/api/v1/key": (200, #"{"data":{"label":"sk-or-…"}}"#)])
    try await OpenRouterClient(apiKey: "sk-or-good", transport: knows).checkKey()
    #expect(await knows.requested == ["/api/v1/key"])
    #expect(await knows.lastAuthorization == "Bearer sk-or-good")

    let refuses = MockTransport(answers: ["/api/v1/key": (401, #"{"error":{"message":"No auth credentials found","code":401}}"#),
                                          "/api/v1/models": (200, #"{"data":[]}"#)])
    let client = OpenRouterClient(apiKey: "sk-or-bad", transport: refuses)
    let error = await #expect(throws: OpenRouterError.self) { try await client.checkKey() }
    #expect(error?.status == 401)
    // What the old check asked: the model list, which the bad key gets.
    #expect(try await client.models().isEmpty)
}

// MARK: The model list on disk

private let twoModels = #"{"data":[{"id":"b/two","name":"B: Two","supported_parameters":["tools"]},{"id":"a/one:free","name":"A: One"}]}"#

@Test func theModelListIsFetchedAndKept() async throws {
    let cache = ORModelCache(file: try scratch().appendingPathComponent("deep/models.json"))
    #expect(cache.load() == nil)
    #expect(cache.isStale)
    let transport = MockTransport(answers: ["/api/v1/models": (200, twoModels),
                                            "/api/v1/models?category=programming": (200, #"{"data":[{"id":"b/two"}]}"#)])
    let models = try await cache.refresh(client: OpenRouterClient(apiKey: "", transport: transport))
    #expect(models.map(\.id) == ["a/one:free", "b/two"])
    #expect(models.map(\.isFree) == [true, false])
    #expect(models.map(\.supportsTools) == [false, true])
    let kept = try #require(cache.load())
    #expect(kept.models.map(\.id) == ["a/one:free", "b/two"])
    #expect(kept.programming == ["b/two"])
    #expect(!cache.isStale)
    // No key was needed, and none was sent.
    #expect(await transport.lastAuthorization == nil)
}

@Test func aListOlderThanADayIsStale() throws {
    let cache = ORModelCache(file: try scratch().appendingPathComponent("models.json"))
    let old = ORModelCache.Contents(fetched: Date().timeIntervalSince1970 - ORModelCache.maxAge - 60, models: [], programming: nil)
    try JSONEncoder().encode(old).write(to: cache.file)
    #expect(cache.isStale)
    let recent = ORModelCache.Contents(fetched: Date().timeIntervalSince1970 - ORModelCache.maxAge + 60, models: [], programming: nil)
    try JSONEncoder().encode(recent).write(to: cache.file)
    #expect(!cache.isStale)
}

/// The programming category is a second request. When it alone fails,
/// the category on disk is kept with the new list; when the list itself
/// fails, nothing on disk changes.
@Test func aFailedRefreshDoesNotWipeWhatIsKept() async throws {
    let cache = ORModelCache(file: try scratch().appendingPathComponent("models.json"))
    try cache.save([], programming: ["kept/model"])
    let half = MockTransport(answers: ["/api/v1/models": (200, twoModels), "/api/v1/models?category=programming": (503, "busy")])
    _ = try await cache.refresh(client: OpenRouterClient(apiKey: "", transport: half))
    #expect(cache.load()?.models.count == 2)
    #expect(cache.load()?.programming == ["kept/model"])

    let before = try Data(contentsOf: cache.file)
    let down = MockTransport(status: 503)
    let error = await #expect(throws: OpenRouterError.self) { try await cache.refresh(client: OpenRouterClient(apiKey: "", transport: down)) }
    #expect(error?.status == 503)
    #expect(try Data(contentsOf: cache.file) == before)
}

// MARK: A tool's schema

private struct BadSchemaTool: ORTool {
    let name = "broken"
    let toolDescription = "A tool whose parameters are not a JSON object."
    let parametersJSON: String
    func call(arguments: String) async throws -> String { "" }
}

/// A tool whose parameters are not a JSON object is not described to the
/// model as taking anything at all: the request is not made.
@Test func aToolWithParametersThatAreNotAnObjectIsNotSent() async throws {
    for parameters in ["not json", "[1, 2]", "\"text\"", ""] {
        let mock = MockTransport(streams: [try reply("unasked")])
        let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [BadSchemaTool(parametersJSON: parameters)])
        await #expect(throws: ORToolSchemaError(tool: "broken")) { try await agent.send("go") { _ in } }
        #expect(await mock.sentBodies.isEmpty)
    }
}
