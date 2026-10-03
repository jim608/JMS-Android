const ambientDefaultIntervalSeconds = 4.0;
const ambientMinimumIntervalSeconds = 0.001;
const ambientMaximumIntervalSeconds = 60.0;
const ambientDefaultInterval = Duration(seconds: 4);

double boundedAmbientIntervalSeconds(double value) => value.isFinite && value > 0
    ? value.clamp(ambientMinimumIntervalSeconds, ambientMaximumIntervalSeconds)
    : ambientDefaultIntervalSeconds;

Duration ambientIntervalDuration(double seconds) =>
    Duration(milliseconds: (boundedAmbientIntervalSeconds(seconds) * 1000).round());
