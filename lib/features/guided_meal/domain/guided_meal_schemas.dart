import 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';

/// The two tool contracts of the guided flow.
///
/// Like the app's own meal schema these are plain JSON Schema and only a hint
/// to the model. Everything the app relies on is re-checked in Dart by
/// [guidedAnalysisFromJson] and [guidedEstimateFromJson], against a reply that
/// ignored the schema entirely.

const askQuestionsToolName = 'ask_meal_questions';
const askQuestionsToolDescription =
    'Describe the meal and list the multiple-choice questions to ask the user.';

const estimateMealToolName = 'estimate_meal';
const estimateMealToolDescription =
    'Return every food of the meal with the estimated weight of its portion.';

const askQuestionsSchema = {
  'type': 'object',
  'properties': {
    'summary': {
      'type': 'string',
      'description':
          'One short line naming what is on the plate, in the user\'s '
          'language.',
    },
    'questions': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'Short unique id: q1, q2…'},
          'text': {
            'type': 'string',
            'description': 'The question, in the user\'s language.',
          },
          'multi_select': {
            'type': 'boolean',
            'description': 'true only if several options can be true at once.',
          },
          'options': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'label': {
                  'type': 'string',
                  'description': 'Short answer, in the user\'s language.',
                },
              },
              'required': ['id', 'label'],
            },
          },
        },
        'required': ['id', 'text', 'options'],
      },
    },
  },
  'required': ['summary', 'questions'],
};

const estimateMealSchema = {
  'type': 'object',
  'properties': {
    'items': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description':
                'The food name only, as a person would search for it, in '
                'the user\'s language.',
          },
          'grams': {
            'type': 'number',
            'description':
                'Estimated weight in grams of the portion that was eaten, '
                'worked out from the user\'s answers.',
          },
          'basis': {
            'type': 'string',
            'description':
                'One short sentence: which answer this weight comes from.',
          },
          'confidence': {
            'type': 'string',
            'enum': ['high', 'medium', 'low'],
            'description':
                'How sure you are about this food and its weight. Be honest: '
                'low when you could not tell what it is, or the weight '
                'rests mostly on "don\'t know" answers, or hidden fat, '
                'sauce or sugar could swing the energy a lot.',
          },
          'doubt': {
            'type': 'string',
            'description':
                'Only for medium or low: one short sentence on what is '
                'uncertain, in the user\'s language.',
          },
          'kcal_per_100g': {'type': 'number'},
          'protein_per_100g': {'type': 'number'},
          'carbs_per_100g': {'type': 'number'},
          'fat_per_100g': {'type': 'number'},
        },
        'required': [
          'name',
          'grams',
          'kcal_per_100g',
          'protein_per_100g',
          'carbs_per_100g',
          'fat_per_100g',
        ],
      },
    },
  },
  'required': ['items'],
};

const maxQuestions = 10;
const minOptions = 2;
const maxOptions = 8;
const maxLabelLength = 60;
const maxQuestionLength = 200;

const maxItemGrams = 2000.0;
const maxItems = 15;

/// The user said grams are hard to judge. A question or option that asks for
/// one anyway ("150 g", "200 ml", "ca. 2 dl") is dropped here rather than
/// trusted to the prompt.
final _metricAmount = RegExp(
  r'\b\d+([.,]\d+)?\s?(g|gr|gramm|gram|kg|ml|cl|dl|l|liter|oz|lb)\b',
  caseSensitive: false,
);

bool mentionsMetricAmount(String text) => _metricAmount.hasMatch(text);

/// Reads the reply of [askQuestionsToolName].
///
/// A malformed question is dropped, the rest survive. A reply with no usable
/// question at all is not an error: the model may legitimately have nothing
/// left to ask, and the caller goes straight to the estimate.
GuidedAnalysis guidedAnalysisFromJson(Object? raw) {
  if (raw is! Map) {
    throw const MealInterpreterException('questions reply is not an object');
  }
  final summary = raw['summary'];
  final rawQuestions = raw['questions'];
  if (rawQuestions is! List) {
    throw const MealInterpreterException('questions reply has no questions');
  }

  final seenIds = <String>{};
  final questions = <GuidedQuestion>[];
  for (final entry in rawQuestions) {
    if (questions.length >= maxQuestions) break;
    final question = _questionFrom(entry, seenIds);
    if (question != null) questions.add(question);
  }

  return GuidedAnalysis(
    summary: summary is String ? summary.trim() : '',
    questions: questions,
  );
}

GuidedQuestion? _questionFrom(Object? entry, Set<String> seenIds) {
  if (entry is! Map) return null;
  final id = entry['id'];
  final text = entry['text'];
  final rawOptions = entry['options'];
  if (id is! String || id.isEmpty || seenIds.contains(id)) return null;
  if (text is! String || text.trim().isEmpty) return null;
  if (text.length > maxQuestionLength || mentionsMetricAmount(text)) {
    return null;
  }
  if (rawOptions is! List) return null;

  final optionIds = <String>{};
  final options = <GuidedOption>[];
  for (final option in rawOptions) {
    if (options.length >= maxOptions) break;
    if (option is! Map) continue;
    final optionId = option['id'];
    final label = option['label'];
    if (optionId is! String || optionId.isEmpty) continue;
    if (label is! String || label.trim().isEmpty) continue;
    if (label.length > maxLabelLength || mentionsMetricAmount(label)) continue;
    if (!optionIds.add(optionId)) continue;
    options.add(GuidedOption(id: optionId, label: label.trim()));
  }
  if (options.length < minOptions) return null;

  seenIds.add(id);
  return GuidedQuestion(
    id: id,
    text: text.trim(),
    multiSelect: entry['multi_select'] == true,
    options: options,
  );
}

/// Reads the reply of [estimateMealToolName].
///
/// Raises when nothing usable came back: unlike the questions, an empty
/// estimate means the flow produced nothing and the user must be told.
GuidedEstimate guidedEstimateFromJson(Object? raw) {
  if (raw is! Map || raw['items'] is! List) {
    throw const MealInterpreterException('estimate reply has no items');
  }
  final rawItems = raw['items'] as List;
  final items = <GuidedEstimateItem>[];
  for (final entry in rawItems) {
    if (items.length >= maxItems) break;
    final item = _estimateItemFrom(entry);
    if (item != null) items.add(item);
  }
  if (items.isEmpty && rawItems.isNotEmpty) {
    throw const MealInterpreterException('every estimated item was dropped');
  }
  return GuidedEstimate(items: items);
}

GuidedEstimateItem? _estimateItemFrom(Object? entry) {
  if (entry is! Map) return null;
  final name = entry['name'];
  if (name is! String || name.trim().isEmpty) return null;

  final grams = _number(entry['grams']);
  if (grams == null || !grams.isFinite || grams <= 0) return null;

  final basis = entry['basis'];
  final doubt = entry['doubt'];
  return GuidedEstimateItem(
    name: name.trim(),
    grams: grams > maxItemGrams ? maxItemGrams : grams,
    basis: basis is String && basis.trim().isNotEmpty ? basis.trim() : null,
    fallbackNutrition: _nutritionFrom(entry),
    confidence: GuidedConfidence.fromTag(entry['confidence']),
    doubt: doubt is String && doubt.trim().isNotEmpty ? doubt.trim() : null,
  );
}

/// Numbers arrive as int, double or a string depending on the model.
double? _number(Object? value) => switch (value) {
  num n => n.toDouble(),
  String s => double.tryParse(s.replaceAll(',', '.')),
  _ => null,
};

/// Plausible values only. The estimate is a fallback the user is told is a
/// guess, but a guess of 4000 kcal per 100 g would still land in the diary.
GuidedNutritionPer100g? _nutritionFrom(Map entry) {
  final kcal = _number(entry['kcal_per_100g']);
  final protein = _number(entry['protein_per_100g']);
  final carbs = _number(entry['carbs_per_100g']);
  final fat = _number(entry['fat_per_100g']);
  if (kcal == null || protein == null || carbs == null || fat == null) {
    return null;
  }
  final values = [kcal, protein, carbs, fat];
  if (values.any((v) => !v.isFinite || v < 0)) return null;
  if (kcal > 900 || protein > 100 || carbs > 100 || fat > 100) return null;
  // Nothing is more than 100 g per 100 g; a little slack for rounding.
  if (protein + carbs + fat > 105) return null;
  return GuidedNutritionPer100g(
    kcal: kcal,
    protein: protein,
    carbs: carbs,
    fat: fat,
  );
}

const decideMealToolName = 'decide_meal';
const decideMealToolDescription =
    'Return the final list of foods after weighing the first estimate against '
    'the second opinion, and say what you decided and why.';

/// The estimate schema plus a verdict, so a decision is the same shape the
/// rest of the flow already reads.
final decideMealSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    ...(estimateMealSchema['properties'] as Map<String, Object?>),
    'verdict': {
      'type': 'string',
      'description':
          "Two or three sentences in the user's language: what you changed "
          'from your first estimate and why, and what you kept.',
    },
  },
  'required': ['items', 'verdict'],
};

/// The most pasted text the app sends. A second opinion is a few paragraphs
/// and a table; anything beyond this is a whole chat pasted by mistake, and
/// the cap is also what bounds the request.
const maxSecondOpinionChars = 8000;

const maxVerdictChars = 600;

/// Reads the reply of [decideMealToolName].
///
/// Raises when no food survived: a decision that empties the meal would throw
/// away the estimate the person already has, so the caller keeps that one.
GuidedDecision guidedDecisionFromJson(Object? raw) {
  final estimate = guidedEstimateFromJson(raw);
  if (estimate.items.isEmpty) {
    throw const MealInterpreterException('decision has no items');
  }
  final verdict = raw is Map ? raw['verdict'] : null;
  final text = verdict is String ? verdict.trim() : '';
  return GuidedDecision(
    estimate: estimate,
    verdict: text.length > maxVerdictChars
        ? text.substring(0, maxVerdictChars)
        : text,
  );
}
