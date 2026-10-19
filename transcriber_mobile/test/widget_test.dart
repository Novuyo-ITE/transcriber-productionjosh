import 'package:flutter_test/flutter_test.dart';
import 'package:transcriber_mobile/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const NovuscribeApp());
  });
}
