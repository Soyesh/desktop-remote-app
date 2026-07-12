import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'remote_client.dart';

class RemoteScreen extends StatefulWidget {
  final String host;
  final int port;
  const RemoteScreen({super.key, required this.host, required this.port});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final _client = RemoteClient();

  Uint8List? _lastFrame;
  String? _statusMessage;

  final _keyboardController = TextEditingController();
  final _keyboardFocus = FocusNode();
  String _lastKeyboardValue = '';

  Timer? _scrollTimer;

  @override
  void initState() {
    super.initState();
    _client.connect(widget.host, widget.port);

    _client.frames.listen((frame) {
      if (mounted) setState(() => _lastFrame = frame);
    });
    _client.status.listen((msg) {
      if (mounted) setState(() => _statusMessage = msg);
    });
  }

  @override
  void dispose() {
    _client.dispose();
    _keyboardController.dispose();
    _keyboardFocus.dispose();
    _scrollTimer?.cancel();
    super.dispose();
  }

  /// Converts finger movement into cursor movement. Tune this if the
  /// cursor feels too fast/slow relative to your actual finger motion.
  static const double _sensitivity = 1.4;

  void _startScrolling(int direction) {
    // direction: +1 = up, -1 = down. Fire immediately, then repeat while held.
    _client.scroll(direction * 120);
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      _client.scroll(direction * 120);
    });
  }

  void _stopScrolling() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
  }
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
            _buildToolbar(),
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

  Widget _buildScreenArea() {
    if (_lastFrame == null) {
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

    return Stack(
      children: [
        GestureDetector(
          // Drag = move cursor. Tap = left click. Double-tap = double-click.
          // Long-press = right-click. All act at the current cursor position.
          onPanUpdate: (details) {
            _client.mouseMoveRelative(details.delta.dx * _sensitivity, details.delta.dy * _sensitivity);
          },
          onTap: () => _client.mouseClick(button: 'left'),
          onDoubleTap: () => _client.mouseDoubleClick(button: 'left'),
          onLongPress: () => _client.mouseClick(button: 'right'),
          child: Image.memory(
            _lastFrame!,
            gaplessPlayback: true, // avoids flicker between frames
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
          ),
        ),
        Positioned(
          right: 12,
          top: 0,
          bottom: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _scrollButton(Icons.keyboard_arrow_up, () => _startScrolling(1)),
                const SizedBox(height: 12),
                _scrollButton(Icons.keyboard_arrow_down, () => _startScrolling(-1)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _scrollButton(IconData icon, VoidCallback onStart) {
    return GestureDetector(
      onTapDown: (_) => onStart(),
      onTapUp: (_) => _stopScrolling(),
      onTapCancel: _stopScrolling,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _clickButton('Left', () => _client.mouseClick(button: 'left')),
          _clickButton('Right', () => _client.mouseClick(button: 'right')),
          IconButton(
            icon: const Icon(Icons.keyboard, color: Colors.white),
            tooltip: 'Keyboard',
            onPressed: _openKeyboard,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_return, color: Colors.white),
            tooltip: 'Enter',
            onPressed: () => _client.pressSpecial('ENTER'),
          ),
          IconButton(
            icon: const Icon(Icons.backspace, color: Colors.white),
            tooltip: 'Backspace',
            onPressed: () => _client.pressSpecial('BACKSPACE'),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Escape',
            onPressed: () => _client.pressSpecial('ESC'),
          ),
        ],
      ),
    );
  }

  Widget _clickButton(String label, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white54),
      ),
      child: Text(label),
    );
  }
}
