import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/presentation/guided_result_view.dart';
import 'package:opennutritracker/generated/l10n.dart';

const _uncertain = GuidedEstimate(
  items: [
    GuidedEstimateItem(
      name: 'Schweineschnitzel, paniert',
      grams: 180,
      basis: 'Eine Handfläche Fleisch',
      confidence: GuidedConfidence.low,
      doubt: 'Menge Öl beim Braten unbekannt',
      fallbackNutrition: GuidedNutritionPer100g(
        kcal: 230,
        protein: 18,
        carbs: 12,
        fat: 12,
      ),
    ),
    GuidedEstimateItem(name: 'Erbsen', grams: 60),
  ],
);

const _sure = GuidedEstimate(
  items: [
    GuidedEstimateItem(
      name: 'Apfel',
      grams: 150,
      confidence: GuidedConfidence.high,
    ),
  ],
);

Widget _app(
  GuidedEstimate estimate, {
  String prompt = 'DER PROMPT',
  void Function(String)? onSubmit,
  String? verdict,
}) => MaterialApp(
  locale: const Locale('de'),
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: Scaffold(
    body: GuidedResultView(
      estimate: estimate,
      photo: null,
      buildPrompt: () => prompt,
      onContinue: () {},
      onSubmitSecondOpinion: onSubmit ?? (_) {},
      verdict: verdict,
    ),
  ),
);

void main() {
  testWidgets('shows foods, weights, doubts and the uncertainty banner', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_uncertain));
    await tester.pumpAndSettle();

    expect(find.text('Schweineschnitzel, paniert'), findsOneWidget);
    expect(find.text('180 g'), findsOneWidget);
    expect(find.text('unsicher'), findsOneWidget);
    expect(find.text('Menge Öl beim Braten unbekannt'), findsOneWidget);
    expect(
      find.textContaining('Bei einigen Lebensmitteln bin ich unsicher'),
      findsOneWidget,
    );
    expect(find.textContaining('etwa 414 kcal'), findsOneWidget);
    expect(find.text('Zweitmeinung holen'), findsOneWidget);
  });

  testWidgets('a sure estimate shows no banner but keeps the option', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_sure));
    await tester.pumpAndSettle();

    expect(find.textContaining('bin ich unsicher'), findsNothing);
    expect(find.text('Zweitmeinung holen'), findsOneWidget);
  });

  testWidgets('the sheet shows the prompt and copies it to the clipboard', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(_app(_uncertain, prompt: 'PROMPT-TEXT-123'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zweitmeinung holen'));
    await tester.pumpAndSettle();

    expect(
      find.text('Zweitmeinung mit deinem eigenen Assistenten'),
      findsOneWidget,
    );
    await tester.tap(find.text('Prompt ansehen'));
    await tester.pumpAndSettle();
    expect(find.text('PROMPT-TEXT-123'), findsOneWidget);

    await tester.tap(find.text('Prompt kopieren'));
    await tester.pumpAndSettle();

    expect(copied, 'PROMPT-TEXT-123');
    expect(find.textContaining('Prompt kopiert'), findsOneWidget);
  });

  testWidgets('without a photo the share action says it shares text only', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_uncertain));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zweitmeinung holen'));
    await tester.pumpAndSettle();

    expect(find.text('Text teilen'), findsOneWidget);
    expect(find.text('Mit Foto teilen'), findsNothing);
  });

  testWidgets('a pasted opinion is handed on for the decision', (tester) async {
    String? submitted;
    await tester.pumpWidget(_app(_uncertain, onSubmit: (t) => submitted = t));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Antwort einfügen'));
    await tester.pumpAndSettle();

    // Nothing to send until something is pasted.
    final decide = find.widgetWithText(
      FilledButton,
      'Final entscheiden lassen',
    );
    expect(tester.widget<FilledButton>(decide).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Zweitmeinung: 190 kcal');
    await tester.pump();
    expect(tester.widget<FilledButton>(decide).onPressed, isNotNull);

    await tester.tap(decide);
    await tester.pumpAndSettle();

    expect(submitted, 'Zweitmeinung: 190 kcal');
  });

  testWidgets('the decision shows its verdict and drops the banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_uncertain, verdict: 'Menge auf 380 g erhöht.'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Meine Entscheidung'), findsOneWidget);
    expect(find.text('Menge auf 380 g erhöht.'), findsOneWidget);
    expect(find.textContaining('bin ich unsicher'), findsNothing);
  });
}
