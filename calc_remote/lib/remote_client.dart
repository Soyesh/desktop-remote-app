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

/// Talks to the desktop companion: receives a stream of JPEG frames and the
/// desktop's screen size, and sends mouse/keyboard events back.
class RemoteClient {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  final _frameController = StreamController<Uint8List>.broadcast();
  final _screenInfoController = StreamController<ScreenInfo>.broadcast();
  final _statusController = StreamController<String>.broadcast();

  Stream<Uint8List> get frames => _frameController.stream;
  Stream<ScreenInfo> get screenInfo => _screenInfoController.stream;
  Stream<String> get status => _statusController.stream;

  bool get isConnected => _channel != null;

  void connect(String host, int port) {
    try {
      final uri = Uri.parse('ws://$host:$port/ws');
      final channel = IOWebSocketChannel.connect(uri);
      _channel = channel;

      _sub = channel.stream.listen(
        (message) {
          if (message is List<int>) {
            _frameController.add(Uint8List.fromList(message));
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
      }
    } catch (_) {
      // ignore malformed control messages
    }
  }

  void _send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  void mouseMove(double x, double y) => _send({'type': 'mouse_move', 'x': x, 'y': y});
  void mouseMoveRelative(double dx, double dy) => _send({'type': 'mouse_move_relative', 'dx': dx, 'dy': dy});
  void mouseDown({String button = 'left'}) => _send({'type': 'mouse_down', 'button': button});
  void mouseUp({String button = 'left'}) => _send({'type': 'mouse_up', 'button': button});
  void mouseClick({String button = 'left'}) => _send({'type': 'mouse_click', 'button': button});
  void mouseDoubleClick({String button = 'left'}) => _send({'type': 'mouse_double_click', 'button': button});
  void scroll(int dy) => _send({'type': 'scroll', 'dy': dy});
  void typeText(String text) => _send({'type': 'key_text', 'text': text});
  void pressSpecial(String code) => _send({'type': 'key_special', 'code': code});

  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    _frameController.close();
    _screenInfoController.close();
    _statusController.close();
  }
}
