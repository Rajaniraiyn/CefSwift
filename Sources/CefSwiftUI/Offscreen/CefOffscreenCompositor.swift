import CoreFoundation
import IOSurface
import Metal

/// Copies the frames Chromium paints into surfaces the view owns, for one
/// layer.
///
/// Chromium paints offscreen frames into a pool of `IOSurface`s and takes
/// a surface back once `on_accelerated_paint` returns: the pool
/// (`RenderableMappableSharedImageVideoFramePool` behind viz's
/// `FrameSinkVideoCapturerImpl`, Chromium 156) hands returned surfaces out
/// again in order, without checking whether a window server still shows
/// them. A layer whose contents were Chromium's surface would show later
/// frames being drawn into it.
///
/// So each frame is copied, on the GPU with a Metal blit, into a surface
/// of a small pool the view owns, and the copy completes before the
/// callback returns. A pool surface is written only when it is not the
/// layer's contents and the window server no longer reads it
/// (`IOSurfaceIsInUse`, which turns false about one display refresh after
/// the layer shows another surface). The pool holds up to four surfaces of
/// the frame's size; a frame that finds none free is dropped, and the
/// compositor asks for a new one a refresh later.
@MainActor
final class CefOffscreenCompositor {
    /// The marker the owned surfaces carry, for tests.
    nonisolated static let ownedSurfaceKey = "CefSwiftOffscreenCopy"

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let maximumPoolSize = 4

    private struct Buffer {
        let surface: IOSurfaceRef
        let texture: MTLTexture?
    }

    private var pool: [Buffer] = []
    /// The surface last returned, which the layer shows.
    private(set) var presented: IOSurfaceRef?
    /// Asks Chromium for a new frame, after one was dropped.
    var requestFrame: (() -> Void)?
    private var frameRequest: Task<Void, Never>?

    /// Copies `source` into a surface of the pool and returns that surface,
    /// or `nil` if the frame is dropped. Call it during the paint callback
    /// and make the returned surface the layer's contents, with implicit
    /// animations off: a contents transition keeps the old surface in use.
    func copy(_ source: IOSurfaceRef) -> IOSurfaceRef? {
        let width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source)
        let format = IOSurfaceGetPixelFormat(source)
        guard width > 0, height > 0 else { return nil }
        pool.removeAll {
            $0.surface !== presented && (IOSurfaceGetWidth($0.surface) != width
                || IOSurfaceGetHeight($0.surface) != height || IOSurfaceGetPixelFormat($0.surface) != format)
        }
        guard let target = takeBuffer(width: width, height: height, format: format) else {
            scheduleFrameRequest()
            return nil
        }
        syncColorSpace(from: source, to: target.surface)
        // Paint callbacks run inside CEF's message loop work, which an idle
        // run loop can repeat many times before AppKit drains its pool;
        // the Metal objects of each copy must not wait for that.
        let copied = autoreleasepool {
            target.texture.map { blit(source, into: $0, width: width, height: height) }
                ?? copyOnCPU(source, into: target.surface)
        }
        guard copied else { return nil }
        presented = target.surface
        return target.surface
    }

    /// Releases every surface but the one shown, as when the view stops
    /// being seen.
    func trim() {
        pool.removeAll { $0.surface !== presented }
    }

    /// Forgets every surface, after the layer's contents were cleared.
    func reset() {
        presented = nil
        pool = []
    }

    // MARK: Pool

    private func takeBuffer(width: Int, height: Int, format: OSType) -> Buffer? {
        if let free = pool.first(where: { $0.surface !== presented && !IOSurfaceIsInUse($0.surface) }) {
            return free
        }
        guard pool.count < Self.maximumPoolSize,
              let surface = Self.makeSurface(width: width, height: height, format: format)
        else { return nil }
        let buffer = Buffer(surface: surface, texture: Self.makeTexture(surface, width: width, height: height, format: format))
        pool.append(buffer)
        return buffer
    }

    /// Asks for a frame a display refresh after one was dropped, by when a
    /// surface is free again.
    private func scheduleFrameRequest() {
        guard frameRequest == nil else { return }
        frameRequest = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(17))
            guard let self else { return }
            frameRequest = nil
            requestFrame?()
        }
    }

    private static func makeSurface(width: Int, height: Int, format: OSType) -> IOSurfaceRef? {
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * height,
            kIOSurfacePixelFormat: format,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        IOSurfaceSetValue(surface, ownedSurfaceKey as CFString, kCFBooleanTrue)
        return surface
    }

    private static func makeTexture(_ surface: IOSurfaceRef, width: Int, height: Int, format: OSType) -> MTLTexture? {
        guard let device, let pixelFormat = metalPixelFormat(format) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    /// Chromium's offscreen frames are BGRA (`PIXEL_FORMAT_ARGB`) or RGBA.
    private static func metalPixelFormat(_ format: OSType) -> MTLPixelFormat? {
        switch format {
        case 0x4247_5241: .bgra8Unorm // 'BGRA'
        case 0x5247_4241: .rgba8Unorm // 'RGBA'
        default: nil
        }
    }

    // MARK: Copying

    /// Copies on the GPU and waits for the copy, so Chromium may reuse
    /// `source` once the paint callback returns.
    private func blit(_ source: IOSurfaceRef, into target: MTLTexture, width: Int, height: Int) -> Bool {
        guard let queue = Self.queue,
              let sourceTexture = Self.makeTexture(source, width: width, height: height, format: IOSurfaceGetPixelFormat(source)),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeBlitCommandEncoder()
        else { return false }
        encoder.copy(
            from: sourceTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }

    /// The fallback without Metal or for another pixel format: a row copy
    /// under both surfaces' locks.
    private func copyOnCPU(_ source: IOSurfaceRef, into target: IOSurfaceRef) -> Bool {
        guard IOSurfaceGetBytesPerElement(source) == IOSurfaceGetBytesPerElement(target),
              IOSurfaceLock(source, .readOnly, nil) == kIOReturnSuccess
        else { return false }
        defer { IOSurfaceUnlock(source, .readOnly, nil) }
        guard IOSurfaceLock(target, [], nil) == kIOReturnSuccess else { return false }
        defer { IOSurfaceUnlock(target, [], nil) }
        let rowBytes = IOSurfaceGetWidth(source) * IOSurfaceGetBytesPerElement(source)
        let sourceRow = IOSurfaceGetBytesPerRow(source), targetRow = IOSurfaceGetBytesPerRow(target)
        let from = IOSurfaceGetBaseAddress(source), to = IOSurfaceGetBaseAddress(target)
        for y in 0..<IOSurfaceGetHeight(source) {
            to.advanced(by: y * targetRow).copyMemory(from: from.advanced(by: y * sourceRow), byteCount: rowBytes)
        }
        return true
    }

    /// Gives the copy the colour space Chromium tagged its surface with,
    /// which Core Animation reads.
    private func syncColorSpace(from source: IOSurfaceRef, to target: IOSurfaceRef) {
        let key = kIOSurfaceColorSpace
        let wanted = IOSurfaceCopyValue(source, key)
        let current = IOSurfaceCopyValue(target, key)
        switch (wanted, current) {
        case (nil, nil): return
        case let (wanted?, current?) where CFEqual(wanted, current): return
        case let (wanted?, _): IOSurfaceSetValue(target, key, wanted)
        case (nil, _): IOSurfaceRemoveValue(target, key)
        }
    }
}

