import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_prompts.dart';

/// A prompt the user can paste into Claude, ChatGPT or Gemini, with the photo
/// attached, to have the estimate checked against real sources.
///
/// **The app sends nothing anywhere for this.** It only writes the text; the
/// person opens whichever assistant they already pay for and pastes it. That
/// is what makes a second opinion possible on a subscription, where no API
/// key exists to call.
///
/// The text carries everything the app learned — the person's note, what was
/// seen, every question with its answer, and the estimate with the model's own
/// doubts — so the assistant starts where this flow stopped instead of
/// asking again. German for a German app, English otherwise, with a line
/// naming the reply language for locales that have no template of their own.
String guidedSecondOpinionPrompt({
  required String languageCode,
  required String? note,
  required GuidedAnalysis analysis,
  required Map<String, GuidedAnswer> answers,
  required GuidedEstimate estimate,
  required String unknownLabel,
}) {
  final words = languageCode == 'de' ? _de : _en;
  final decimalComma = languageCode == 'de';

  String number(double value) {
    final text = value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    return decimalComma ? text.replaceAll('.', ',') : text;
  }

  final trimmedNote = note?.trim();
  final buffer = StringBuffer()
    ..writeln(words.intro)
    ..writeln()
    ..writeln('## ${words.yourInfo}')
    ..writeln(
      '${words.description}: '
      '${trimmedNote == null || trimmedNote.isEmpty ? words.none : trimmedNote}',
    );
  if (analysis.summary.isNotEmpty) {
    buffer.writeln('${words.seen}: ${analysis.summary}');
  }

  final answerLines = guidedAnswerLines(
    analysis.questions,
    answers,
    unknownLabel,
  );
  if (answerLines.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('${words.answers}:');
    for (final line in answerLines) {
      buffer.writeln('- $line');
    }
  }

  buffer
    ..writeln()
    ..writeln('## ${words.estimateHeading}')
    ..writeln(
      '| ${words.food} | ${words.amount} | kcal/100 g | ${words.protein} '
      '| ${words.carbs} | ${words.fat} | ${words.sureness} |',
    )
    ..writeln('|---|---|---|---|---|---|---|');
  for (final item in estimate.items) {
    final n = item.fallbackNutrition;
    buffer.writeln(
      '| ${item.name} | ${number(item.grams)} g '
      '| ${n == null ? '?' : number(n.kcal)} '
      '| ${n == null ? '?' : number(n.protein)} '
      '| ${n == null ? '?' : number(n.carbs)} '
      '| ${n == null ? '?' : number(n.fat)} '
      '| ${switch (item.confidence) {
        GuidedConfidence.high => words.sure,
        GuidedConfidence.medium => words.roughly,
        GuidedConfidence.low => words.unsure,
      }} |',
    );
  }
  final total = estimate.totalKcal;
  if (total != null) {
    buffer.writeln('${words.total}: ~${number(total)} kcal');
  }

  final doubts = [
    for (final item in estimate.items)
      if (item.doubt != null) '${item.name}: ${item.doubt}',
  ];
  buffer
    ..writeln()
    ..writeln('## ${words.doubtHeading}');
  if (doubts.isEmpty) {
    buffer.writeln(words.noDoubts);
  } else {
    for (final line in doubts) {
      buffer.writeln('- $line');
    }
  }

  buffer
    ..writeln()
    ..writeln('## ${words.taskHeading}');
  for (var i = 0; i < words.tasks.length; i++) {
    buffer.writeln('${i + 1}. ${words.tasks[i]}');
  }
  if (languageCode != 'de' && languageCode != 'en') {
    buffer
      ..writeln()
      ..writeln('Please answer in the language with the code "$languageCode".');
  }
  return buffer.toString().trimRight();
}

class _Words {
  final String intro;
  final String yourInfo;
  final String description;
  final String none;
  final String seen;
  final String answers;
  final String estimateHeading;
  final String food;
  final String amount;
  final String protein;
  final String carbs;
  final String fat;
  final String sureness;
  final String sure;
  final String roughly;
  final String unsure;
  final String total;
  final String doubtHeading;
  final String noDoubts;
  final String taskHeading;
  final List<String> tasks;

  const _Words({
    required this.intro,
    required this.yourInfo,
    required this.description,
    required this.none,
    required this.seen,
    required this.answers,
    required this.estimateHeading,
    required this.food,
    required this.amount,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.sureness,
    required this.sure,
    required this.roughly,
    required this.unsure,
    required this.total,
    required this.doubtHeading,
    required this.noDoubts,
    required this.taskHeading,
    required this.tasks,
  });
}

const _de = _Words(
  intro:
      'Ich möchte eine Zweitmeinung zu den Kalorien und Nährwerten einer '
      'Mahlzeit. Das Foto der Mahlzeit hängt an dieser Nachricht an.',
  yourInfo: 'Meine Angaben',
  description: 'Beschreibung',
  none: 'keine',
  seen: 'Was eine andere KI auf dem Foto erkannt hat',
  answers: 'Meine Antworten auf Rückfragen',
  estimateHeading: 'Bisherige Schätzung (von einer KI, teils unsicher)',
  food: 'Lebensmittel',
  amount: 'Menge',
  protein: 'Eiweiß',
  carbs: 'Kohlenhydrate',
  fat: 'Fett',
  sureness: 'Sicherheit',
  sure: 'ziemlich sicher',
  roughly: 'ungefähr',
  unsure: 'unsicher',
  total: 'Summe laut dieser Schätzung',
  doubtHeading: 'Wo die Schätzung unsicher ist',
  noDoubts: 'Die KI hat keine besonderen Unsicherheiten gemeldet.',
  taskHeading: 'Deine Aufgabe',
  tasks: [
    'Prüfe anhand des Fotos und meiner Antworten, ob Lebensmittel und '
        'Mengen stimmen. Korrigiere, was nicht passt, und sag mir, warum.',
    'Suche verlässliche Quellen für die Nährwerte (zum Beispiel '
        'Bundeslebensmittelschlüssel, USDA FoodData Central, Herstellerangaben '
        'oder offizielle Nährwerttabellen) und nenne sie mit Link. Erfinde '
        'keine Quellen.',
    'Gib je Lebensmittel Menge in Gramm, kcal, Eiweiß, Kohlenhydrate und '
        'Fett an, dann die Summe. Nenne außerdem eine realistische Spanne '
        '(von bis) und was sie am meisten bewegt.',
    'Fehlt dir eine Information, frag mich zuerst, statt zu raten.',
    'Schließe mit einer kompakten Tabelle ab '
        '(Lebensmittel | g | kcal | Eiweiß | KH | Fett), die ich in meine '
        'Kalorien-App übernehmen kann.',
  ],
);

const _en = _Words(
  intro:
      'I would like a second opinion on the calories and nutrition of a '
      'meal. The photo of the meal is attached to this message.',
  yourInfo: 'My details',
  description: 'Description',
  none: 'none',
  seen: 'What another AI saw in the photo',
  answers: 'My answers to follow-up questions',
  estimateHeading: 'Estimate so far (by an AI, partly uncertain)',
  food: 'Food',
  amount: 'Amount',
  protein: 'Protein',
  carbs: 'Carbs',
  fat: 'Fat',
  sureness: 'Confidence',
  sure: 'fairly sure',
  roughly: 'roughly',
  unsure: 'unsure',
  total: 'Total by this estimate',
  doubtHeading: 'Where the estimate is uncertain',
  noDoubts: 'The AI reported no particular uncertainties.',
  taskHeading: 'Your task',
  tasks: [
    'Check against the photo and my answers whether the foods and amounts '
        'are right. Correct what is not, and tell me why.',
    'Look up reliable sources for the nutrition values (for example the '
        'German BLS, USDA FoodData Central, manufacturer data or official '
        'nutrition tables) and give them with links. Do not invent sources.',
    'Give amount in grams, kcal, protein, carbohydrates and fat for each '
        'food, then the total. Also give a realistic range (from to) and '
        'what moves it most.',
    'If you are missing information, ask me first instead of guessing.',
    'Finish with a compact table (Food | g | kcal | Protein | Carbs | Fat) '
        'that I can copy into my calorie app.',
  ],
);
