import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ScreenInfo {
  final int width;
  final int height;
  ScreenInfo(this.width, this.height);
}

class FramePatch {
  final int x, y, width, height;
  final Uint8List jpegBytes;
  FramePatch(this.x, this.y, this.width, this.height, this.jpegBytes);
}

/// Talks to the desktop companion: receives a stream of JPEG frames and the
/// desktop's screen size, and sends mouse/keyboard events back.
class RemoteClient {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  final _patchController = StreamController<FramePatch>.broadcast();
  final _screenInfoController = StreamController<ScreenInfo>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _textInputFocusController = StreamController<bool>.broadcast();

  Stream<FramePatch> get patches => _patchController.stream;
  Stream<ScreenInfo> get screenInfo => _screenInfoController.stream;
  Stream<String> get status => _statusController.stream;
  Stream<bool> get textInputFocus => _textInputFocusController.stream;

  bool get isConnected => _channel != null;

  void connect(String host, int port) {
    try {
      final uri = Uri.parse('ws://$host:$port/ws');
      final channel = IOWebSocketChannel.connect(uri);
      _channel = channel;

      _sub = channel.stream.listen(
        (message) {
          if (message is List<int>) {
            _handleBinaryMessage(Uint8List.fromList(message));
          } else if (message is String) {
            _handleTextMessage(message);
          }
        },
        onError: (e) {
          _statusController.add('Connection error: $e');
          _channel = null;
        },
        onDone: () {
          _statusController.add('Disconnected');
          _channel = null;
        },
      );
    } catch (e) {
      _statusController.add('Could not connect: $e');
    }
  }

  void _handleTextMessage(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['type'] == 'screen_info') {
        _screenInfoController.add(ScreenInfo(data['width'] as int, data['height'] as int));
      } else if (data['type'] == 'text_input_focus') {
        _textInputFocusController.add(data['active'] as bool);
      }
    } catch (_) {
      // ignore malformed control messages
    }
  }

  void _handleBinaryMessage(Uint8List bytes) {
    if (bytes.length < 16) return;
    final header = ByteData.sublistView(bytes, 0, 16);
    final x = header.getInt32(0, Endian.little);
    final y = header.getInt32(4, Endian.little);
    final w = header.getInt32(8, Endian.little);
    final h = header.getInt32(12, Endian.little);
    _patchController.add(FramePatch(x, y, w, h, bytes.sublist(16)));
  }

  void _send(Map<String, dynamic> payload) {
    if (_channel == null) {
      print('[SEND] DROPPED - no active channel: ${payload['type']}'); // TEMP DEBUG
      return;
    }
    print('[SEND] ${payload['type']}'); // TEMP DEBUG
    _channel!.sink.add(jsonEncode(payload));
  }

  void mouseMove(double x, double y) => _send({'type': 'mouse_move', 'x': x, 'y': y});
  void mouseMoveRelative(double dx, double dy) => _send({'type': 'mouse_move_relative', 'dx': dx, 'dy': dy});
  void mouseDown({String button = 'left'}) => _send({'type': 'mouse_down', 'button': button});
  void mouseUp({String button = 'left'}) => _send({'type': 'mouse_up', 'button': button});
  void mouseClick({String button = 'left'}) => _send({'type': 'mouse_click', 'button': button});
  void mouseDoubleClick({String button = 'left'}) => _send({'type': 'mouse_double_click', 'button': button});
  void mouseClickAt(double xPercent, double yPercent, {String button = 'left'}) =>
    _send({'type': 'mouse_click_at', 'x': xPercent, 'y': yPercent, 'button': button});
void mouseDoubleClickAt(double xPercent, double yPercent, {String button = 'left'}) =>
    _send({'type': 'mouse_double_click_at', 'x': xPercent, 'y': yPercent, 'button': button});
  void scroll(int dy) => _send({'type': 'scroll', 'dy': dy});
  void typeText(String text) => _send({'type': 'key_text', 'text': text});
  void pressSpecial(String code) => _send({'type': 'key_special', 'code': code});

  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    _patchController.close();
    _screenInfoController.close();
    _statusController.close();
    _textInputFocusController.close();
  }
}
