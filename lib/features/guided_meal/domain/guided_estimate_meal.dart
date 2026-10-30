import 'dart:math' as math;

import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';

const _estimateCodePrefix = 'ai-estimate:';

/// How far a database food's energy per 100 g may sit from the model's own
/// figure before the database food is judged to be a different food.
///
/// Tight on purpose. With the person's answers behind it the model's figure
/// has been right to within a few percent in use, so a database food 15 %
/// away is more likely a different product than the same food measured
/// differently.
///
/// A food name from a photo ("Schweineschnitzel, paniert") finds products and
/// records that share some of its words, and the name score the resolver
/// computes says nothing about whether the energy is right. Comparing the two
/// energy figures is what catches "a frozen schnitzel in a gratin" taking the
/// place of a plain one.
const _energyTolerance = 0.15;

/// The floor for that comparison, in kcal per 100 g, so near-zero foods such
/// as coffee or water are not judged on a percentage of almost nothing.
const _energySlack = 10.0;

/// A food built from the model's own per-100 g figures, for the review screen
/// to offer where no database knows the food.
///
/// Marked in two places: the code, which the screen reads to flag the row, and
/// [suffix] in the name, which is what survives into the diary afterwards so
/// the entry stays honest about where its numbers came from.
MealEntity guidedEstimateMeal(GuidedEstimateItem item, String suffix) {
  final nutrition = item.fallbackNutrition;
  return MealEntity(
    code: '$_estimateCodePrefix${item.name}',
    name: '${item.name} $suffix',
    url: null,
    mealQuantity: '100',
    mealUnit: 'g',
    servingQuantity: null,
    servingUnit: null,
    servingSize: null,
    nutriments: nutrition == null
        ? MealNutrimentsEntity.empty()
        : MealNutrimentsEntity(
            energyKcal100: nutrition.kcal,
            carbohydrates100: nutrition.carbs,
            fat100: nutrition.fat,
            proteins100: nutrition.protein,
            sugars100: null,
            saturatedFat100: null,
            fiber100: null,
          ),
    source: MealSourceEntity.unknown,
  );
}

/// Whether [meal] came from [guidedEstimateMeal] rather than a database.
bool isGuidedEstimate(MealEntity? meal) =>
    meal?.code?.startsWith(_estimateCodePrefix) ?? false;

/// Decides, for one food of the guided flow, which numbers the review row
/// starts from: the database's or the model's own.
///
/// - **No database match:** the model's figures, as the only choice.
/// - **A match whose energy agrees** with the model's figure (and whose name
///   matched well): the database food stays selected, as the more
///   authoritative source, and the estimate is offered last.
/// - **A match that disagrees, or matched weakly:** the estimate is selected
///   and the database foods follow it. The person asked for a meal worked out
///   from their answers; a wrong product silently replacing that is the worse
///   mistake, and every row still shows where its numbers came from and lets
///   them pick another.
///
/// Foods the model gave no figures for are returned as they are.
ResolvedMealItem mergeGuidedEstimate(
  ResolvedMealItem item,
  GuidedEstimateItem? estimated,
  String suffix,
) {
  final figures = estimated?.fallbackNutrition;
  if (estimated == null || figures == null) return item;
  final estimate = guidedEstimateMeal(estimated, suffix);

  // Its score is not a match quality, so it must not read as a weak match.
  ResolvedMealItem estimateFirst(List<MealEntity> rest) => ResolvedMealItem(
    parsed: item.parsed,
    candidates: [estimate, ...rest],
    selectedIndex: 0,
    confidence: 1.0,
  );

  if (!item.isResolved) return estimateFirst(const []);

  final databaseKcal = item.selected?.nutriments.energyKcal100;
  final agrees =
      !item.isLowConfidence &&
      databaseKcal != null &&
      (databaseKcal - figures.kcal).abs() <=
          math.max(figures.kcal * _energyTolerance, _energySlack);
  if (agrees) {
    return ResolvedMealItem(
      parsed: item.parsed,
      candidates: [...item.candidates, estimate],
      selectedIndex: item.selectedIndex,
      confidence: item.confidence,
    );
  }
  return estimateFirst(item.candidates);
}
