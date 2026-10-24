import 'package:flutter/widgets.dart';

/// Logical viewport sizes, independent of Android/Linux or device branding.
bool isHandheldViewport(Size size) =>
    size.width >= 600 && size.width <= 1440 && size.height >= 360 && size.height <= 900 && size.aspectRatio >= 1.35;

double handheldPosterSize(Size size) => size.height < 600 ? 240 : 280;
