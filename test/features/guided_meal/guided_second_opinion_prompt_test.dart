import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_second_opinion_prompt.dart';

const _analysis = GuidedAnalysis(
  summary: 'Schnitzel mit Erbsen',
  questions: [
    GuidedQuestion(
      id: 'q1',
      text: 'Welche Fleischsorte war es?',
      multiSelect: false,
      options: [
        GuidedOption(id: 'a', label: 'Hähnchen'),
        GuidedOption(id: 'b', label: 'Schwein'),
      ],
    ),
    GuidedQuestion(
      id: 'q2',
      text: 'Wie viele Erbsen?',
      multiSelect: false,
      options: [
        GuidedOption(id: 'a', label: 'Eine Handvoll'),
        GuidedOption(id: 'b', label: 'Zwei Handvoll'),
      ],
    ),
  ],
);

final _answers = {
  'q1': const GuidedAnswer(questionId: 'q1', optionIds: {'b'}),
  'q2': const GuidedAnswer(questionId: 'q2', unknown: true),
};

const _estimate = GuidedEstimate(
  items: [
    GuidedEstimateItem(
      name: 'Schweineschnitzel, paniert',
      grams: 180,
      confidence: GuidedConfidence.low,
      doubt: 'Menge Öl beim Braten unbekannt',
      fallbackNutrition: GuidedNutritionPer100g(
        kcal: 230.5,
        protein: 18,
        carbs: 12,
        fat: 12,
      ),
    ),
    GuidedEstimateItem(name: 'Erbsen', grams: 60),
  ],
);

String _prompt(String languageCode, {GuidedEstimate estimate = _estimate}) =>
    guidedSecondOpinionPrompt(
      languageCode: languageCode,
      note: 'Kantinenessen',
      analysis: _analysis,
      answers: _answers,
      estimate: estimate,
      unknownLabel: 'Weiß ich nicht',
    );

void main() {
  group('guidedSecondOpinionPrompt', () {
    test(
      'carries everything the flow learned, in German with decimal commas',
      () {
        final text = _prompt('de');

        expect(text, contains('Zweitmeinung'));
        expect(text, contains('Kantinenessen'));
        expect(text, contains('Schnitzel mit Erbsen'));
        expect(text, contains('Welche Fleischsorte war es? → Schwein'));
        expect(text, contains('Wie viele Erbsen? → Weiß ich nicht'));
        expect(
          text,
          contains('| Schweineschnitzel, paniert | 180 g | 230,5 |'),
        );
        expect(text, contains('unsicher'));
        expect(text, contains('Menge Öl beim Braten unbekannt'));
        // The model's own total: 180 g at 230.5 kcal per 100 g.
        expect(text, contains('~414,9 kcal'));
        expect(text, contains('Erfinde keine Quellen'));
      },
    );

    test('a food without figures shows question marks, not zeros', () {
      final text = _prompt('de');

      expect(text, contains('| Erbsen | 60 g | ? | ? | ? | ? | ungefähr |'));
    });

    test('says so when the model reported no doubts', () {
      final text = _prompt(
        'de',
        estimate: const GuidedEstimate(
          items: [GuidedEstimateItem(name: 'Apfel', grams: 150)],
        ),
      );

      expect(text, contains('keine besonderen Unsicherheiten'));
    });

    test('English for English, with decimal points', () {
      final text = _prompt('en');

      expect(text, contains('second opinion'));
      expect(text, contains('| 180 g | 230.5 |'));
      expect(text, isNot(contains('Please answer in the language')));
    });

    test('a locale without a template gets English and a reply language', () {
      final text = _prompt('fr');

      expect(text, contains('second opinion'));
      expect(
        text,
        contains('Please answer in the language with the code "fr"'),
      );
    });

    test('asks for sources, a range and a copyable table', () {
      final text = _prompt('en');

      expect(text, contains('Do not invent sources'));
      expect(text, contains('realistic range'));
      expect(text, contains('compact table'));
    });
  });

  group('confidence', () {
    Map<String, Object?> item({Object? confidence, Object? doubt}) => {
      'name': 'Erbsen',
      'grams': 60,
      'confidence': ?confidence,
      'doubt': ?doubt,
      'kcal_per_100g': 70,
      'protein_per_100g': 5,
      'carbs_per_100g': 10,
      'fat_per_100g': 0.5,
    };

    test('is read from the reply', () {
      final estimate = guidedEstimateFromJson({
        'items': [item(confidence: 'low', doubt: 'Sauce unklar')],
      });

      expect(estimate.items.single.confidence, GuidedConfidence.low);
      expect(estimate.items.single.doubt, 'Sauce unklar');
      expect(estimate.isUncertain, isTrue);
    });

    test('a missing or unknown value reads as medium, never as high', () {
      final estimate = guidedEstimateFromJson({
        'items': [item(), item(confidence: 'certain')],
      });

      expect(
        estimate.items.map((i) => i.confidence),
        everyElement(GuidedConfidence.medium),
      );
      expect(estimate.isUncertain, isFalse);
    });

    test('the model total counts only foods that came with figures', () {
      final estimate = guidedEstimateFromJson({
        'items': [
          item(),
          {'name': 'Rest', 'grams': 100},
        ],
      });

      // 60 g at 70 kcal per 100 g.
      expect(estimate.totalKcal, closeTo(42, 0.001));
    });
  });
}
