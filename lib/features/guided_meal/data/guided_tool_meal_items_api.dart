import 'dart:convert';

import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';
import 'package:opennutritracker/features/add_meal/util/meal_text_parser.dart';
import 'package:opennutritracker/features/guided_meal/data/guided_tool_client.dart';

/// The single-shot meal reader (typed lines and the plain photo reader) on top
/// of the guided flow's provider client.
///
/// For providers that client alone knows how to reach — today the ChatGPT
/// plan, which is served as a stream. The tool schema, the prompts and every
/// check that follows are the reader's own, unchanged: this only swaps how the
/// request travels.
class GuidedToolMealItemsApi implements MealItemsApi {
  final GuidedToolClient _client;
  final AiSelection _selection;
  final Duration? _timeout;

  GuidedToolMealItemsApi(this._client, this._selection, {Duration? timeout})
    : _timeout = timeout;

  @override
  Future<MealTextParseResult> requestItems({
    required MealContent content,
    required String system,
  }) async {
    final reply = await _client.call(
      _selection,
      GuidedToolRequest(
        system: system,
        text: switch (content) {
          MealTextContent(:final text) => text,
          MealPhotoContent() => mealPhotoContentPrompt,
        },
        photo: switch (content) {
          MealPhotoContent(:final mediaType, :final base64Data) => MealPhoto(
            bytes: base64Decode(base64Data),
            mediaType: mediaType,
          ),
          MealTextContent() => null,
        },
        toolName: mealItemsToolName,
        toolDescription: mealItemsToolDescription,
        schema: mealItemsToolSchema,
        maxTokens: 1024,
        timeout: _timeout,
      ),
    );

    return validateParsedMealItems(
      mealItemsFromJson(reply['items']),
      statedIn: content is MealTextContent ? content.text : null,
    );
  }
}
