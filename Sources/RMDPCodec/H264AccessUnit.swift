import CoreMedia
import Foundation

/// One H.264 access unit in transport form: AVCC sample bytes (4-byte length-prefixed NALs)
/// plus the SPS/PPS a decoder needs to start from it. Bridges VideoToolbox's `CMSampleBuffer`
/// and the wire, in both directions.
public struct H264AccessUnit {
    public var isKeyframe: Bool
    /// SPS, PPS (only populated on keyframes).
    public var parameterSets: [Data]
    public var avccData: Data

    public init(isKeyframe: Bool, parameterSets: [Data], avccData: Data) {
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.avccData = avccData
    }

    /// Extract from an encoder output sample.
    public init?(sampleBuffer sb: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, (first[kCMSampleAttachmentKey_NotSync] as? Bool) == true {
            isKey = false
        }
        var sets: [Data] = []
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                              parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                              nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        }
        let len = CMBlockBufferGetDataLength(block)
        var data = Data(count: len)
        let st = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        self.init(isKeyframe: isKey, parameterSets: sets, avccData: data)
    }

    /// Build a format description from SPS/PPS.
    public static func formatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let datas = parameterSets.map { NSData(data: $0) }
        let ptrs = datas.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = datas.map { $0.length }
        var fmt: CMVideoFormatDescription?
        let st = ptrs.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: datas.count,
                    parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        return st == noErr ? fmt : nil
    }

    /// Wrap as a decodable sample buffer against `format`.
    public func sampleBuffer(format: CMVideoFormatDescription, pts: CMTime = .invalid) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let len = avccData.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = avccData.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = len
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr
        else { return nil }
        return sb
    }
}
