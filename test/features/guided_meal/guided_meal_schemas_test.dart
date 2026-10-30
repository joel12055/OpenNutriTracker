import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_prompts.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_schemas.dart';

Map<String, Object?> _question(
  String id, {
  String text = 'Welche Fleischsorte war es?',
  List<Map<String, Object?>>? options,
  bool? multi,
}) => {
  'id': id,
  'text': text,
  'multi_select': ?multi,
  'options':
      options ??
      [
        {'id': 'a', 'label': 'Hähnchen'},
        {'id': 'b', 'label': 'Schwein'},
        {'id': 'c', 'label': 'Rind'},
      ],
};

void main() {
  group('guidedAnalysisFromJson', () {
    test('reads questions and options', () {
      final analysis = guidedAnalysisFromJson({
        'summary': 'Schnitzel mit Erbsen',
        'questions': [_question('q1', multi: false), _question('q2')],
      });

      expect(analysis.summary, 'Schnitzel mit Erbsen');
      expect(analysis.questions.map((q) => q.id), ['q1', 'q2']);
      expect(analysis.questions.first.options.map((o) => o.label), [
        'Hähnchen',
        'Schwein',
        'Rind',
      ]);
      expect(analysis.questions.first.multiSelect, isFalse);
    });

    test('drops a question that asks for grams, keeps the others', () {
      final analysis = guidedAnalysisFromJson({
        'summary': '',
        'questions': [
          _question('q1', text: 'Wie viel Reis? (in Gramm: 100 g oder 200 g)'),
          _question('q2'),
        ],
      });

      expect(analysis.questions.map((q) => q.id), ['q2']);
    });

    test('drops options that state an exact weight or volume', () {
      final analysis = guidedAnalysisFromJson({
        'summary': '',
        'questions': [
          _question(
            'q1',
            text: 'Wie groß war die Portion Erbsen?',
            options: [
              {'id': 'a', 'label': 'Eine Handvoll'},
              {'id': 'b', 'label': 'Zwei Handvoll'},
              {'id': 'c', 'label': 'ca. 150 g'},
              {'id': 'd', 'label': '2,5 dl'},
            ],
          ),
        ],
      });

      expect(analysis.questions.single.options.map((o) => o.id), ['a', 'b']);
    });

    test('drops a question left with fewer than two options', () {
      final analysis = guidedAnalysisFromJson({
        'summary': '',
        'questions': [
          _question(
            'q1',
            options: [
              {'id': 'a', 'label': 'Eine Handvoll'},
              {'id': 'b', 'label': '100 g'},
            ],
          ),
        ],
      });

      expect(analysis.questions, isEmpty);
    });

    test('drops duplicate question ids and duplicate option ids', () {
      final analysis = guidedAnalysisFromJson({
        'summary': '',
        'questions': [
          _question('q1'),
          _question('q1', text: 'Noch einmal?'),
          _question(
            'q2',
            options: [
              {'id': 'a', 'label': 'Ja'},
              {'id': 'a', 'label': 'Doppelt'},
              {'id': 'b', 'label': 'Nein'},
            ],
          ),
        ],
      });

      expect(analysis.questions.map((q) => q.id), ['q1', 'q2']);
      expect(analysis.questions.last.options.map((o) => o.label), [
        'Ja',
        'Nein',
      ]);
    });

    test('caps the number of questions', () {
      final analysis = guidedAnalysisFromJson({
        'summary': '',
        'questions': [for (var i = 0; i < 30; i++) _question('q$i')],
      });

      expect(analysis.questions, hasLength(maxQuestions));
    });

    test('an empty question list is a valid answer', () {
      final analysis = guidedAnalysisFromJson({
        'summary': 'Apfel',
        'questions': <Object?>[],
      });

      expect(analysis.questions, isEmpty);
    });

    test('raises when the reply is not the shape that was asked for', () {
      expect(
        () => guidedAnalysisFromJson({'summary': 'x'}),
        throwsA(isA<MealInterpreterException>()),
      );
      expect(
        () => guidedAnalysisFromJson('nope'),
        throwsA(isA<MealInterpreterException>()),
      );
    });
  });

  group('guidedEstimateFromJson', () {
    Map<String, Object?> item({
      Object? name = 'Erbsen, gekocht',
      Object? grams = 60,
      Object? kcal = 70,
      Object? protein = 5,
      Object? carbs = 10,
      Object? fat = 0.5,
    }) => {
      'name': name,
      'grams': grams,
      'basis': 'Eine Handvoll',
      'kcal_per_100g': kcal,
      'protein_per_100g': protein,
      'carbs_per_100g': carbs,
      'fat_per_100g': fat,
    };

    test('reads items with their fallback nutrition', () {
      final estimate = guidedEstimateFromJson({
        'items': [item()],
      });

      final first = estimate.items.single;
      expect(first.name, 'Erbsen, gekocht');
      expect(first.grams, 60);
      expect(first.basis, 'Eine Handvoll');
      expect(first.fallbackNutrition?.kcal, 70);
    });

    test('accepts numbers written as strings with a decimal comma', () {
      final estimate = guidedEstimateFromJson({
        'items': [item(grams: '62,5', kcal: '70')],
      });

      expect(estimate.items.single.grams, 62.5);
      expect(estimate.items.single.fallbackNutrition?.kcal, 70);
    });

    test('clamps an absurd weight', () {
      final estimate = guidedEstimateFromJson({
        'items': [item(grams: 90000)],
      });

      expect(estimate.items.single.grams, maxItemGrams);
    });

    test('drops items without a name or with a non-positive weight', () {
      final estimate = guidedEstimateFromJson({
        'items': [item(name: ''), item(grams: 0), item(grams: -5), item()],
      });

      expect(estimate.items, hasLength(1));
    });

    test('keeps the item but ignores implausible nutrition values', () {
      final estimate = guidedEstimateFromJson({
        'items': [
          item(kcal: 4000),
          item(protein: 80, carbs: 80, fat: 80),
          item(kcal: -1),
        ],
      });

      expect(estimate.items, hasLength(3));
      expect(estimate.items.every((i) => i.fallbackNutrition == null), isTrue);
    });

    test('raises when every item was dropped', () {
      expect(
        () => guidedEstimateFromJson({
          'items': [item(name: ''), item(grams: 0)],
        }),
        throwsA(isA<MealInterpreterException>()),
      );
    });

    test('an empty list is a valid answer', () {
      expect(guidedEstimateFromJson({'items': <Object?>[]}).items, isEmpty);
    });
  });

  group('guidedEstimateUserText', () {
    test('lists each question with the labels picked or the unknown label', () {
      const questions = [
        GuidedQuestion(
          id: 'q1',
          text: 'Welche Fleischsorte?',
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
      ];

      final text = guidedEstimateUserText(
        note: 'Mittagessen in der Kantine',
        summary: 'Schnitzel mit Erbsen',
        questions: questions,
        answers: {
          'q1': const GuidedAnswer(questionId: 'q1', optionIds: {'b'}),
          'q2': const GuidedAnswer(questionId: 'q2', unknown: true),
        },
        unknownLabel: 'Weiß ich nicht',
      );

      expect(text, contains('Mittagessen in der Kantine'));
      expect(text, contains('Welche Fleischsorte? → Schwein'));
      expect(text, contains('Wie viele Erbsen? → Weiß ich nicht'));
    });
  });
}
