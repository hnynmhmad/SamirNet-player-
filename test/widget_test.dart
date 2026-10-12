import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:samirnet_player/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SM Player renders the application shell', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SamirNetApp());
    await tester.pump();
    expect(find.text('SM Player'), findsOneWidget);
    expect(find.text('الرئيسية'), findsWidgets);
  });
}
