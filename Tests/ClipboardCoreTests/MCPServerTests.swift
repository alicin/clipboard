import Foundation
import Testing

@testable import ClipboardCore

@Suite struct MCPServerTests {
    private func call(_ server: MCPServer, method: String, params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let response = try #require(server.handle(try JSONSerialization.data(withJSONObject: request)))
        return try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func tool(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let response = try call(server, method: "tools/call", params: ["name": name, "arguments": arguments])
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    private func setUp(access: AIAccess) throws -> (TemporaryStore, MCPServer, pinned: Clip, loose: Clip) {
        let temp = try TemporaryStore()
        let pinned = try temp.add("Pinned snippet about deployment")
        let loose = try temp.add("Loose note about deployment")
        let board = try temp.store.createPinboard(name: "Work", color: "sky")
        try temp.store.pin(clipID: pinned.id, pinboardID: board.id)
        try temp.store.setAIAccess(access)
        return (temp, MCPServer { temp.store }, pinned, loose)
    }

    @Test func initializeEchoesSupportedVersion() throws {
        let (_, server, _, _) = try setUp(access: .off)
        let response = try call(server, method: "initialize", params: ["protocolVersion": "2025-06-18"])
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "clipboard")
        #expect(response["id"] as? Int == 1)
    }

    @Test func unknownProtocolVersionGetsOurLatest() throws {
        let (_, server, _, _) = try setUp(access: .off)
        let response = try call(server, method: "initialize", params: ["protocolVersion": "1999-01-01"])
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
    }

    @Test func notificationsGetNoResponse() throws {
        let (_, server, _, _) = try setUp(access: .off)
        let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(server.handle(line) == nil)
    }

    @Test func malformedInputAndUnknownMethodsReturnErrors() throws {
        let (_, server, _, _) = try setUp(access: .off)
        let parse = try #require(server.handle(Data("not json".utf8)))
        let parsed = try #require(try JSONSerialization.jsonObject(with: parse) as? [String: Any])
        #expect((parsed["error"] as? [String: Any])?["code"] as? Int == -32700)
        let unknown = try call(server, method: "nope/nope")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func toolsListNamesEveryTool() throws {
        let (_, server, _, _) = try setUp(access: .off)
        let response = try call(server, method: "tools/list")
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == [
            "clipboard_search", "clipboard_recent", "clipboard_get", "pinboards_list", "pinboard_items",
        ])
    }

    @Test func accessOffRefusesEveryTool() throws {
        let (_, server, pinned, _) = try setUp(access: .off)
        for (name, arguments) in [
            ("clipboard_recent", [:]), ("clipboard_search", ["query": "deployment"]),
            ("clipboard_get", ["id": pinned.id]), ("pinboards_list", [:]), ("pinboard_items", ["pinboard": "Work"]),
        ] as [(String, [String: Any])] {
            let result = try tool(server, name, arguments)
            #expect(result.isError, "\(name) should be refused")
            #expect(!result.text.contains("deployment"))
        }
    }

    @Test func pinboardsAccessHidesLooseClips() throws {
        let (_, server, pinned, loose) = try setUp(access: .pinboards)
        let recent = try tool(server, "clipboard_recent")
        #expect(recent.text.contains("Pinned snippet"))
        #expect(!recent.text.contains("Loose note"))

        let search = try tool(server, "clipboard_search", ["query": "deployment"])
        #expect(search.text.contains("Pinned snippet"))
        #expect(!search.text.contains("Loose note"))

        #expect(try tool(server, "clipboard_get", ["id": pinned.id]).text.contains("Pinned snippet"))
        let refused = try tool(server, "clipboard_get", ["id": loose.id])
        #expect(refused.isError)
        #expect(!refused.text.contains("Loose note"))
    }

    @Test func everythingAccessSeesAllAndGetReturnsFullText() throws {
        let (temp, server, _, loose) = try setUp(access: .everything)
        #expect(try tool(server, "clipboard_recent").text.contains("Loose note"))
        let long = String(repeating: "word ", count: 500)
        let clip = try temp.add(long)
        let full = try tool(server, "clipboard_get", ["id": clip.id])
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(full.text.utf8)) as? [String: Any])
        #expect(decoded["text"] as? String == long)
        #expect(try tool(server, "clipboard_get", ["id": loose.id]).isError == false)
    }

    @Test func accessChangeAppliesWithoutRestart() throws {
        let (temp, server, _, _) = try setUp(access: .everything)
        #expect(try tool(server, "clipboard_recent").isError == false)
        try temp.store.setAIAccess(.off)
        #expect(try tool(server, "clipboard_recent").isError)
    }

    @Test func pinboardToolsResolveNameOrID() throws {
        let (temp, server, _, _) = try setUp(access: .pinboards)
        #expect(try tool(server, "pinboards_list").text.contains("Work"))
        #expect(try tool(server, "pinboard_items", ["pinboard": "work"]).text.contains("Pinned snippet"))
        let id = try #require(try temp.store.pinboards().first?.id)
        #expect(try tool(server, "pinboard_items", ["pinboard": String(id)]).text.contains("Pinned snippet"))
        #expect(try tool(server, "pinboard_items", ["pinboard": "Missing"]).isError)
    }

    @Test func missingDatabaseIsAToolErrorNotACrash() throws {
        let server = MCPServer {
            try ClipStore(directory: URL(fileURLWithPath: "/tmp/paste-missing-\(UUID().uuidString)"), readOnly: true)
        }
        let result = try tool(server, "clipboard_recent")
        #expect(result.isError)
        #expect(result.text.contains("No clipboard history yet"))
    }
}
