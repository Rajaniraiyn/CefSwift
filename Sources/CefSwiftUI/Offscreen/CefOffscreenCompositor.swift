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
/// the layer shows another surface). A frame that finds none free is
/// dropped, and the compositor asks for a new one a refresh later.
///
/// Only what changed is copied. Each pool surface keeps the part that is
/// out of date: the damage of every frame since it was last written, which
/// Chromium reports with each frame (viz's `capture_update_rect`). A gap
/// in the frames' sequence numbers, or a new size, makes a surface wholly
/// out of date. The pool holds up to four surfaces of the frame's size,
/// and three above 32 MB each (a 5120×3200 frame is 64 MB).
@MainActor
final class CefOffscreenCompositor {
    /// The marker the owned surfaces carry, for tests.
    nonisolated static let ownedSurfaceKey = "CefSwiftOffscreenCopy"

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let maximumPoolSize = 4
    private static let maximumLargePoolSize = 3
    private static let largeSurfaceBytes = 32 << 20

    /// For SelfTest's `compositor` benchmark: copy whole frames, into up
    /// to four surfaces at any size, as an earlier design did.
    static var copiesWholeFrames = false

    private final class Buffer {
        let surface: IOSurfaceRef
        let texture: MTLTexture?
        /// The part of the surface older than the latest frame, in pixels.
        var stale: CGRect

        init(surface: IOSurfaceRef, texture: MTLTexture?, stale: CGRect) {
            self.surface = surface
            self.texture = texture
            self.stale = stale
        }
    }

    private var pool: [Buffer] = []
    /// The sequence number of the last frame seen.
    private var lastSequence: UInt64?
    /// Bytes copied, for tests and benchmarks.
    private(set) var copiedBytes = 0
    /// The surface last returned, which the layer shows.
    private(set) var presented: IOSurfaceRef?
    /// Asks Chromium for a new frame, after one was dropped.
    var requestFrame: (() -> Void)?
    private var frameRequest: Task<Void, Never>?

    /// Copies `source` into a surface of the pool and returns that surface,
    /// or `nil` if the frame is dropped. Call it during the paint callback
    /// and make the returned surface the layer's contents, with implicit
    /// animations off: a contents transition keeps the old surface in use.
    ///
    /// `damage` is the part of `source` that differs from the previous
    /// frame, in pixels; `sequence` the frame's number, when known.
    func copy(_ source: IOSurfaceRef, damage: CGRect? = nil, sequence: UInt64? = nil) -> IOSurfaceRef? {
        let width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source)
        let format = IOSurfaceGetPixelFormat(source)
        guard width > 0, height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        pool.removeAll {
            $0.surface !== presented && (IOSurfaceGetWidth($0.surface) != width
                || IOSurfaceGetHeight($0.surface) != height || IOSurfaceGetPixelFormat($0.surface) != format)
        }
        // What changed since each surface was written. Without a known
        // predecessor, everything did.
        let continuous = !Self.copiesWholeFrames && sequence != nil && lastSequence.map { sequence == $0 &+ 1 } == true
        let changed = continuous ? (damage ?? bounds).intersection(bounds) : bounds
        lastSequence = sequence
        for buffer in pool {
            let matches = IOSurfaceGetWidth(buffer.surface) == width && IOSurfaceGetHeight(buffer.surface) == height
            buffer.stale = matches ? buffer.stale.union(changed).intersection(bounds) : bounds
            if buffer.stale.isNull { buffer.stale = .zero }
        }
        guard let target = takeBuffer(width: width, height: height, format: format) else {
            scheduleFrameRequest()
            return nil
        }
        syncColorSpace(from: source, to: target.surface)
        let region = target.stale.integral.intersection(bounds)
        if !region.isEmpty {
            // Paint callbacks run inside CEF's message loop work, which an
            // idle run loop can repeat many times before AppKit drains its
            // pool; the Metal objects of each copy must not wait for that.
            let copied = autoreleasepool {
                target.texture.map { blit(source, into: $0, region: region) }
                    ?? copyOnCPU(source, into: target.surface, region: region)
            }
            guard copied else {
                target.stale = bounds
                return nil
            }
            copiedBytes += Int(region.width * region.height) * 4
        }
        target.stale = .zero
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
        lastSequence = nil
        pool = []
    }

    // MARK: Pool

    private func takeBuffer(width: Int, height: Int, format: OSType) -> Buffer? {
        if let free = pool.first(where: { $0.surface !== presented && !IOSurfaceIsInUse($0.surface) }) {
            return free
        }
        let limit = width * height * 4 > Self.largeSurfaceBytes && !Self.copiesWholeFrames
            ? Self.maximumLargePoolSize : Self.maximumPoolSize
        guard pool.count < limit,
              let surface = Self.makeSurface(width: width, height: height, format: format)
        else { return nil }
        let buffer = Buffer(
            surface: surface, texture: Self.makeTexture(surface, width: width, height: height, format: format),
            stale: CGRect(x: 0, y: 0, width: width, height: height))
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

    /// Copies `region` on the GPU and waits for the copy, so Chromium may
    /// reuse `source` once the paint callback returns.
    private func blit(_ source: IOSurfaceRef, into target: MTLTexture, region: CGRect) -> Bool {
        let width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source)
        guard let queue = Self.queue,
              let sourceTexture = Self.makeTexture(source, width: width, height: height, format: IOSurfaceGetPixelFormat(source)),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeBlitCommandEncoder()
        else { return false }
        let origin = MTLOrigin(x: Int(region.minX), y: Int(region.minY), z: 0)
        encoder.copy(
            from: sourceTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
            sourceSize: MTLSize(width: Int(region.width), height: Int(region.height), depth: 1),
            to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed
    }

    /// The fallback without Metal or for another pixel format: a row copy
    /// under both surfaces' locks.
    private func copyOnCPU(_ source: IOSurfaceRef, into target: IOSurfaceRef, region: CGRect) -> Bool {
        guard IOSurfaceGetBytesPerElement(source) == IOSurfaceGetBytesPerElement(target),
              IOSurfaceLock(source, .readOnly, nil) == kIOReturnSuccess
        else { return false }
        defer { IOSurfaceUnlock(source, .readOnly, nil) }
        guard IOSurfaceLock(target, [], nil) == kIOReturnSuccess else { return false }
        defer { IOSurfaceUnlock(target, [], nil) }
        let element = IOSurfaceGetBytesPerElement(source)
        let rowBytes = Int(region.width) * element, left = Int(region.minX) * element
        let sourceRow = IOSurfaceGetBytesPerRow(source), targetRow = IOSurfaceGetBytesPerRow(target)
        let from = IOSurfaceGetBaseAddress(source), to = IOSurfaceGetBaseAddress(target)
        for y in Int(region.minY)..<Int(region.maxY) {
            to.advanced(by: y * targetRow + left).copyMemory(from: from.advanced(by: y * sourceRow + left), byteCount: rowBytes)
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

