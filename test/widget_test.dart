// Smoke test for the TL Chat app.
//
// Asserts only content rendered in the first viewport of the unconnected
// home page (connection panel). No Tailscale node is started in tests, so
// nothing native runs; the async state-dir lookup settles via pumpAndSettle.

import 'package:flutter_test/flutter_test.dart';

import 'package:tl_chat/main.dart';

void main() {
  testWidgets('ChatApp renders the connection panel', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    expect(find.text('TL Chat'), findsOneWidget);
    expect(find.text('接入 Hub'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('节点主机名'), findsOneWidget);
  });
}
