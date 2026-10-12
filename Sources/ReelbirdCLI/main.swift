import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let code = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(code)
