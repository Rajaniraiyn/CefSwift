// The executable of every helper process: renderer, GPU and utility.
// `swift package cef bundle` builds it and copies it into each helper app.
import CefRenderer
import Darwin

exit(CefHelper.run())
