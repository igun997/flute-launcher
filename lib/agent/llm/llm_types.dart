import 'dart:typed_data';

/// Wire-neutral chat types shared by every provider client, the tool loop and the UI.
/// Nothing here knows about HTTP; the clients map these to Chat Completions or Responses.

enum Role { system, user, assistant, tool }

sealed class Part {
  const Part();
}

class TextPart extends Part {
  const TextPart(this.text);
  final String text;
}

/// A picture the model should look at. JPEG, PNG or WebP.
class ImagePart extends Part {
  const ImagePart(this.bytes, {this.mime = 'image/jpeg'});
  final Uint8List bytes;
  final String mime;
}

/// A document sent as-is (PDF). Plain-text files are turned into [TextPart]s by the runtime.
class FilePart extends Part {
  const FilePart(this.bytes, {required this.name, required this.mime});
  final Uint8List bytes;
  final String name;
  final String mime;
}

class ToolCall {
  const ToolCall({required this.id, required this.name, required this.arguments});
  final String id;

  /// The name the model used; unique across built-in and MCP tools.
  final String name;
  final Map<String, dynamic> arguments;
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    this.parts = const [],
    this.toolCalls = const [],
    this.toolCallId,
    this.isError = false,
  });

  ChatMessage.text(Role role, String text) : this(role: role, parts: [TextPart(text)]);

  /// The result of one tool call, answering the assistant message that asked for it.
  ChatMessage.toolResult(String callId, String text, {bool error = false})
      : this(role: Role.tool, parts: [TextPart(text)], toolCallId: callId, isError: error);

  final Role role;
  final List<Part> parts;

  /// Only on assistant messages: what the model asked to run.
  final List<ToolCall> toolCalls;

  /// Only on tool messages: the call this answers.
  final String? toolCallId;
  final bool isError;

  String get text => parts.whereType<TextPart>().map((p) => p.text).join();
}

/// A function the model may call. [parameters] is a JSON Schema object.
class ToolSpec {
  const ToolSpec({required this.name, required this.description, required this.parameters});
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

class LlmRequest {
  const LlmRequest({required this.model, required this.messages, this.tools = const [], this.instructions});
  final String model;

  /// The conversation so far, without a system message: use [instructions].
  final List<ChatMessage> messages;
  final List<ToolSpec> tools;

  /// The system prompt (skills catalogue, date, rules).
  final String? instructions;
}

class Usage {
  const Usage({this.inputTokens, this.outputTokens});
  final int? inputTokens;
  final int? outputTokens;
}

enum FinishReason { stop, toolCalls, length, filtered, other }

sealed class LlmEvent {
  const LlmEvent();
}

class TextDelta extends LlmEvent {
  const TextDelta(this.text);
  final String text;
}

/// Model "thinking" text, when the provider streams it. Shown dimmed, never sent back.
class ReasoningDelta extends LlmEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// The stream ended. [toolCalls] is non-empty exactly when the model wants tools run.
class LlmFinished extends LlmEvent {
  const LlmFinished({required this.reason, this.toolCalls = const [], this.usage});
  final FinishReason reason;
  final List<ToolCall> toolCalls;
  final Usage? usage;
}

/// Thrown by clients for failures the user should read: bad key, quota, unknown model, network.
class LlmException implements Exception {
  const LlmException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;

  /// A provider error code such as `subscription_sharing_usage_limit_exceeded`.
  final String? code;

  bool get isAuth => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// One provider wire. Implementations: Chat Completions and Responses.
abstract class LlmClient {
  /// Streams one assistant turn. Cancelling the subscription aborts the request.
  /// Throws [LlmException] (before or during the stream) for provider and network errors.
  Stream<LlmEvent> stream(LlmRequest request);

  void close();
}
