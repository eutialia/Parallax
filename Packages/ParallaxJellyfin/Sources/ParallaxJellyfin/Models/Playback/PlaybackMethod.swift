import Foundation

// `resolve()` (PlaybackInfoService.swift) branches solely on whether the
// server returned a transcodingURL, so it can only ever produce directPlay
// or transcode: the server stream-copies eligible sources through the HLS
// transcode profile but always reports PlayMethod.Transcode for that job
// (StreamBuilder.cs:803 overwrites it before the response is built), and
// MediaSourceInfo.transcodeReasons is [JsonIgnore]'d, so PlaybackInfo carries
// no client-visible copy-vs-reencode signal. `.directStream` was therefore
// unreachable and is deleted per the repo's delete-over-deprecate rule.
public enum PlaybackMethod: Sendable, Hashable {
    case directPlay
    case transcode
}
