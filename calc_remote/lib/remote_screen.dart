import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'remote_client.dart';
import 'dart:ui' as ui;

class RemoteScreen extends StatefulWidget {
  final String host;
  final int port;
  const RemoteScreen({super.key, required this.host, required this.port});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final _client = RemoteClient();

  final GlobalKey _viewportKey = GlobalKey();

  ui.Image? _canvasImage;
  int _canvasWidth = 0;
  int _canvasHeight = 0;
  final List<FramePatch> _patchQueue = [];
  bool _processingQueue = false;
  String? _statusMessage;

  final _keyboardController = TextEditingController();
  final _keyboardFocus = FocusNode();
  String _lastKeyboardValue = '';

  // ---- Pointer/gesture state -----------------------------------------
  // We use a raw Listener instead of a GestureDetector with combined
  // Tap+DoubleTap+Pan+LongPress recognizers. Combining all of those on one
  // detector puts them in the same gesture arena and causes the tap
  // recognizer to get starved by natural finger jitter while Flutter holds
  // it open waiting to see if a double-tap follows. Doing it by hand gives
  // us deterministic, jitter-tolerant behavior.
  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;
  bool _isDragging = false;
  bool _longPressFired = false;
  Timer? _longPressTimer;
  Timer? _tapTimer;
  Offset? _lastTapPosition;
  DateTime? _lastTapTime;

  // Net displacement (from the initial touch-down point, NOT summed path
  // length) that a finger must travel before we treat it as an intentional
  // drag rather than a stationary tap. Summed path length is the wrong
  // metric -- jitter during a "still" tap adds up fast even when the net
  // position barely moves, which is what was causing taps to get swallowed
  // and the cursor to drift on every tap.
  static const double _dragThreshold = 20.0;
  static const double _doubleTapSlop = 40.0;
  static const Duration _doubleTapTimeout = Duration(milliseconds: 300);
  static const Duration _longPressTimeout = Duration(milliseconds: 500);

  // Some touch panels / OEM touch-optimization layers (seen on Oplus/ColorOS
  // devices) report a single offset "jump" sample right at touch-down before
  // settling. Two guards against that:
  // 1) Ignore movement classification for a brief grace window right after
  //    down -- a real intentional drag is never that fast to start.
  // 2) Reject any single-frame delta that's implausibly large to be a real
  //    finger movement -- treat it as sensor noise, not a drag.
  static const Duration _moveGracePeriod = Duration(milliseconds: 40);
  static const double _spikeRejectDistance = 45.0;

  // Once a drag is confirmed we don't resend every single move sample --
  // only once the finger has moved a couple more logical pixels since the
  // last one we actually sent. Keeps the socket from getting flooded during
  // a long drag without affecting where the selection box ends up.
  static const double _dragUpdateMinDelta = 3.0;
  Offset? _lastDragSentPosition;

  // ---- Pinch-zoom state -------------------------------------------------
  // Every active finger currently on the glass, keyed by Flutter's pointer
  // id, in the *untransformed* viewport coordinate space (same space the
  // Listener reports raw touches in -- the zoom transform is applied only
  // to the visual child, never to input).
  final Map<int, Offset> _activePointers = {};

  // Which pointer id "owns" the current single-finger tap/drag gesture.
  // Only events from this id are processed as tap/drag; everything else is
  // either a second finger (pinch) or a leftover finger we're ignoring
  // until it's fully lifted.
  int? _singleFingerPointerId;

  // The two pointer ids currently driving a pinch, and the gesture's
  // reference values captured at the moment the second finger touched down.
  List<int>? _pinchPointerIds;
  double _pinchStartDistance = 1.0;
  double _pinchStartScale = 1.0;
  Offset _pinchContentAnchor = Offset.zero;

  // Current zoom transform applied to the mirrored desktop image.
  // _viewScale == 1.0 means "fit to the viewport" (the actual width of the
  // mobile viewport) -- per your ask, we never zoom out past that; 1.0 is
  // the floor, not just a starting point.
  double _viewScale = 1.0;
  Offset _viewOffset = Offset.zero;
  static const double _minZoomScale = 1.0;
  static const double _maxZoomScale = 4.0;

  @override
  void initState() {
    super.initState();
    _client.connect(widget.host, widget.port);

    _client.screenInfo.listen((info) {
      _canvasWidth = info.width;
      _canvasHeight = info.height;
      _initBlankCanvas();
    });
    _client.patches.listen((patch) {
      _patchQueue.add(patch);
      _drainQueue();
    });
    _client.status.listen((msg) {
      if (mounted) setState(() => _statusMessage = msg);
    });
    _client.textInputFocus.listen((active) {
      if (active) {
        _openKeyboard();
      } else {
        _keyboardFocus.unfocus();
      }
    });
  }

  @override
  void dispose() {
    _client.dispose();
    _keyboardController.dispose();
    _keyboardFocus.dispose();
    _longPressTimer?.cancel();
    _tapTimer?.cancel();
    _canvasImage?.dispose();
    super.dispose();
  }

  void _sendAbsoluteClick(Offset localPosition, {String button = 'left', bool doubleTap = false}) {
    final percent = _percentFor(localPosition);
    if (percent == null) return;
    print('[TAP] x=${percent.dx} y=${percent.dy} doubleTap=$doubleTap'); // TEMP DEBUG
    if (doubleTap) {
      _client.mouseDoubleClickAt(percent.dx, percent.dy, button: button);
    } else {
      _client.mouseClickAt(percent.dx, percent.dy, button: button);
    }
  }

  /// Converts a raw local point in the viewport (untransformed touch
  /// coordinates) into the 0..1 normalized coordinates the desktop side
  /// expects. Accounts for the current zoom/pan so taps and drags land on
  /// the correct desktop pixel even while zoomed in.
  Offset? _percentFor(Offset localPosition) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    // Undo the visual zoom transform to get back to the coordinate space
    // of the full (unzoomed) mirrored screen.
    final contentLocal = (localPosition - _viewOffset) / _viewScale;
    final xPercent = (contentLocal.dx / box.size.width).clamp(0.0, 1.0);
    final yPercent = (contentLocal.dy / box.size.height).clamp(0.0, 1.0);
    return Offset(xPercent, yPercent);
  }

  /// Starts a real click-and-drag on the desktop: move the desktop cursor to
  /// exactly where the finger went down, then press the button. Everything
  /// under this point onward behaves exactly like a physical mouse
  /// click-drag -- e.g. dragging a selection box over files/icons.
  void _beginDragSelection(Offset downPosition) {
    final percent = _percentFor(downPosition);
    if (percent == null) return;
    _client.mouseMove(percent.dx, percent.dy);
    _client.mouseDown(button: 'left');
    _lastDragSentPosition = downPosition;
  }

  /// Follows the finger while the button stays down, throttled slightly so
  /// we're not sending a message for every single touch sample.
  void _updateDragSelection(Offset currentPosition) {
    if (_lastDragSentPosition != null &&
        (currentPosition - _lastDragSentPosition!).distance < _dragUpdateMinDelta) {
      return;
    }
    final percent = _percentFor(currentPosition);
    if (percent == null) return;
    _client.mouseMove(percent.dx, percent.dy);
    _lastDragSentPosition = currentPosition;
  }

  /// Releases the button at the finger's final position, completing the
  /// drag/selection.
  void _endDragSelection(Offset upPosition) {
    final percent = _percentFor(upPosition);
    if (percent != null) {
      _client.mouseMove(percent.dx, percent.dy);
    }
    _client.mouseUp(button: 'left');
    _lastDragSentPosition = null;
  }

  // ---- Pointer handlers ------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;

    if (_activePointers.length == 1) {
      _singleFingerPointerId = event.pointer;
      _pointerDownPosition = event.localPosition;
      _pointerDownTime = DateTime.now();
      _isDragging = false;
      _longPressFired = false;

      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPressTimeout, () {
        if (_pointerDownPosition == null || _isDragging) return;
        _longPressFired = true;
        _sendAbsoluteClick(_pointerDownPosition!, button: 'right');
      });
    } else if (_activePointers.length == 2) {
      // A second finger just landed -- this is a pinch-zoom gesture, not a
      // tap/drag/long-press. Cleanly cancel whatever the first finger was
      // in the middle of (releasing the mouse button if a drag was live).
      _cancelSingleFingerGesture();
      _startPinch();
    }
    // 3rd+ finger: ignored, doesn't affect pinch tracking.
  }

  void _cancelSingleFingerGesture() {
    _longPressTimer?.cancel();
    if (_isDragging) {
      _client.mouseUp(button: 'left');
    }
    _pointerDownPosition = null;
    _pointerDownTime = null;
    _isDragging = false;
    _longPressFired = false;
    _lastDragSentPosition = null;
    _singleFingerPointerId = null;
  }

  void _startPinch() {
    final ids = _activePointers.keys.take(2).toList();
    if (ids.length < 2) return;
    final p1 = _activePointers[ids[0]]!;
    final p2 = _activePointers[ids[1]]!;

    _pinchPointerIds = ids;
    _pinchStartDistance = (p1 - p2).distance.clamp(1.0, double.infinity);
    _pinchStartScale = _viewScale;

    final midpoint = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    // The content-space point currently under the fingers' midpoint -- we
    // keep this exact point anchored under the midpoint as scale changes,
    // which is what makes a pinch feel like it's zooming "into" your fingers
    // instead of the corner of the screen.
    _pinchContentAnchor = (midpoint - _viewOffset) / _viewScale;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointers.containsKey(event.pointer)) {
      _activePointers[event.pointer] = event.localPosition;
    }

    if (_pinchPointerIds != null) {
      _updatePinch();
      return;
    }

    // Ignore moves from any finger that isn't the one driving the current
    // single-finger gesture (e.g. a leftover finger after a pinch ended).
    if (event.pointer != _singleFingerPointerId) return;
    if (_pointerDownPosition == null || _longPressFired) return;

    // Reject single-frame spikes outright -- a real finger can't teleport
    // this far in one touch sample; this is panel/driver noise.
    if (event.delta.distance > _spikeRejectDistance) return;

    // During the grace window right after touch-down, don't let any
    // movement count toward drag detection -- this is exactly when
    // first-sample coordinate jump artifacts occur. We still forward the
    // motion below if we're already dragging (shouldn't happen this early),
    // but we won't use it to *start* a drag classification.
    final withinGracePeriod = _pointerDownTime != null &&
        DateTime.now().difference(_pointerDownTime!) < _moveGracePeriod;

    // Net displacement from the down point -- NOT summed jitter distance.
    final netDisplacement = (event.localPosition - _pointerDownPosition!).distance;

    if (!_isDragging && !withinGracePeriod && netDisplacement > _dragThreshold) {
      _isDragging = true;
      _longPressTimer?.cancel();
      // Press down exactly where the finger originally landed, so the
      // selection box starts from the right spot rather than from wherever
      // the finger happens to be now.
      _beginDragSelection(_pointerDownPosition!);
    }

    if (_isDragging) {
      _updateDragSelection(event.localPosition);
    }
  }

  void _updatePinch() {
    final ids = _pinchPointerIds;
    if (ids == null) return;
    final p1 = _activePointers[ids[0]];
    final p2 = _activePointers[ids[1]];
    if (p1 == null || p2 == null) return; // one finger already lifted

    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final distance = (p1 - p2).distance.clamp(1.0, double.infinity);
    final scaleFactor = distance / _pinchStartDistance;
    final newScale = (_pinchStartScale * scaleFactor).clamp(_minZoomScale, _maxZoomScale);

    final midpoint = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    var newOffset = midpoint - _pinchContentAnchor * newScale;

    // Never let the zoomed content reveal empty space beyond its own edges.
    // At newScale == 1.0 this pins the offset to exactly (0, 0), which is
    // the "never zoom out past actual width" floor you asked for.
    final minOffsetX = box.size.width * (1 - newScale);
    final minOffsetY = box.size.height * (1 - newScale);
    newOffset = Offset(
      newOffset.dx.clamp(minOffsetX, 0.0),
      newOffset.dy.clamp(minOffsetY, 0.0),
    );

    setState(() {
      _viewScale = newScale;
      _viewOffset = newOffset;
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);

    if (_pinchPointerIds != null) {
      if (_pinchPointerIds!.contains(event.pointer) && _activePointers.length < 2) {
        // Pinch ends. If one finger is still down, we deliberately leave it
        // alone -- it never got tap/drag state set up, so it's inert until
        // it's lifted too. This avoids an accidental click right after a
        // pinch when the second finger comes off a beat before the first.
        _pinchPointerIds = null;
      }
      return;
    }

    if (event.pointer != _singleFingerPointerId) return;

    _longPressTimer?.cancel();

    final wasDragging = _isDragging;
    final wasLongPress = _longPressFired;
    final downPosition = _pointerDownPosition;

    _pointerDownPosition = null;
    _pointerDownTime = null;
    _isDragging = false;
    _longPressFired = false;
    _singleFingerPointerId = null;

    if (wasLongPress || downPosition == null) return;

    if (wasDragging) {
      _endDragSelection(event.localPosition);
      return;
    }

    final now = DateTime.now();
    if (_lastTapPosition != null &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!) < _doubleTapTimeout &&
        (downPosition - _lastTapPosition!).distance < _doubleTapSlop) {
      // This is the second tap of a double-tap -- fire it now and cancel
      // the single-click timer from the first tap.
      _tapTimer?.cancel();
      _lastTapPosition = null;
      _lastTapTime = null;
      _sendAbsoluteClick(downPosition, doubleTap: true);
      return;
    }

    // Might still become a double-tap -- hold briefly before committing.
    _lastTapPosition = downPosition;
    _lastTapTime = now;
    _tapTimer?.cancel();
    _tapTimer = Timer(_doubleTapTimeout, () {
      _sendAbsoluteClick(downPosition);
      _lastTapPosition = null;
      _lastTapTime = null;
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);

    if (_pinchPointerIds != null) {
      if (_pinchPointerIds!.contains(event.pointer) && _activePointers.length < 2) {
        _pinchPointerIds = null;
      }
      return;
    }

    if (event.pointer != _singleFingerPointerId) return;

    _longPressTimer?.cancel();
    // If the touch was interrupted mid-drag (e.g. an OS gesture stole the
    // pointer), release the button now -- otherwise the desktop is left
    // thinking the mouse button is permanently held down.
    if (_isDragging) {
      _client.mouseUp(button: 'left');
    }
    _pointerDownPosition = null;
    _pointerDownTime = null;
    _isDragging = false;
    _longPressFired = false;
    _lastDragSentPosition = null;
    _singleFingerPointerId = null;
  }

  // -----------------------------------------------------------------------


  void _openKeyboard() {
    _keyboardController.text = '';
    _lastKeyboardValue = '';
    FocusScope.of(context).requestFocus(_keyboardFocus);
  }

  void _onKeyboardChanged(String value) {
    // Diff against the previous value so backspaces map correctly.
    if (value.length > _lastKeyboardValue.length && value.startsWith(_lastKeyboardValue)) {
      _client.typeText(value.substring(_lastKeyboardValue.length));
    } else if (value.length < _lastKeyboardValue.length) {
      final removedCount = _lastKeyboardValue.length - value.length;
      for (var i = 0; i < removedCount; i++) {
        _client.pressSpecial('BACKSPACE');
      }
    } else if (value != _lastKeyboardValue) {
      _client.typeText(value);
    }
    _lastKeyboardValue = value;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            if (_statusMessage != null)
              Container(
                width: double.infinity,
                color: Colors.red.shade900,
                padding: const EdgeInsets.all(6),
                child: Text(
                  _statusMessage!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            Expanded(child: _buildScreenArea()),
            // Off-screen field used purely to summon the system keyboard.
            SizedBox(
              height: 0,
              width: 0,
              child: TextField(
                controller: _keyboardController,
                focusNode: _keyboardFocus,
                onChanged: _onKeyboardChanged,
                autocorrect: false,
                enableSuggestions: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _initBlankCanvas() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _canvasWidth.toDouble(), _canvasHeight.toDouble()),
      Paint()..color = Colors.black,
    );
    final picture = recorder.endRecording();
    final img = await picture.toImage(_canvasWidth, _canvasHeight);
    picture.dispose();
    if (mounted) {
      setState(() {
        _canvasImage?.dispose();
        _canvasImage = img;
      });
    } else {
      img.dispose();
    }
  }

  Future<void> _drainQueue() async {
    if (_processingQueue) return;
    _processingQueue = true;
    while (_patchQueue.isNotEmpty) {
      await _compositePatch(_patchQueue.removeAt(0));
    }
    _processingQueue = false;
  }

  Future<void> _compositePatch(FramePatch patch) async {
    if (_canvasImage == null || patch.width <= 0 || patch.height <= 0) return;

    final codec = await ui.instantiateImageCodec(patch.jpegBytes);
    final frame = await codec.getNextFrame();
    final patchImage = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(_canvasImage!, Offset.zero, Paint());
    canvas.drawImage(patchImage, Offset(patch.x.toDouble(), patch.y.toDouble()), Paint());
    final picture = recorder.endRecording();
    final newCanvas = await picture.toImage(_canvasWidth, _canvasHeight);
    picture.dispose();
    patchImage.dispose();
    codec.dispose();

    final oldCanvas = _canvasImage;
    if (mounted) {
      setState(() => _canvasImage = newCanvas);
    } else {
      newCanvas.dispose();
    }
    oldCanvas?.dispose();
  }

  Widget _buildScreenArea() {
    if (_canvasImage == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text('Waiting for first frame...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _canvasWidth / _canvasHeight,
        child: ClipRect(
          child: Listener(
            key: _viewportKey,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: Transform(
                transform: Matrix4.identity()
                  ..translateByDouble(_viewOffset.dx, _viewOffset.dy, 0, 1)
                  ..scaleByDouble(_viewScale, _viewScale, _viewScale, 1),
              child: CustomPaint(
                painter: _CanvasPainter(_canvasImage),
                size: Size.infinite,
              ),
            ),
          ),
        ),
      ),
    );
  }

}

class _CanvasPainter extends CustomPainter {
  final ui.Image? image;
  _CanvasPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    if (image == null) return;
    canvas.drawImageRect(
      image!,
      Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) => oldDelegate.image != image;
}