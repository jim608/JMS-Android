@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/widgets/full_screen_helpers/full_screen_helper_web.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

@JS('Object.defineProperty')
external JSObject _defineProperty(JSObject object, JSString name, JSObject descriptor);

@JS('Reflect.deleteProperty')
external bool _deleteProperty(JSObject object, JSString name);

@JS('Promise.reject')
external JSPromise<JSAny?> _reject(JSAny? reason);

void _property(JSObject object, String name, JSAny? value) {
  final descriptor = JSObject()
    ..['value'] = value
    ..['configurable'] = true.toJS;
  _defineProperty(object, name.toJS, descriptor);
  addTearDown(() => _deleteProperty(object, name.toJS));
}

Future<(WidgetRef, ProviderContainer)> _mount(WidgetTester tester) async {
  final container = ProviderContainer(overrides: [
    mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(fullScreen: true)),
  ]);
  addTearDown(container.dispose);
  late WidgetRef widgetRef;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: Consumer(builder: (context, ref, child) {
      widgetRef = ref;
      return const SizedBox.shrink();
    })),
  ));
  return (widgetRef, container);
}

void main() {
  testWidgets('unsupported document fullscreen leaves inline playback usable', (tester) async {
    final (ref, container) = await _mount(tester);
    _property(web.document, 'fullscreenElement', null);
    _property(web.document, 'fullscreenEnabled', false.toJS);
    var requests = 0;
    _property(
        web.document.documentElement!,
        'requestFullscreen',
        (() {
          requests++;
          return Future<JSAny?>.value(null).toJS;
        }).toJS);
    await tester.runAsync(() => FullScreenHelper.instantiate().toggleFullScreen(ref));
    expect(requests, 0);
    expect(container.read(mediaPlaybackProvider).fullScreen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected fullscreen request is contained and state follows DOM', (tester) async {
    final (ref, container) = await _mount(tester);
    _property(web.document, 'fullscreenElement', null);
    _property(web.document, 'fullscreenEnabled', true.toJS);
    _property(web.document.documentElement!, 'requestFullscreen', (() => _reject('denied by fixture'.toJS)).toJS);
    await tester.runAsync(() => FullScreenHelper.instantiate().toggleFullScreen(ref));
    expect(container.read(mediaPlaybackProvider).fullScreen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen exit waits for its promise and does not read a disposed widget ref', (tester) async {
    final (ref, _) = await _mount(tester);
    _property(web.document, 'fullscreenElement', web.document.documentElement);
    final exit = Completer<JSAny?>();
    _property(web.document, 'exitFullscreen', (() => exit.future.toJS).toJS);
    final action = await tester.runAsync(() async => (FullScreenHelper.instantiate().closeFullScreen(ref),));
    final pending = action!.$1;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      exit.complete(null);
      await pending;
    });
    expect(tester.takeException(), isNull);
  });
}
