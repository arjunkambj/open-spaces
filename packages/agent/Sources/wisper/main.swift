import Foundation
import WisperAgent
import WisperStore

// The `wisper` command-line tool. Everything it does lives in WisperAgent;
// this file only connects it to the files on disk and the real terminal.

// One data folder for everything: the library reads and writes it, and the tickets that
// let the app trust a request to start or stop recording are left in it.
let environment = WisperAgent.Environment.live()
let agent = WisperAgent(library: FileLibrary(root: environment.dataFolder), environment: environment)
exit(await agent.run(Array(CommandLine.arguments.dropFirst()), io: .standard()))
