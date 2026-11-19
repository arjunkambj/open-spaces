import Foundation
import WisperAgent
import WisperStore

// The `wisper` command-line tool. Everything it does lives in WisperAgent;
// this file only connects it to the files on disk and the real terminal.

let agent = WisperAgent(library: FileLibrary())
exit(await agent.run(Array(CommandLine.arguments.dropFirst()), io: .standard()))
