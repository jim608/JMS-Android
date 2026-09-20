import 'dart:math' as math;
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:fladder/widgets/shared/ambient_geometry.dart';

enum AmbientComposition { direct, previous, legacy }

class AmbientBlurDiagnostics {
  bool _enabled = false;
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (!value) clearPreview();
  }

  final preview = ValueNotifier<AmbientSamplePreview?>(null);
  DateTime? capturedAt;
  String source = 'unknown';
  String sampleStatus = 'not sampled';
  String contentChange = 'unknown';
  int? _lastSignature;
  bool inspecting = false;
  double backgroundFraction = 0;
  Rect? videoRect;
  Size? viewport;

  void clearPreview() {
    if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => clearPreview());
      return;
    }
    final previous = preview.value;
    preview.value = null;
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.image.dispose());
    }
  }

  Future<void> inspect(ui.Image image, Rect crop, bool Function() valid) async {
    if (!enabled || inspecting) return;
    inspecting = true;
    final ownedImage = image.clone();
    final sampledAt = DateTime.now();
    var published = false;
    try {
      final bytes = await ownedImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (!enabled || !valid() || bytes == null) return;
      var totalAlpha = 0;
      var brightest = 0;
      var signature = 0;
      var count = 0;
      final step = math.max(1, (math.sqrt(crop.width * crop.height / 1024)).ceil());
      for (var vertical = crop.top.ceil(); vertical < crop.bottom.floor(); vertical += step) {
        for (var horizontal = crop.left.ceil(); horizontal < crop.right.floor(); horizontal += step) {
          final offset = (vertical * ownedImage.width + horizontal) * 4;
          final red = bytes.getUint8(offset);
          final green = bytes.getUint8(offset + 1);
          final blue = bytes.getUint8(offset + 2);
          final alpha = bytes.getUint8(offset + 3);
          totalAlpha += alpha;
          brightest = math.max(brightest, math.max(red, math.max(green, blue)));
          signature = (signature * 31 + red + green * 256 + blue * 65536 + alpha) & 0x7fffffff;
          count++;
        }
      }
      sampleStatus = count == 0
          ? 'empty crop'
          : totalAlpha < count * 8
              ? 'transparent / no visible pixels'
              : brightest < 12
                  ? 'dark / black (not automatically a capture failure)'
                  : 'visible color';
      contentChange = _lastSignature == null
          ? 'first sample'
          : _lastSignature == signature
              ? 'unchanged (may be a static scene)'
              : 'changed';
      _lastSignature = signature;
      final previous = preview.value;
      preview.value = AmbientSamplePreview(ownedImage, crop, sampledAt);
      published = true;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.image.dispose());
      }
    } catch (_) {
      if (enabled && valid()) sampleStatus = 'preview unavailable';
    } finally {
      if (!published) ownedImage.dispose();
      inspecting = false;
    }
  }

  bool running = false;
  bool inFlight = false;
  int captures = 0;
  int failures = 0;
  int allocated = 0;
  int released = 0;
  int retainedBytes = 0;
  int peakImageBytes = 0;
  int? captureMicros;
  int? blurMicros;
  String size = 'unknown';
}

class AmbientSamplePreview {
  final ui.Image image;
  final Rect crop;
  final DateTime capturedAt;
  const AmbientSamplePreview(this.image, this.crop, this.capturedAt);
}

class AmbientBlur extends StatefulWidget {
  final Widget child;
  final double sigmaX;
  final double sigmaY;
  final Duration duration;
  final double downscaleFactor;
  final double maxCaptureDimension;
  final double opacity;
  final double spread;
  final Color vignetteColor;
  final bool enabled;
  final bool playing;
  final AmbientComposition composition;
  final AmbientBlurDiagnostics? diagnostics;

  final double vignetteCornerRadius;
  final double vignetteFeather;
  final double vignetteMargin;

  const AmbientBlur({
    super.key,
    required this.child,
    this.sigmaX = 64.0,
    this.sigmaY = 64.0,
    this.duration = const Duration(seconds: 4),
    this.downscaleFactor = 4.0,
    this.maxCaptureDimension = 192.0,
    this.opacity = 0.80,
    this.spread = 0.90,
    this.vignetteColor = Colors.black,
    this.vignetteCornerRadius = 64.0,
    this.vignetteFeather = 128,
    this.vignetteMargin = 0,
    this.enabled = true,
    this.playing = true,
    this.composition = AmbientComposition.direct,
    this.diagnostics,
  })  : assert(downscaleFactor > 0),
        assert(maxCaptureDimension > 0),
        assert(opacity >= 0 && opacity <= 1),
        assert(spread >= 0 && spread <= 1);

  @override
  State<AmbientBlur> createState() => _AmbientBlurState();
}

class _AmbientBlurState extends State<AmbientBlur> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _blendController;
  final GlobalKey _boundaryKey = GlobalKey();

  ui.Image? _oldImage;
  ui.Image? _currentImage;
  bool _isCapturing = false;

  bool _active = true;
  int _generation = 0;
  Rect? _videoRect;
  Size? _viewport;
  bool get _running => mounted && _active && widget.enabled && widget.playing;

  void _disposeImage(ui.Image? image) {
    if (image == null) return;
    image.dispose();
    widget.diagnostics?.released++;
  }

  void _releaseFrames() {
    final images = {_oldImage, _currentImage}.nonNulls.toList();
    _oldImage = null;
    _currentImage = null;
    widget.diagnostics?.retainedBytes = 0;
    widget.diagnostics?.clearPreview();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in images) {
        _disposeImage(image);
      }
    });
  }

  void _updateActivity({bool release = false}) {
    _generation++;
    widget.diagnostics?.running = _running;
    _blendController.stop();
    if (release) _releaseFrames();
    if (_running) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _captureAndBlur());
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _blendController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _blendController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _captureAndBlur();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _captureAndBlur());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    setState(() => _updateActivity(release: !_active));
  }

  @override
  void didUpdateWidget(covariant AmbientBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.playing != widget.playing ||
        oldWidget.composition != widget.composition) {
      _updateActivity(release: !widget.enabled || oldWidget.composition != widget.composition);
    }
    if (oldWidget.duration != widget.duration) {
      _blendController.duration = widget.duration;
      if (_blendController.isAnimating) {
        _blendController.forward(from: _blendController.value);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _blendController.dispose();
    for (final image in {_oldImage, _currentImage}.nonNulls) {
      _disposeImage(image);
    }
    widget.diagnostics?.running = false;
    widget.diagnostics?.retainedBytes = 0;
    widget.diagnostics?.clearPreview();
    super.dispose();
  }

  Future<void> _captureAndBlur() async {
    if (!_running || _isCapturing) return;
    _isCapturing = true;
    final diagnostics = widget.diagnostics;
    diagnostics?.running = true;
    diagnostics?.inFlight = true;
    final stopwatch = diagnostics?.enabled == true ? (Stopwatch()..start()) : null;
    final timeline = diagnostics?.enabled == true ? (developer.TimelineTask()..start('JMS ambient capture')) : null;
    final generation = _generation;

    ui.Image? unblurredImage;
    ui.Image? blurredImage;
    ui.Picture? picture;

    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize) return;

      final pixelRatio = MediaQuery.of(context).devicePixelRatio;
      if (boundary.size.isEmpty) return;
      final visibleVideo = ambientVideoRect(boundary);
      final videoRect = visibleVideo ?? Offset.zero & boundary.size;
      final viewport = boundary.size;
      if (diagnostics != null) {
        diagnostics.source = visibleVideo == null ? 'boundary (texture not identified)' : 'visible video texture';
        diagnostics.videoRect = videoRect;
        diagnostics.viewport = viewport;
        diagnostics.backgroundFraction =
            visibleVideo == null ? -1 : 1 - videoRect.width * videoRect.height / (viewport.width * viewport.height);
      }
      final renderScale = math.min(
        pixelRatio / widget.downscaleFactor,
        widget.maxCaptureDimension / boundary.size.longestSide,
      );

      unblurredImage = await boundary.toImage(pixelRatio: renderScale);
      diagnostics?.allocated++;
      diagnostics?.captureMicros = stopwatch?.elapsedMicroseconds;
      timeline?.instant('capture complete');
      stopwatch?.reset();
      if (!_running || generation != _generation) return;
      final rawBounds = Rect.fromLTWH(0, 0, unblurredImage.width.toDouble(), unblurredImage.height.toDouble());
      final contentCrop = Rect.fromLTRB(videoRect.left * renderScale, videoRect.top * renderScale,
              videoRect.right * renderScale, videoRect.bottom * renderScale)
          .intersect(rawBounds);
      final crop = widget.composition == AmbientComposition.direct ? contentCrop : rawBounds;
      final width = crop.width.ceil().clamp(1, unblurredImage.width);
      final height = crop.height.ceil().clamp(1, unblurredImage.height);

      final scaledSigmaX = widget.sigmaX * renderScale;
      final scaledSigmaY = widget.sigmaY * renderScale;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: scaledSigmaX,
          sigmaY: scaledSigmaY,
          tileMode: ui.TileMode.clamp,
        );

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
      canvas.drawImageRect(unblurredImage, crop, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), paint);
      canvas.restore();
      picture = recorder.endRecording();

      blurredImage = await picture.toImage(
        width,
        height,
      );
      diagnostics?.allocated++;
      if (diagnostics != null) {
        diagnostics.blurMicros = stopwatch?.elapsedMicroseconds;
        diagnostics.size = '${blurredImage.width} × ${blurredImage.height}';
        diagnostics.peakImageBytes = math.max(
          diagnostics.peakImageBytes,
          diagnostics.retainedBytes + unblurredImage.width * unblurredImage.height * 8,
        );
      }

      if (!_running || generation != _generation) return;

      setState(() {
        final oldToDispose = _oldImage;

        _oldImage = _currentImage;
        _currentImage = blurredImage;
        _videoRect = visibleVideo;
        _viewport = viewport;

        if (oldToDispose != null && oldToDispose != _oldImage && oldToDispose != _currentImage) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _disposeImage(oldToDispose);
          });
        }
      });
      diagnostics?.captures++;
      diagnostics?.capturedAt = DateTime.now();
      diagnostics?.retainedBytes =
          {_oldImage, _currentImage}.nonNulls.fold<int>(0, (total, image) => total + image.width * image.height * 4);
      blurredImage = null;
      if (diagnostics?.enabled == true) {
        unawaited(diagnostics!.inspect(unblurredImage, contentCrop, () => _running && generation == _generation));
      }
    } catch (_) {
      diagnostics?.failures++;
    } finally {
      timeline?.finish();
      stopwatch?.stop();
      picture?.dispose();
      _disposeImage(blurredImage);
      _disposeImage(unblurredImage);
      _isCapturing = false;
      diagnostics?.inFlight = false;
      if (_running) _blendController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReady = widget.enabled && _currentImage != null;

    return Stack(
      alignment: Alignment.center,
      children: [
        if (isReady && widget.composition != AmbientComposition.legacy)
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: AmbientFramePainter(
                  oldImage: _oldImage,
                  image: _currentImage!,
                  blend: _blendController,
                  opacity: widget.composition == AmbientComposition.previous ? 0.5 : widget.opacity,
                  spread: widget.spread,
                  videoRect: widget.composition == AmbientComposition.direct ? _videoRect : null,
                  viewport: _viewport,
                  vignetteColor: widget.vignetteColor,
                ),
              ),
            ),
          ),
        if (isReady && widget.composition == AmbientComposition.legacy)
          Positioned.fill(
            child: Opacity(
              opacity: 0.5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_oldImage != null)
                    RawImage(
                      image: _oldImage,
                      fit: BoxFit.fill,
                    ),
                  if (_currentImage != null)
                    FadeTransition(
                      opacity: _oldImage == null ? const AlwaysStoppedAnimation(1.0) : _blendController,
                      child: RawImage(
                        image: _currentImage,
                        fit: BoxFit.fill,
                      ),
                    ),
                  if (widget.vignetteColor.a > 0)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _RoundedRectVignettePainter(
                            color: widget.vignetteColor.withAlpha(125),
                            cornerRadius: widget.vignetteCornerRadius,
                            feather: widget.vignetteFeather,
                            margin: widget.vignetteMargin,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        RepaintBoundary(key: _boundaryKey, child: widget.child),
      ],
    );
  }
}

class AmbientFramePainter extends CustomPainter {
  final ui.Image? oldImage;
  final ui.Image image;
  final Animation<double> blend;
  final double opacity;
  final Color vignetteColor;
  final double spread;
  final Rect? videoRect;
  final Size? viewport;

  AmbientFramePainter({
    required this.oldImage,
    required this.image,
    required this.blend,
    required this.opacity,
    required this.vignetteColor,
    this.spread = 0.9,
    this.videoRect,
    this.viewport,
  }) : super(repaint: blend);

  @override
  void paint(Canvas canvas, Size size) {
    final fullBounds = Offset.zero & size;
    final sourceViewport = viewport ?? size;
    final video = videoRect == null
        ? null
        : Rect.fromLTRB(
            videoRect!.left * size.width / sourceViewport.width,
            videoRect!.top * size.height / sourceViewport.height,
            videoRect!.right * size.width / sourceViewport.width,
            videoRect!.bottom * size.height / sourceViewport.height);
    if (video != null && (video.contains(Offset.zero) && video.bottomRight == size.bottomRight(Offset.zero))) return;
    final destination = video == null ? fullBounds : ambientExtent(video, size, spread);
    canvas.save();
    if (video != null) canvas.clipRect(video, clipOp: ui.ClipOp.difference, doAntiAlias: false);
    final progress = oldImage == null ? 1.0 : blend.value;
    final currentAlpha = opacity * progress;
    final oldAlpha = currentAlpha == 1 ? 0.0 : opacity * (1 - progress) / (1 - currentAlpha);
    void draw(ui.Image frame, double alpha) {
      canvas.drawImageRect(
        frame,
        Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
        destination,
        Paint()
          ..color = Colors.white.withValues(alpha: alpha)
          ..filterQuality = FilterQuality.low,
      );
    }

    if (oldImage != null) draw(oldImage!, oldAlpha);
    draw(image, currentAlpha);
    if (video != null) {
      void fade(Rect rect, Alignment start, Alignment end) {
        if (rect.isEmpty) return;
        canvas.drawRect(
            rect.inflate(1),
            Paint()
              ..shader = LinearGradient(
                begin: start,
                end: end,
                colors: [Colors.black, Colors.transparent],
              ).createShader(rect));
      }

      fade(Rect.fromLTRB(destination.left, destination.top, destination.right, video.top), Alignment.topCenter,
          Alignment.bottomCenter);
      fade(Rect.fromLTRB(destination.left, video.bottom, destination.right, destination.bottom), Alignment.bottomCenter,
          Alignment.topCenter);
      fade(Rect.fromLTRB(destination.left, destination.top, video.left, destination.bottom), Alignment.centerLeft,
          Alignment.centerRight);
      fade(Rect.fromLTRB(video.right, destination.top, destination.right, destination.bottom), Alignment.centerRight,
          Alignment.centerLeft);
    } else if (vignetteColor.a > 0) {
      canvas.drawRect(
        destination,
        Paint()
          ..shader = RadialGradient(
            colors: [vignetteColor.withValues(alpha: 0), vignetteColor.withValues(alpha: opacity * 0.49)],
            stops: const [0.45, 1],
            radius: 0.9,
          ).createShader(destination),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AmbientFramePainter oldDelegate) =>
      oldDelegate.oldImage != oldImage ||
      oldDelegate.image != image ||
      oldDelegate.opacity != opacity ||
      oldDelegate.spread != spread ||
      oldDelegate.videoRect != videoRect ||
      oldDelegate.viewport != viewport ||
      oldDelegate.vignetteColor != vignetteColor;
}

class _RoundedRectVignettePainter extends CustomPainter {
  final Color color;
  final double cornerRadius;
  final double feather;
  final double margin;

  _RoundedRectVignettePainter({
    required this.color,
    required this.cornerRadius,
    required this.feather,
    required this.margin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();

    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    if (feather > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, feather);
    }

    final insetRect = Rect.fromLTWH(
      margin + feather,
      margin + feather,
      size.width - 2 * (margin + feather),
      size.height - 2 * (margin + feather),
    );

    if (insetRect.width > 0 && insetRect.height > 0) {
      final safeRRect = RRect.fromRectAndRadius(
        insetRect,
        Radius.circular(cornerRadius),
      );

      final outerRect = Rect.fromLTWH(0, 0, size.width, size.height).inflate(feather * 3);
      final outerRRect = RRect.fromRectAndRadius(outerRect, Radius.zero);

      canvas.drawDRRect(outerRRect, safeRRect, paint);
    } else {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RoundedRectVignettePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.cornerRadius != cornerRadius ||
        oldDelegate.feather != feather ||
        oldDelegate.margin != margin;
  }
}
