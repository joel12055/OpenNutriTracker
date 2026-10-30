/// One choice the user can tap. The app adds its own "I don't know" choice to
/// every question, so a model never has to (and never gets to) offer one.
class GuidedOption {
  final String id;
  final String label;

  const GuidedOption({required this.id, required this.label});
}

/// A question the model wants answered before it estimates anything.
///
/// Multiple choice by construction: there is no free-text question, because
/// the point of this flow is that a person can answer from memory of a plate
/// of food ("a handful") without weighing anything.
class GuidedQuestion {
  final String id;
  final String text;

  /// Several options may be ticked together, e.g. "which of these were in it?".
  final bool multiSelect;
  final List<GuidedOption> options;

  const GuidedQuestion({
    required this.id,
    required this.text,
    required this.multiSelect,
    required this.options,
  });
}

/// What the model made of the photo and the optional note, before asking.
class GuidedAnalysis {
  /// One short line naming what is on the plate, in the user's language.
  final String summary;
  final List<GuidedQuestion> questions;

  const GuidedAnalysis({required this.summary, required this.questions});
}

/// The user's answer to one question.
///
/// [unknown] is the app's own "I don't know" choice and excludes [optionIds].
class GuidedAnswer {
  final String questionId;
  final Set<String> optionIds;
  final bool unknown;

  const GuidedAnswer({
    required this.questionId,
    this.optionIds = const {},
    this.unknown = false,
  });

  bool get isAnswered => unknown || optionIds.isNotEmpty;
}

/// Energy and macros per 100 g, as the model believes them to be.
///
/// Only ever a fallback for a food no database could resolve, and always shown
/// as an estimate. Never preferred over a database row.
class GuidedNutritionPer100g {
  final double kcal;
  final double protein;
  final double carbs;
  final double fat;

  const GuidedNutritionPer100g({
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
  });
}

/// How sure the model says it is about one food and its weight.
///
/// Taken at its word only in one direction: a missing or unknown value reads
/// as [medium], never as [high], so a model that skips the field cannot make
/// an estimate look safer than it was.
enum GuidedConfidence {
  high,
  medium,
  low;

  static GuidedConfidence fromTag(Object? value) => switch (value) {
    'high' => high,
    'low' => low,
    _ => medium,
  };
}

/// One food with the amount the answers add up to.
class GuidedEstimateItem {
  /// The food as the user would name it, in their language. Used as the
  /// database search query.
  final String name;

  /// What the model estimated the portion to weigh, derived from the answers
  /// ("a handful of peas"), not read off the photo. The user can still edit it
  /// on the review screen.
  final double grams;

  /// One short sentence on how [grams] came about, shown next to the row.
  final String? basis;

  /// Used only when the food databases find nothing.
  final GuidedNutritionPer100g? fallbackNutrition;

  final GuidedConfidence confidence;

  /// One short sentence on what makes this item uncertain, when it is.
  final String? doubt;

  const GuidedEstimateItem({
    required this.name,
    required this.grams,
    this.basis,
    this.fallbackNutrition,
    this.confidence = GuidedConfidence.medium,
    this.doubt,
  });

  /// Energy of the portion by the model's own figures, or null without them.
  double? get kcal {
    final nutrition = fallbackNutrition;
    return nutrition == null ? null : nutrition.kcal * grams / 100;
  }
}

class GuidedEstimate {
  final List<GuidedEstimateItem> items;

  const GuidedEstimate({required this.items});

  /// Whether the model flagged any food as one it could not pin down.
  bool get isUncertain =>
      items.any((item) => item.confidence == GuidedConfidence.low);

  /// The model's own total, or null when no food came with figures. Counts
  /// only the foods that have some, so it is a floor, not a promise.
  double? get totalKcal {
    final values = [
      for (final item in items)
        if (item.kcal != null) item.kcal!,
    ];
    return values.isEmpty ? null : values.reduce((a, b) => a + b);
  }
}

/// The final word after a second opinion: the foods the model settled on and
/// a short account of what it changed and why.
class GuidedDecision {
  final GuidedEstimate estimate;

  /// Two or three sentences in the person's language, or empty.
  final String verdict;

  const GuidedDecision({required this.estimate, required this.verdict});
}
