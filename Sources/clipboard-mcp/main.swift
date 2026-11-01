import Foundation
import ClipboardCore

let server = MCPServer { try ClipStore(readOnly: true) }

while let line = readLine(strippingNewline: true) {
    guard !line.allSatisfy(\.isWhitespace) else { continue }
    if let response = server.handle(Data(line.utf8)) {
        FileHandle.standardOutput.write(response + Data("\n".utf8))
    }
}
