import 'package:flutter_test/flutter_test.dart';
import 'package:samirnet_player/main.dart';

void main() {
  testWidgets('SamirNet Player renders the application shell', (tester) async {
    await tester.pumpWidget(const SamirNetApp());
    await tester.pump();
    expect(find.text('SamirNet Player'), findsOneWidget);
    expect(find.text('الرئيسية'), findsWidgets);
  });
}
