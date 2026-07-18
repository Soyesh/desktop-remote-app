import 'package:flutter_test/flutter_test.dart';

import 'package:calc_remote/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const RemoteApp());
    await tester.pump();
  });
}