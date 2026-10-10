import 'package:flutter_test/flutter_test.dart';
import 'package:waytowebs_app/main.dart';

void main() {
  testWidgets('role selection shows the three app roles', (tester) async {
    await tester.pumpWidget(const WaytowebsApp());

    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Dealer'), findsOneWidget);
    expect(find.text('Plumber'), findsOneWidget);
  });
}
