/// The video ranges advertised for browser-managed playback.
///
/// Codec support alone does not establish HDR output through the browser,
/// compositor and display. Until that path is verified, advertise SDR only.
/// This is a server negotiation constraint, not evidence that an incoming
/// source or a server-transcoded response has actually become SDR.
const webAdvertisedVideoRangeTypes = 'SDR';
