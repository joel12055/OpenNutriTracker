import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/resolve_parsed_meals_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/search_products_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_photo_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/read_meal_text_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/bulk_add_bloc.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_estimate_meal.dart';
import 'package:opennutritracker/features/guided_meal/domain/guided_meal_entities.dart';
import 'package:opennutritracker/features/meal_detail/util/meal_quantity_converter.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

MealEntity _dbMeal(String name, {double? kcal}) => MealEntity(
  code: name,
  name: name,
  url: null,
  mealQuantity: null,
  mealUnit: null,
  servingQuantity: null,
  servingUnit: null,
  servingSize: null,
  source: MealSourceEntity.off,
  nutriments: MealNutrimentsEntity(
    energyKcal100: kcal,
    carbohydrates100: null,
    fat100: null,
    proteins100: null,
    sugars100: null,
    saturatedFat100: null,
    fiber100: null,
  ),
);

class _FakeSearch implements SearchProductsUseCase {
  final Map<String, List<MealEntity>> results;

  _FakeSearch(this.results);

  @override
  Future<SearchProductsResult> searchOFFProductsByString(
    String searchString, {
    bool skipRemote = false,
  }) async => SearchProductsResult(
    meals: results[searchString] ?? const [],
    remoteSourceEmpty: false,
  );

  @override
  Future<SearchProductsResult> searchFDCFoodByString(
    String searchString, {
    bool skipRemote = false,
    bool forResolution = false,
  }) async => const SearchProductsResult(meals: [], remoteSourceEmpty: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyStorage implements FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BulkAddBloc _bloc(Map<String, List<MealEntity>> results) => BulkAddBloc(
  ResolveParsedMealsUseCase(_FakeSearch(results)),
  ReadMealTextUseCase(
    AiCredentialStorage(_EmptyStorage()),
    (_) => throw StateError('no model here'),
  ),
  ReadMealPhotoUseCase(
    AiCredentialStorage(_EmptyStorage()),
    (_) => throw StateError('no model here'),
  ),
);

const _peas = GuidedNutritionPer100g(kcal: 70, protein: 5, carbs: 10, fat: 0.5);

Future<BulkAddLoadedState> _load(
  BulkAddBloc bloc,
  List<GuidedEstimateItem> items,
) async {
  bloc.add(
    LoadGuidedMealEvent(
      items: items,
      usesImperialUnits: false,
      estimatedSuffix: '(geschätzt)',
    ),
  );
  return await bloc.stream.firstWhere((s) => s is BulkAddLoadedState)
      as BulkAddLoadedState;
}

void main() {
  group('guidedEstimateMeal', () {
    test('carries the model figures and is recognisable as an estimate', () {
      final meal = guidedEstimateMeal(
        const GuidedEstimateItem(
          name: 'Erbsen',
          grams: 60,
          fallbackNutrition: _peas,
        ),
        '(geschätzt)',
      );

      expect(isGuidedEstimate(meal), isTrue);
      expect(meal.name, 'Erbsen (geschätzt)');
      expect(meal.nutriments.energyKcal100, 70);
      expect(meal.nutriments.proteins100, 5);
      expect(isGuidedEstimate(_dbMeal('Erbsen')), isFalse);
      expect(isGuidedEstimate(null), isFalse);
    });
  });

  group('LoadGuidedMealEvent', () {
    const peasItem = GuidedEstimateItem(
      name: 'Erbsen',
      grams: 60,
      fallbackNutrition: _peas,
    );

    test('a database match that agrees on energy is kept', () async {
      final bloc = _bloc({
        'Erbsen': [_dbMeal('Erbsen', kcal: 74)],
      });

      final row = (await _load(bloc, const [peasItem])).rows.single;

      expect(row.amountText, '60');
      expect(isGuidedEstimate(row.meal), isFalse);
      expect(row.meal!.nutriments.energyKcal100, 74);
      // The estimate stays on offer, last.
      expect(row.resolved.candidates, hasLength(2));
      expect(isGuidedEstimate(row.resolved.candidates.last), isTrue);
    });

    test('a match that disagrees on energy yields to the estimate', () async {
      // Peas the model puts at 70 kcal/100 g, matched to something at 250.
      final bloc = _bloc({
        'Erbsen': [_dbMeal('Erbsen', kcal: 250)],
      });

      final row = (await _load(bloc, const [peasItem])).rows.single;

      expect(isGuidedEstimate(row.meal), isTrue);
      expect(row.meal!.nutriments.energyKcal100, 70);
      expect(row.isLowConfidence, isFalse);
      // The database food is still there to switch to.
      expect(row.resolved.candidates, hasLength(2));
      expect(isGuidedEstimate(row.resolved.candidates.last), isFalse);
    });

    test('15 % away is the edge: inside it the database stays', () async {
      // The model says 70; the tolerance is max(15 % of 70, 10) = 10.5.
      final inside = _bloc({
        'Erbsen': [_dbMeal('Erbsen', kcal: 80)],
      });
      final outside = _bloc({
        'Erbsen': [_dbMeal('Erbsen', kcal: 85)],
      });

      final kept = (await _load(inside, const [peasItem])).rows.single;
      final yielded = (await _load(outside, const [peasItem])).rows.single;

      expect(isGuidedEstimate(kept.meal), isFalse);
      expect(isGuidedEstimate(yielded.meal), isTrue);
    });

    test('a ready meal 40 % below the home-made one yields', () async {
      // The case that prompted the rule: a shop's carbonara against the
      // model's figure for one cooked at home.
      final bloc = _bloc({
        'Spaghetti Carbonara': [_dbMeal('Spaghetti Carbonara', kcal: 130)],
      });

      final row = (await _load(bloc, const [
        GuidedEstimateItem(
          name: 'Spaghetti Carbonara',
          grams: 350,
          fallbackNutrition: GuidedNutritionPer100g(
            kcal: 215,
            protein: 9,
            carbs: 24,
            fat: 9,
          ),
        ),
      ])).rows.single;

      expect(isGuidedEstimate(row.meal), isTrue);
      expect(row.meal!.nutriments.energyKcal100, 215);
    });

    test('a match with no energy value yields to the estimate', () async {
      final bloc = _bloc({
        'Erbsen': [_dbMeal('Erbsen')],
      });

      final row = (await _load(bloc, const [peasItem])).rows.single;

      expect(isGuidedEstimate(row.meal), isTrue);
    });

    test('a weakly matched name yields even when the energy agrees', () async {
      // `rankForResolution` scores "Cadbury Creme Eggs Multipack" far below
      // the confidence floor for the query "Eier".
      final bloc = _bloc({
        'Eier': [_dbMeal('Cadbury Creme Eggs Multipack 5 Pack', kcal: 140)],
      });

      final row = (await _load(bloc, const [
        GuidedEstimateItem(
          name: 'Eier',
          grams: 120,
          fallbackNutrition: GuidedNutritionPer100g(
            kcal: 140,
            protein: 12,
            carbs: 1,
            fat: 10,
          ),
        ),
      ])).rows.single;

      expect(isGuidedEstimate(row.meal), isTrue);
    });

    test('with no match the estimate stands in and is the selection', () async {
      final bloc = _bloc({});

      final row = (await _load(bloc, const [peasItem])).rows.single;

      expect(row.isResolved, isTrue);
      expect(isGuidedEstimate(row.meal), isTrue);
      expect(row.isLowConfidence, isFalse);
      expect(row.amountText, '60');
    });

    test('with no match and no figures the row stays unresolved', () async {
      final bloc = _bloc({});

      final state = await _load(bloc, const [
        GuidedEstimateItem(name: 'Erbsen', grams: 60),
      ]);

      expect(state.rows.single.isResolved, isFalse);
    });

    test('a match is kept when the model gave no figures to compare', () async {
      final bloc = _bloc({
        'Erbsen': [_dbMeal('Erbsen', kcal: 250)],
      });

      final row = (await _load(bloc, const [
        GuidedEstimateItem(name: 'Erbsen', grams: 60),
      ])).rows.single;

      expect(isGuidedEstimate(row.meal), isFalse);
      expect(row.resolved.candidates, hasLength(1));
    });

    test('the row energy follows the estimate and the weight', () async {
      final bloc = _bloc({});

      final row = (await _load(bloc, const [
        GuidedEstimateItem(
          name: 'Schnitzel',
          grams: 180,
          fallbackNutrition: GuidedNutritionPer100g(
            kcal: 230,
            protein: 18,
            carbs: 12,
            fat: 12,
          ),
        ),
      ])).rows.single;

      // 180 g at 230 kcal per 100 g, in the unit the row was loaded with.
      expect(
        kcalForQuantity(180, row.effectiveUnit, row.meal!),
        closeTo(414, 0.01),
      );
    });
  });
}
