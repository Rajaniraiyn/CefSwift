import CefBundling
import Foundation

exit(CefTool.main(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment))
