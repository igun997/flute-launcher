# Flute agent: contract

An AI agent inside the launcher. Chat with a model from an OpenAI-compatible gateway, a ChatGPT
plan (Sign in with ChatGPT) or OpenRouter; tools from built-ins (calendar, contacts, notes) and
external MCP servers (GitHub, Jira, any Streamable HTTP server); skills pulled from GitHub with
`npx skills`-style commands; images and video as input; Markdown output; every write asks first.

English UI. Android only. Dart 3.13, Flutter 3.50, `import 'package:material_ui/material_ui.dart'`
(NOT material.dart). No flutter/dart commands in a slice: the owner of the build runs
`rflutter analyze` and `rflutter test` once at the end. Write compile-ready code. Never log or
print tokens, keys or message content.

Already written, do not edit (import them): `lib/agent/llm/llm_types.dart`,
`lib/agent/llm/model_info.dart`, `lib/agent/tools/agent_tool.dart`.

Dependencies available (already in pubspec): http, mcp_dart ^2.4.4, gpt_markdown, flutter_animate,
device_calendar_plus ^0.12.0, flutter_contacts ^2.6.0, image_picker, file_picker, url_launcher,
path_provider, crypto, archive ^4.7.1, yaml, uuid, flutter_secure_storage, shared_preferences.
Do not add others; say so in your final message if you need one.

Tests: `test/agent/<slice>/...`, flutter_test only, deterministic, `http` fakes via
`package:http/testing.dart` `MockClient` / `MockClient.streamed`. Test behavior a user would hit
(wire parsing, error mapping, permission denial), not wiring.

## Slice A: LLM wire (`lib/agent/llm/`)

Files: `chat_completions_client.dart`, `responses_client.dart`, `model_catalog.dart`, `sse.dart`.

```dart
class ChatCompletionsClient implements LlmClient {
  ChatCompletionsClient({
    required String baseUrl,                       // https://host/v1, no trailing slash
    required Future<String> Function() apiKey,     // called per request
    Map<String, String> extraHeaders = const {},
    http.Client? httpClient,
  });
}
class ResponsesClient implements LlmClient {
  ResponsesClient({
    required String baseUrl,                       // https://api.openai.com/v1
    required Future<String> Function() accessToken,
    Map<String, String> extraHeaders = const {},
    http.Client? httpClient,
  });
}
class ModelCatalog {
  static Future<List<ModelInfo>> fetch({required ProviderKind kind, required String baseUrl,
      required String token, http.Client? httpClient});
  /// Case-insensitive; every whitespace-separated token must occur in id, name or ownedBy.
  /// Ranking: id starts with query, id contains, name contains; then alphabetical.
  static List<ModelInfo> search(List<ModelInfo> all, String query);
  static List<ModelInfo>? loadCache(SharedPreferences prefs, String profileId);
  static Future<void> saveCache(SharedPreferences prefs, String profileId, List<ModelInfo> models);
}
```

**ChatCompletionsClient**: `POST {baseUrl}/chat/completions`, headers `Authorization: Bearer <key>`,
`Content-Type: application/json`, `Accept: text/event-stream`. Body: `model`, `messages`,
`stream:true`, `stream_options:{include_usage:true}`, `tools` (as `{type:function,function:{name,
description,parameters}}`, only when non-empty). The system prompt is `request.instructions` as a
first `system` message. Mapping: user parts: TextPart -> `{type:text}`, ImagePart ->
`{type:image_url,image_url:{url:"data:<mime>;base64,..."}}`, FilePart -> `{type:file,file:{filename,
file_data:"data:<mime>;base64,..."}}`; plain string content when only one TextPart. Assistant with
`toolCalls` -> `tool_calls:[{id,type:function,function:{name,arguments:<json string>}}]`, `content`
null when empty. Tool results -> `{role:tool, tool_call_id, content}`. A tool result can never carry
images. Streaming: SSE `data:` lines, `[DONE]` ends. Accumulate `delta.tool_calls` by `index`
(id/name arrive once, `arguments` arrives in fragments; some gateways repeat id/name on every
fragment or send the whole call in one chunk: both must work). Emit `TextDelta` for
`delta.content`; `ReasoningDelta` for `delta.reasoning_content` or `delta.reasoning`. Finish
reason: `stop`, `tool_calls`, `length`, `content_filter`. Usage from the final chunk (`usage`).
Emit `LlmFinished(toolCalls: ...)` once at the end; reason is `toolCalls` when calls exist.
Unparseable tool arguments -> `{}` plus the raw text under key `_raw`. If the response is
`application/json` (server ignored `stream`) parse it as one completion and emit the same events.
If status is 400 and the body mentions `stream_options`, retry once without it. Errors: status >= 400
-> `LlmException(message from {error:{message,code}} or body prefix, statusCode, code)`; never
include the request or key. Socket/timeout -> `LlmException('Cannot reach <host>')`. 401/403
messages should say the key was refused.

**ResponsesClient**: `POST {baseUrl}/responses`. Body exactly: `model`, `instructions`,
`input` (array), `tools` (only when non-empty, `{type:function,name,description,parameters}`),
`store:false`, `stream:true`. NEVER send `temperature`, `max_output_tokens`, `metadata`, `user`,
`truncation`, `previous_response_id`, `conversation`, `top_p` or system-role items (this endpoint
rejects them). Input mapping: user -> `{role:user,content:[{type:input_text,text},{type:input_image,
image_url:"data:..."},{type:input_file,filename,file_data:"data:..."}]}`; assistant text ->
`{role:assistant,content:[{type:output_text,text}]}`; assistant tool call -> `{type:function_call,
call_id,name,arguments:<json string>}`; tool result -> `{type:function_call_output,call_id,output}`.
Events (`event:`/`data:` JSON with `type`): `response.output_text.delta` -> TextDelta;
`response.reasoning_summary_text.delta` and `response.reasoning_text.delta` -> ReasoningDelta;
`response.output_item.added`/`.done` for `item.type == function_call` (collect `call_id`, `name`,
`arguments`; `response.function_call_arguments.delta/.done` fill arguments by `item_id`);
`response.completed` -> success (usage from `response.usage`); `response.failed` ->
`LlmException(error.message, code: error.code)` (codes such as
`subscription_sharing_usage_limit_exceeded` / `subscription_sharing_usage_unavailable` get a
friendly message: "Your ChatGPT plan limit for apps is used up. Wait for it to reset or raise the
limit in ChatGPT > Settings > Usage."); `response.incomplete` -> finish with reason `length`;
`error` event -> LlmException. A stream that ends without `response.completed`/`incomplete`/
`failed` -> `LlmException('The reply was cut off')`. Finish reason is `toolCalls` when any
function_call was collected, else `stop`.

**ModelCatalog.fetch**: `GET {baseUrl}/models` with bearer. Accept all of: OpenAI
`{data:[{id,owned_by}]}`; OpenRouter (`name`, `context_length`, `architecture.input_modalities`
containing `image` -> acceptsImages, `pricing.prompt` is USD per token -> per million);
ChatGPT plan `{models:[{slug,display_name,visibility}]}` keep only `visibility == "list"` (or
missing), id = slug; plain list `[{id}]`; Ollama-style `{models:[{name,model}]}`. Sort by name,
dedupe by id. Errors -> LlmException like the clients. `saveCache`/`loadCache` store JSON under
`agent.models.<profileId>`.

**sse.dart**: a small `Stream<SseEvent> parseSse(Stream<List<int>> bytes)` (`event`, `data`
joined with `\n`; comments and blank keep-alives ignored; handles CRLF and chunks that split a
line or a UTF-8 character). Shared by both clients.

## Slice B: sign-in and providers (`lib/agent/auth/`)

Files: `secret_store.dart`, `pkce.dart`, `loopback_server.dart`, `chatgpt_oauth.dart`,
`openrouter_oauth.dart`, `provider_store.dart`.

```dart
abstract class SecretStore { Future<String?> read(String key); Future<void> write(String key, String value); Future<void> delete(String key); }
class SecureSecretStore implements SecretStore { ... flutter_secure_storage ... }
class MemorySecretStore implements SecretStore { ... }   // tests

class Pkce { final String verifier; final String challenge; static Pkce generate(); static String randomUrlSafe([int bytes = 32]); }

class LoopbackServer {
  /// Binds 127.0.0.1 (port 0 = any free port unless [port] is given).
  static Future<LoopbackServer> start({int port = 0, String path = '/auth/callback'});
  int get port;
  Uri redirectUri({String host = '127.0.0.1'});            // http://<host>:<port><path>
  /// First request on [path]: its query parameters. Answers the browser with a small page
  /// ("Signed in. You can return to Flute.") and closes. Times out with TimeoutException.
  Future<Map<String, String>> waitForCallback({Duration timeout = const Duration(minutes: 5)});
  Future<void> close();
}

class ProviderStore extends ChangeNotifier {
  ProviderStore({required SharedPreferences prefs, required SecretStore secrets,
      http.Client? httpClient, Future<bool> Function(Uri url)? openBrowser /* default: url_launcher externalApplication */});
  Future<void> load();
  List<ProviderProfile> get profiles;
  ProviderProfile? get active;                          // null until one exists
  Future<ProviderProfile> addApiKeyProfile({required String label, required String baseUrl, required String apiKey});
  Future<ProviderProfile> signInWithOpenRouter();       // profile: label 'OpenRouter', https://openrouter.ai/api/v1, ProviderAuth.openrouterOAuth, kind openaiCompatible
  Future<ProviderProfile> signInWithChatGpt();          // profile: label 'ChatGPT plan', https://api.openai.com/v1, kind chatgptPlan, ProviderAuth.chatgptOAuth
  void cancelSignIn();                                  // closes the loopback wait; the pending sign-in future throws a cancel LlmException
  bool get signingIn;
  Future<void> setActive(String id);
  Future<void> setModel(String id, String model);
  Future<void> updateApiKeyProfile(String id, {String? label, String? baseUrl, String? apiKey});
  Future<void> remove(String id);                       // also deletes its secrets
  Future<String> tokenFor(String id);                   // API key, or a ChatGPT access token refreshed when < 2 min from expiry; LlmException(statusCode: 401) when the session is gone
  String? accountLabel(String id);                      // ChatGPT email; null otherwise
}
```
Profiles persist as JSON list in prefs `agent.profiles`, active id in `agent.active`. Secrets:
`agent.key.<id>` (API key / OpenRouter key), `agent.chatgpt.<id>` (JSON credential record).
Baseurl is normalised (trim, drop trailing `/`). `addApiKeyProfile` validates the URL is https
(http allowed only for localhost / 10.x / 192.168.x / 100.x.x.x for self-hosted gateways).

**Sign in with ChatGPT** (official flow for open-source local apps). Read the docs first, they
are authoritative: https://developers.openai.com/siwc/token-sharing-open-source.md and the pages
`/sign-in.md`, `/profiles-and-sessions.md`, `/token-reference.md`, `/errors-and-recovery.md` under
`https://developers.openai.com/siwc/token-sharing-open-source/`. Summary: persist a stable
`ext_agent_host_id = urn:uuid:<v4>` (prefs, created once). First time: authorize at
`https://auth.openai.com/api/accounts/authorize` with `client_id=dynamic_agent_client`,
`agent_name_hint=Flute`, `ext_agent_host_id`, `response_type=code`,
`redirect_uri=http://127.0.0.1:<port>/auth/callback` (LoopbackServer, port 1455 first, fall back
to any), `scope=openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`,
`resource=https://api.openai.com/v1`, `state`, `nonce`, PKCE S256. The callback returns `code`,
`state`, issued `client_id` (save it; use it for the token exchange and later sign-ins). Exchange
at `https://auth.openai.com/api/accounts/oauth/token` (form-encoded, no secret, same
redirect_uri and resource). Check `state`; check the granted scope contains
`chatgpt.tokens.use.direct` (else throw `LlmException('ChatGPT plan use was not allowed ...')`);
decode the ID token claims (signature check may be skipped because the token came straight from
the token endpoint over TLS, say so in a comment) and verify `iss`, `aud == client_id`, `exp`,
`nonce`. Refresh per the docs (rotating refresh token: replace access token, refresh token,
expiry and scopes together, atomically). Revoked/invalid_grant on refresh -> delete the
credential and throw LlmException(statusCode: 401, 'Sign in with ChatGPT again').

**OpenRouter**: PKCE per https://openrouter.ai/docs/guides/overview/auth/oauth.md. Loopback
redirect `http://localhost:<port>/callback` (LoopbackServer(path: '/callback'),
`redirectUri(host: 'localhost')`), `https://openrouter.ai/auth?callback_url=...&code_challenge=...
&code_challenge_method=S256&key_label=Flute`, then `POST https://openrouter.ai/api/v1/auth/keys`
`{code, code_verifier, code_challenge_method:'S256'}` -> `{key}` stored as the profile key.

Tests: PKCE (RFC 7636 appendix B vector), loopback callback parsing, ChatGPT authorize URL has
every required parameter, token exchange/refresh with MockClient (including rotating refresh and
revoked refresh), tokenFor refresh window, OpenRouter exchange, profile persistence round trip,
https validation.

## Slice C: built-in tools and device media (`lib/agent/tools/`, android)

Files: `notes_store.dart`, `notes_tools.dart`, `calendar_backend.dart`, `calendar_tools.dart`,
`contacts_backend.dart`, `contact_tools.dart`, `time_tools.dart`, `builtin_tools.dart`.

```dart
class BuiltinTools implements ToolSource {
  BuiltinTools({required SharedPreferences prefs, NotesStore? notes, CalendarBackend? calendar, ContactsBackend? contacts});
  static const groups = ['calendar', 'contacts', 'notes'];     // 'time' tools are always on
  bool isEnabled(String group);                  // prefs agent.tools.<group>, default true for notes, false for calendar/contacts
  Future<void> setEnabled(String group, bool on);
  Future<bool> hasPermission(String group);      // notes: true
  Future<bool> requestPermission(String group);  // system dialog (calendar: READ+WRITE_CALENDAR; contacts: READ+WRITE_CONTACTS)
  @override List<AgentTool> get tools;           // enabled groups only, plus time
  @override Stream<void> get changes;
}
```
`CalendarBackend` / `ContactsBackend` are small abstract classes wrapping `device_calendar_plus`
and `flutter_contacts` (read the packages' docs on pub.dev for the exact API; default
implementations `DeviceCalendarBackend` / `DeviceContactsBackend`), so tools can be tested with
fakes. A tool call whose permission is missing requests it once, then returns
`ToolResult.error('Calendar access was denied. Turn it on in Settings > Apps > Flute > Permissions.')`
if refused. Tool names (exact): `current_time` (read), `notes_list`, `notes_search`, `notes_read`
(read), `notes_create`, `notes_update`, `notes_delete` (write); `calendar_list_calendars`,
`calendar_list_events` (read), `calendar_create_event`, `calendar_update_event`,
`calendar_delete_event` (write); `contacts_search`, `contacts_get` (read), `contacts_create`,
`contacts_update`, `contacts_delete` (write). Arguments are small flat JSON objects; dates are
ISO 8601 local (`2026-11-20T14:00`) and all-day is `allDay:true` with `YYYY-MM-DD`. Results are
compact plain text or JSON (ids included so the model can follow up), lists capped (default 25).
Every write tool's `describeCall` is a readable sentence with the real values; delete tools say
what will be deleted by looking it up first. `NotesStore`: JSON file `notes.json` in
`getApplicationSupportDirectory()`, notes `{id,title,body,createdAt,updatedAt}`, serialised
writes, atomic replace; constructor takes an optional `File` for tests.

Android: add `READ_CALENDAR`, `WRITE_CALENDAR`, `READ_CONTACTS`, `WRITE_CONTACTS` to
`android/app/src/main/AndroidManifest.xml`. Video frames for models that only take images: add to
`android/app/src/main/kotlin/id/nst/focus_launcher/FluteNative.kt` a method-channel call
`extractVideoFrames {path, count, maxEdge}` -> list of JPEG byte arrays, evenly spaced across the
duration, using `MediaMetadataRetriever.getFrameAtTime(..., OPTION_CLOSEST_SYNC)`, scaled so the
longest edge is `maxEdge` (default 768), quality 80, run off the main thread, release the
retriever, error -> null; plus `videoInfo {path}` -> `{durationMs,width,height}`. Add Dart
wrappers `FluteNative.extractVideoFrames(String path, {int count = 6, int maxEdge = 768})` ->
`Future<List<Uint8List>>` and `FluteNative.videoInfo(String path)` in
`lib/native/flute_native.dart` (follow the file's existing `_call` pattern; read the file first).
Content URIs: `image_picker`/`file_picker` return real file paths, so paths only.

Tests: NotesStore round trip and concurrent writes; each tool with fake backends (argument
parsing, date handling, permission denied, describeCall text); `BuiltinTools` enable/disable
and `changes`.

## Slice D: MCP servers and skills (`lib/agent/mcp/`, `lib/agent/skills/`)

Files: `mcp/mcp_server_config.dart`, `mcp/mcp_manager.dart`, `mcp/mcp_presets.dart`,
`skills/skill.dart`, `skills/skill_manager.dart`, `skills/skill_commands.dart`,
`skills/skill_tools.dart`.

```dart
enum McpAuthKind { none, bearer, basic, header }
class McpServerConfig { final String id, name, url; final McpAuthKind auth; final String? headerName; final bool enabled; final bool readOnly; /* extra X-MCP-Readonly style header handled by preset */ ... toJson/fromJson/copyWith }
enum McpStatus { disconnected, connecting, connected, failed }
class McpPreset { final String key, title, description, url; final McpAuthKind auth; final String secretLabel; final String helpUrl; final Map<String,String> headers; }
class McpPresets { static const github = ...; static const jira = ...; static List<McpPreset> all; }

class McpManager extends ChangeNotifier implements ToolSource {
  McpManager({required SharedPreferences prefs, required SecretStore secrets, http.Client? httpClient});
  Future<void> load();                          // reads configs; does not connect
  List<McpServerConfig> get servers;
  McpStatus statusOf(String id); String? errorOf(String id); List<AgentTool> toolsOf(String id);
  Future<McpServerConfig> add({required String name, required String url, McpAuthKind auth = McpAuthKind.none, String? headerName, String? secret});
  Future<McpServerConfig> addPreset(McpPreset preset, {required String secret});   // jira: secret = base64("email:apiToken") built by McpPresets.jiraBasic(email, apiToken)
  Future<void> update(String id, {String? name, String? url, String? secret});
  Future<void> remove(String id);
  Future<void> setEnabled(String id, bool on);  // enabling connects, disabling disconnects
  Future<void> connect(String id);              // Streamable HTTP via mcp_dart; initialize, listTools; failure -> status failed + errorOf
  Future<void> disconnect(String id);
  Future<void> connectEnabled();                // fire-and-forget on app start / agent open, bounded 15 s per server
  Future<void> setToolDisabled(String serverId, String toolName, bool disabled);
  bool isToolDisabled(String serverId, String toolName);
  @override List<AgentTool> get tools;          // connected servers, non-disabled tools
  @override Stream<void> get changes;
}
```
Secrets in `agent.mcp.<id>`. Tool names: `<serverSlug>__<toolName>` sanitised to
`[a-zA-Z0-9_-]`, max 64 (truncate the server slug first, keep uniqueness with a numeric suffix).
Risk: `read` only when the MCP tool's annotation `readOnlyHint == true` (mcp_dart exposes tool
annotations; check its API), everything else `write`. `describeCall`: "<server>: <tool>" plus
the first few arguments as `key: value` (values cut to 80 chars, secrets never). `run`: calls the
tool, joins text content, notes images as `[image]`, `isError` -> ToolResult.error; truncate to
12 000 characters with a trailing "...(truncated)". Reconnect once on a session error. Remote
Streamable HTTP only (Android cannot run stdio servers): reject `http://` except localhost/LAN.
Auth headers: bearer -> `Authorization: Bearer <secret>`, basic -> `Authorization: Basic <secret>`
(secret already base64), header -> `<headerName>: <secret>`. Read mcp_dart's source/docs
(`StreamableHttpClientTransport`, `StreamableHttpClientTransportOptions(requestInit / headers)`)
for how to attach headers; if headers need a custom `http.Client`, wrap one that adds them.
Presets: GitHub `https://api.githubcopilot.com/mcp/`, bearer PAT; Atlassian
`https://mcp.atlassian.com/v2/mcp`, basic from email + API token (the admin must allow API
tokens; `McpPresets.jiraBasic(email, token)` returns the base64).

Skills (the `npx skills` format by vercel-labs, https://github.com/vercel-labs/skills, read its
README and docs/commands.md): a skill is a folder with `SKILL.md` (YAML frontmatter `name`,
`description`, markdown body) plus optional files.

```dart
class Skill { final String name, description, source; final String? ref; final String dir; /* absolute */ ... }
class SkillOffer { final String name, description, path; }      // found in a repo, not installed
class SkillManager extends ChangeNotifier {
  SkillManager({required Directory root /* tests */, http.Client? httpClient, String? githubToken Function()?});
  static Future<SkillManager> open({http.Client? httpClient});   // root = <app support>/skills
  Future<void> load();
  List<Skill> get installed;
  Future<List<SkillOffer>> list(String source);                  // npx skills add <src> --list
  Future<List<Skill>> add(String source, {List<String> names = const [], bool all = false});
  Future<List<SkillOffer>> find(String query);                   // npx skills find: use the skills.sh search API (find it in the repo's source)
  Future<List<String>> check();                                  // names with updates
  Future<List<Skill>> update([List<String> names = const []]);
  Future<void> remove(String name);
  String catalogue();                                            // "- name: description" lines for the system prompt, '' when none
  String? bodyOf(String name);                                   // SKILL.md body without frontmatter
  Future<String?> readFile(String name, String relativePath);   // safe: no .. or absolute paths, 64 KB cap
}
class SkillCommands {
  SkillCommands(SkillManager skills);
  static bool matches(String input);        // "npx skills ...", "skills ...", "/skills ..." (first word)
  Future<String> run(String input);         // markdown for the chat: lists, progress summary, errors
}
class SkillTools implements ToolSource { SkillTools(SkillManager m); }   // tools: skill_load(name) read, skill_read_file(name, path) read
```
Sources: `owner/repo`, `owner/repo@ref`, `owner/repo@skill-name`, full GitHub URL, `.../tree/<ref>/<path>`,
and direct `.zip`/`.tar.gz`/SKILL.md URLs. Fetch GitHub archives from
`https://codeload.github.com/<owner>/<repo>/zip/<ref or HEAD>` (no API rate limit; private repos
use the optional token). Find skills: every directory with a `SKILL.md` (search root,
`skills/`, `skills/.curated`, `.agents/skills`, nested one level). Limits as the CLI: download
10 MiB, extracted 25 MiB, 1000 files; reject path traversal and symlinks. Install copies the
skill dir to `<root>/<name>/`; `skills-lock.json` records source, ref, resolved commit if known,
content hash. `add` with no names and several skills found and not `all` returns the offers
without installing (the command output tells the user the exact command to run). Commands:
`add`, `list|ls`, `find`, `check`, `update`, `remove|rm`, `--skill/-s`, `--list/-l`, `--all`, `-y`
ignored. Skills are prompt text only: never run scripts from a skill.

Tests: MCP manager with a fake transport/MockClient where feasible (config persistence, tool
naming/uniqueness, risk mapping, disabled tools, status transitions); `McpPresets.jiraBasic`;
skills: parse frontmatter, discover in a built-in zip fixture (create it in the test with
`archive`), path traversal rejected, size limits, add/remove/update/lock, command parsing and
output, `catalogue`.

## Slice E: UI (`lib/agent/ui/`)

Files: `agent_page.dart`, `chat_bubbles.dart`, `composer.dart`, `confirm_controller.dart`,
`confirm_sheet.dart`, `model_picker.dart`, `agent_settings_page.dart`, `mcp_settings.dart`,
`skills_settings.dart`.

The runtime (written by the owner) exposes:

```dart
// lib/agent/runtime/agent_runtime.dart
enum AttachmentKind { image, video, file }
class Attachment { final AttachmentKind kind; final String path; final String name; Attachment({required this.kind, required this.path, required this.name}); }
enum ToolState { waiting, running, done, denied, failed }
sealed class ChatItem { String get id; }
class UserItem extends ChatItem { String text; List<Attachment> attachments; }
class AssistantItem extends ChatItem { String text; String reasoning; bool streaming; String? error; }
class ToolItem extends ChatItem { String toolName; String source; String summary; ToolState state; String? output; }
class NoticeItem extends ChatItem { String text; /* markdown */ }
class AgentRuntime extends ChangeNotifier {
  List<ChatItem> get items; bool get busy; String? get setupProblem; // null when ready to chat
  ProviderProfile? get profile; String? get model;
  Future<void> send(String text, {List<Attachment> attachments = const []});
  void cancel(); void newChat();
  List<String> get slashHints;  // ['skills add owner/repo', ...]
}
```
and the app object `Flute` (lib/app/flute.dart) gains: `ProviderStore providers`,
`McpManager mcp`, `SkillManager skills`, `BuiltinTools builtins`, `AgentRuntime agent`,
`ConfirmController confirm` (E writes this class: `class ConfirmController extends ChangeNotifier
implements Confirmer { ConfirmRequest? get pending; void resolve(ConfirmDecision d); }`, `ask`
completes when `resolve` is called; a second `ask` while one is pending waits its turn; session
allowances are remembered per tool name inside the controller; a `reset()` clears them).

`AgentPage({required Flute flute, required VoidCallback onClose})`: full-screen, dark sky-ink
styling consistent with the app (look at `lib/home/settings_page.dart` and `lib/app/theme.dart`
for colors, text styles and `SkyInk`), top bar (back, title "Ask Flute", model chip that opens
`showModelPicker`, overflow: New chat, Settings), message list that sticks to the bottom while
streaming and stops sticking when the user scrolls up, composer pinned above the keyboard
(multi-line text field, attach button -> sheet with Photo, Camera, Video, File via
`image_picker` / `file_picker`, thumbnails with remove, send/stop button, `/` shows slash hints).
Messages: user bubbles right, assistant left rendered with `GptMarkdown` (code blocks with copy
button, tables, links open with url_launcher, LaTeX), streaming caret, "Thinking" collapsible for
reasoning, tool cards (icon by source, summary, state chip, expandable output), image/video
thumbnails in user bubbles (video shows a play badge; thumbnails via `Image.file` for images,
a dark tile with the file name for video). Motion with `flutter_animate`: messages fade+slide in
(160 ms), the typing dots, tool card state transitions, send button morph; keep every animation
cheap (no per-frame rebuild of the whole list) and respect
`MediaQuery.disableAnimations`. Empty state: a short greeting and 3 tappable example prompts.
A setup banner when `runtime.setupProblem != null` ("Add a provider to start") with a button to
Agent settings. The confirm sheet (`showConfirmSheet` driven by `ConfirmController`, listened to
in `AgentPage`): shows the tool source icon, `summary`, the arguments as a compact key/value list,
buttons Allow once / Allow for this chat / Deny; cannot be dismissed by tapping outside (deny on
back); the whole app stays usable while it is up.

`showModelPicker(BuildContext, {required Flute flute})`: bottom sheet. On open: show the cached
list immediately (`ModelCatalog.loadCache`) and refresh from the provider in the background
(`ModelCatalog.fetch` with `providers.tokenFor`), spinner/retry state, count ("312 models"), a
search field filtering live with `ModelCatalog.search`, rows with name, id, context length and an
image badge, the current one checked, tap selects via `providers.setModel` and closes.

`AgentSettingsPage({required Flute flute})`: sections. PROVIDER: list profiles (radio = active),
each with model, edit (label/URL/key), delete; buttons "Sign in with ChatGPT", "Connect
OpenRouter", "Add OpenAI-compatible gateway" (name, base URL, API key; password field; paste
friendly; validates and shows the model count after saving by calling the catalog). While a sign-in
is running show "Finish in your browser" with Cancel (`providers.cancelSignIn`). Branding: the
ChatGPT button reads "Continue with ChatGPT"; no logos. Note under it: "Uses your ChatGPT plan
allowance. Manage app limits in ChatGPT > Settings > Usage." TOOLS: switches for Calendar,
Contacts, Notes (`builtins`), turning one on requests the permission when missing; MCP SERVERS
(`mcp_settings.dart`): list with status dot, tool count, enable switch, tap -> detail page with
tools (switch per tool, a "needs confirmation" tag for write tools), reconnect, edit, delete;
"Add server": presets GitHub and Jira (token fields with the right help text and a link button
via url_launcher), and "Custom server" (name, URL, auth type, token). SKILLS (`skills_settings.dart`):
installed list (name, description, source, remove), an "Add skill" field that accepts the same
text as the command (`owner/repo`) showing the found skills with checkboxes, and "Check for
updates"; a hint that `skills add owner/repo` also works in the chat.

All sheets/pages follow the existing visual language (dark surfaces `FluteColors`, tile radius
16, teal accent). Never show a token or key after it was saved (show "Saved" / last 4 only).
Tests: widget tests for the confirm flow (`ConfirmController` ordering, session allowance),
`showModelPicker` filtering with a fake catalog is optional; keep UI tests few and meaningful.

## Owner

The runtime, `Flute` wiring, the Shell entry (swipe right from Home), integration and the build.

# v2 additions

Same rules as above (no flutter/dart/rflutter in a slice; the owner builds; English UI; `material_ui`;
never log secrets or message content; tests under `test/agent/<slice>/`). Read the existing files you
touch first. Shared interfaces already present: `AgentTool`, `ToolSource`, `ToolRisk`, `Confirmer`
(lib/agent/tools/agent_tool.dart), `SecretStore` (lib/agent/auth/secret_store.dart), `LlmClient` types,
`AgentRuntime` (lib/agent/runtime/agent_runtime.dart, owner only), `Flute` (lib/app/flute.dart, owner only).
Settings sections are written as separate widget files and wired by the owner into
`agent_settings_page.dart`: each section is a `StatelessWidget`/`StatefulWidget` taking
`{required Flute flute}`; the owner adds the fields below to `Flute`.

## Slice L: launcher control and fixes (AgentLauncher)
Files: `lib/agent/tools/launcher_tools.dart`, edits to `builtin_tools.dart`, `calendar_tools.dart`,
`contact_tools.dart`, `lib/agent/ui/composer.dart`, `lib/home/shell.dart`, `lib/home/settings_page.dart`,
`lib/agent/ui/agent_settings_page.dart` (bottom padding only), `lib/app/flute.dart` (only the
`externalFlow` helper below), tests.
1. **Launcher tools** (group `launcher`, default on, risk: reads `read` + source `launcher`, all
   changes `write`). The agent manages the launcher through `ModeEngine`, `AppRepository`, `LockSettings`,
   `FluteNative` (read lib/core/mode_engine.dart, models.dart, app_repository.dart, lib/home/mode_sheet.dart,
   lib/home/settings_page.dart to learn every capability; cover what the UI can do). Tool names (exact):
   `launcher_status` (current mode, until when, schedules, favorites, DND state), `launcher_set_mode`
   (mode free|work|focus|sleep, optional minutes), `launcher_wake_up`, `launcher_list_schedules`,
   `launcher_add_schedule` / `launcher_update_schedule` / `launcher_delete_schedule` (days, start, end,
   mode, name), `launcher_list_apps` (query optional, category optional, limit default 50; no parameters
   lists the first apps), `launcher_set_app_category`, `launcher_pin_app` / `launcher_unpin_app`,
   `launcher_list_pins`, `launcher_set_always_allowed` if the engine has that rule, `launcher_set_setting`
   for simple toggles that exist (pets on/off, follow location, lockscreen) only if safe. Describe each
   call with real values. `current_time` stays in time tools.
2. **Calendar**: `calendar_list_events` must take `from`/`to` (ISO local or `YYYY-MM-DD`, to inclusive for
   dates), default today to +7 days, `limit` default 50 (max 200), optional `calendarId`, and say in
   the result how many matched and whether the list was cut. A range longer than 366 days is clamped
   with a note. **Contacts**: `contacts_search` with NO parameters returns the first contacts (name order)
   up to `limit` (default 25, max 100); with `query` it searches name, phone, email, company; result says
   total and whether cut. Fix wording in the tool descriptions so the model calls them without asking
   the user for parameters.
3. **Camera/picker bug**: coming back from the camera or a picker lands on Home instead of attaching.
   Cause: `Shell.didChangeAppLifecycleState` calls `_goHome()` on every resume after a background.
   Add `Flute.externalFlow<T>(Future<T> Function() run)` (counter + a 2 s grace after it ends) and make
   Shell skip `_goHome` while it is active; wrap every `image_picker` / `file_picker` call in
   composer.dart with it. Verify nothing else can cause the page to change (the Home button still
   goes Home via the native `homePressed` event). Also keep the composer's draft and the chat intact.
   Add a widget/unit test for the guard timing.
4. **Settings bottom clip**: the last item of `SettingsPage` (and `AgentSettingsPage`, `McpServerPage`,
   other long pages in lib/agent/ui) is hidden behind the system navigation bar. Add bottom padding
   `MediaQuery.paddingOf(context).bottom + 24` to every long ListView/scroll body in lib/home/settings_page.dart and
   lib/agent/ui/agent_settings_page.dart (other ui files are owned by other agents; list the ones you
   did not touch in your final message).

## Slice W: web tools (AgentWeb)
Files: `lib/agent/web/web_settings.dart` (prefs/secrets), `lib/agent/web/web_tools.dart`,
`lib/agent/ui/web_settings_section.dart`, tests. Providers: **Tavily** (https://docs.tavily.com: `POST
https://api.tavily.com/search`, `/extract`) and **Firecrawl** (https://docs.firecrawl.dev: v2 `search`,
`scrape`, `/v2/...` Bearer key). Read both docs for the current API and use them exactly.
```dart
enum WebProvider { tavily, firecrawl }
class WebSettings extends ChangeNotifier {
  WebSettings({required SharedPreferences prefs, required SecretStore secrets, http.Client? httpClient});
  Future<void> load();
  WebProvider? get provider;            // active one, null when no key saved
  bool hasKey(WebProvider p);
  Future<void> saveKey(WebProvider p, String key);   // validates with a tiny request, throws a readable error
  Future<void> removeKey(WebProvider p);
  Future<void> setProvider(WebProvider p);
}
class WebTools implements ToolSource { WebTools(WebSettings s, {http.Client? httpClient}); }
```
Tools (source `web`, risk `read`, no confirmation): `web_search` (query, max_results default 5, optional
`time_range`, `include_domains`), `web_fetch` (url -> clean markdown text, truncated to 12 000 chars with a note),
plus provider extras if natural (`web_map`/crawl are out). Results are compact markdown with titles, urls
and snippets, never raw JSON; errors map to readable `ToolResult.error`. Tools are only listed when a key is saved. Never send
the user's personal data in a search unless the model chose it. URL safety: only http(s), refuse localhost/private
IPs for `web_fetch`. `WebSettingsSection({required Flute flute})` in the UI file: provider choice, key
fields (saved keys never shown again, only "Saved"), remove, a "Get a key" link (url_launcher).
Also check that **tables render** in chat: read lib/agent/ui/chat_bubbles.dart and the gpt_markdown
version in pubspec.lock; write a widget test rendering a GitHub-style table inside `AssistantMessage`
(header row, alignment colons, inline `code` and **bold** in cells, a long table that must scroll
horizontally instead of overflowing) and fix chat_bubbles.dart if it fails or overflows (you own
chat_bubbles.dart for this task).

## Slice O: MCP OAuth (AgentMcpOauth)
Files: `lib/agent/mcp/mcp_oauth.dart`, edits to `mcp_manager.dart`, `mcp_server_config.dart`,
`mcp_presets.dart`, `lib/agent/ui/mcp_settings.dart`, tests in test/agent/mcp/.
Add `McpAuthKind.oauth`: sign in through the browser, no token typing. Follow the MCP authorization
spec (https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization): on 401 read
`WWW-Authenticate` / `/.well-known/oauth-protected-resource`, then `/.well-known/oauth-authorization-server`
(or OIDC discovery), **dynamic client registration** (RFC 7591) with `client_name: Flute`, a loopback
`redirect_uri` (`http://127.0.0.1:<port>/callback`, reuse `lib/agent/auth/loopback_server.dart` and
`pkce.dart`), PKCE S256, `resource` parameter (RFC 8707), scopes from the server metadata, token
exchange, refresh with rotation, tokens stored only in `SecretStore` (`agent.mcp.oauth.<id>` JSON).
mcp_dart 2.4.4 has OAuth helpers (`OAuthClientProvider`, `OAuthAuthorizationCodeProvider`,
`StreamableHttpClientTransportOptions(authProvider:)`, `finishAuthRedirect`): read its source and use
them if they fit, otherwise implement the flow yourself and send headers as the manager already does.
Behavior: adding a server with auth `oauth` (default for the GitHub and Atlassian presets: GitHub
`https://api.githubcopilot.com/mcp/` supports OAuth; Atlassian `https://mcp.atlassian.com/v2/mcp` is OAuth
2.1; keep the token/Basic path as "Use a token instead") connects; if sign-in is needed the manager
status becomes `needsSignIn` (new `McpStatus` value) and `McpManager.signIn(id)` opens the browser, waits
for the callback (cancelable, 5 min), then connects. `signOut(id)` deletes tokens (and revokes when the
server offers it). Refresh before expiry and on 401 once. UI: in `mcp_settings.dart` the add-server
page offers "Sign in with browser" first; server detail shows signed-in state and Sign in/Sign out; no
secrets shown. Tests: discovery parsing, registration body, authorize URL (resource, PKCE), token
exchange and refresh with `MockClient`, status transitions with a fake server returning 401.

## Slice V: voice (AgentVoice)
Files: `android/app/src/main/kotlin/id/nst/focus_launcher/VoiceNative.kt` (+ registration, one small edit in
`FluteEngine.kt`), `AndroidManifest.xml` (RECORD_AUDIO and `<queries>` for speech/TTS services),
`lib/agent/voice/voice_native.dart`, `voice_controller.dart`, `voice_confirmer.dart`, `voice_orb.dart`,
`voice_page.dart`, `voice_settings_section.dart`, `shaders/orb.frag` (+ pubspec shaders entry),
`lib/agent/ui/agent_page.dart` (add the mic entry only), `lib/agent/tools/audio_tools.dart`, tests.
1. **Native** (`flute/voice` MethodChannel + `flute/voice_events` EventChannel, written like
   FluteNative.kt/FluteEvents.kt): `SpeechRecognizer` (on-device when `isOnDeviceRecognitionAvailable`, else
   the default service; partial results, final result, RMS level events 0..1, errors mapped to a small enum,
   language from settings default = device locale), `TextToSpeech` (queue, `speak(text, utteranceId)`, stop,
   voices list, rate, language, `onDone`/`onError` events), RECORD_AUDIO permission request flow (reuse the
   LocationAccess pattern for the dialog). Everything on the main thread as Android requires, released
   in `onDestroy`.
2. **Dart**: `VoiceController extends ChangeNotifier` with state `idle | listening | thinking | speaking`,
   `levels` (ValueListenable<double>, smoothed), `partial` text, `Future<String?> listenOnce()`, `speak(text)`
   (Markdown stripped to speakable text: no code blocks (say "code block"), table rows read as sentences, links
   read by title), `stop()`, `speakStream`-style incremental speaking that starts at the first sentence while
   the reply still streams, settings (language, rate, auto-speak replies, hands-free loop: after the reply
   finishes listen again).
3. **Voice mode UI** `VoicePage` (full screen, opened from a mic button in AgentPage): the **Jarvis-style
   orb** drawn by `shaders/orb.frag` (fragment program via `FragmentProgram`, uniforms: time, level, state,
   colors; concentric rotating rings, a glowing core that pulses with the mic level while listening, a slow
   breathing glow while thinking, ripples with the reply audio while speaking; cheap: one full-size quad,
   about 30 fps via a Ticker only while the page is visible, honours `disableAnimations`), partial text
   under it, a live transcript of the last exchange (Markdown tables/code shown on screen even though not
   read aloud), tool cards, a hands-free toggle, tap orb = interrupt/stop, close button. The page uses the
   same `AgentRuntime` (`flute.agent`): send the final transcript, speak the reply as it streams.
4. **Voice approval**: `VoiceAwareConfirmer implements Confirmer` wrapping the on-screen `ConfirmController`:
   in voice mode it speaks "<summary>. Say allow or deny." (the summary is the tool's describeCall), listens,
   accepts allow/yes/ok/go ahead/do it and deny/no/cancel/stop (English; configurable word lists, also Indonesian
   "ya", "boleh", "tidak", "jangan"), unclear answers re-ask once then deny, and the on-screen sheet stays
   usable at the same time (first answer wins). Outside voice mode it only delegates.
5. **Transcribe tool** (`AudioTools implements ToolSource`, source `audio`, risk read): `audio_transcribe(path or
   attachment name)` sends an audio file to the active OpenAI-compatible provider's
   `POST {base}/audio/transcriptions` (multipart, model from settings default `whisper-1`, or the first model
   whose id contains `whisper`/`transcribe` in the catalog cache) and returns the text; on provider failure
   a readable error. Attachment kind audio: composer needs an "Audio" option and the runtime transcribes
   attached audio before sending (tell the owner what API you need from AttachmentPrep).
Permission copy: explain why the microphone is needed before asking.

## Slice S: sandbox (AgentSandbox)
Files: `lib/agent/sandbox/*` (provider interface, `instabox_provider.dart`, `daytona_provider.dart`,
`local_wasm_provider.dart`, `sandbox_manager.dart`, `sandbox_tools.dart`, `sandbox_settings.dart`),
`lib/agent/ui/sandbox_settings_section.dart`, Rust in `native/hub/src/wasm.rs` + signals (add to
`signals.rs`, register in `lib.rs`/`jobs.rs::start`, run `rinf gen` is done by the owner: list the signals), tests,
`native/hub/Cargo.toml` deps. Read https://www.daytona.io/docs (API + toolbox `process/execute`) and Instabox
(`instabox --help`, `instabox exec --help`, API at https://api.instabox.sh with `ibk_...` keys: find the REST
endpoints for create, exec, files, pause/stop, delete via the CLI's `--help`, its docs, or the HTTP calls the CLI
makes; the `instabox` binary is installed on the dev machine for reading help only).
```dart
abstract class SandboxProvider {
  String get id; String get label;
  Future<SandboxSession> open();                 // creates or starts, returns when ready to run code
}
abstract class SandboxSession {
  String get label;                              // for the UI
  Future<ExecResult> runPython(String code, {Duration timeout});   // stdout, stderr, exitCode, files changed
  Future<ExecResult> runShell(String command, {Duration timeout}); // remote providers only; local throws Unsupported
  Future<void> writeFile(String path, List<int> bytes); Future<List<int>> readFile(String path);
  Future<void> close();                          // MUST stop the paid resource: delete the sandbox the app created,
                                                 // or pause/stop a pre-existing one the user picked
}
class SandboxManager extends ChangeNotifier {
  SandboxManager({required SharedPreferences prefs, required SecretStore secrets, http.Client? httpClient});
  Future<void> load();
  List<SandboxProviderConfig> get providers;     // instabox, daytona (key saved?), local wasm (always)
  Future<void> saveKey(String providerId, String key, {String? apiUrl});   // validate with a cheap call
  String? preferredProviderId;                   // user's choice; null = best available (remote with key, else local)
  Future<SandboxSession> session();              // lazily opens one per agent run, reused by every call in the run
  Future<void> shutdown();                       // closes the session now; idempotent; also called by an idle timer (default 90 s) and when the app pauses
  bool get running;
}
class SandboxTools implements ToolSource { SandboxTools(SandboxManager m); }
```
Tools (source `sandbox`): `sandbox_python` (code, optional `timeout_s` default 60, max 300), `sandbox_shell`
(remote only), `sandbox_write_file`, `sandbox_read_file` (text up to 200 KB; binary returned as a note); all
`write` risk because they execute code (confirm sheet shows the code, trimmed to 600 chars). Output returned
compact (stdout/stderr tail 8 000 chars, exit code, elapsed). **Lifecycle**: the sandbox opens on first use in a
run and `shutdown()` runs when the run ends (the owner calls it from the runtime) and by the idle timer; an
ephemeral remote sandbox is deleted, a user-selected existing one is paused/stopped; failures to stop are
shown loudly in the status and retried. Setting: "Keep warm for N minutes" default 0. **Local default**
(no remote key, or the user picks it): `LocalWasmProvider` runs a WASI Python (CPython compiled to
WASI, e.g. VMware Wasm Labs `python-3.12.0.wasm` or the best current build: pick one with a stable download URL
and pin its SHA-256 in code; download on first use to the app's support dir with a progress callback and
size check, never bundle it in the APK) through **wasmi** (pure Rust interpreter, small) or wasmtime if it
builds for Android (`aarch64-linux-android`; prefer wasmi unless startup is unusable): Rust job
`WasmRunRequest { id, argv, stdin, env, files(preopen dir contents), timeout_ms, max_memory_mb }` +
`WasmRunResponse { id, exit_code, stdout, stderr, error }` with the module bytes held in Rust after a
`WasmLoadRequest`, execution on `spawn_blocking`, fuel/epoch timeout, memory cap, no network, no host fs
except an in-memory preopen dir. Document the real startup time on a phone class device from the Rust
unit test if it can run `python -c "print(1+1)"` on the dev machine (the test may skip when the module file
is absent). Settings section: provider choice, API key fields (instabox, daytona; saved keys hidden), local
runtime status (download/size/delete), "stops after use" explanation, a test button that opens, runs
`print(1+1)`, and closes, showing the elapsed time.

## Slice R: routines (AgentRoutines)
A routine is a saved prompt the LLM runs by itself on a trigger and reports by notification. Files:
Kotlin `RoutineScheduler.kt`, `RoutineReceiver.kt`, `Notifier.kt` (new, `android/app/src/main/kotlin/id/nst/focus_launcher/`),
registration in `AndroidManifest.xml` (receivers; `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM` or inexact, `RECEIVE_BOOT_COMPLETED`
if absent), a small hook in `BootReceiver.kt` to reschedule, channel `flute/routines` (MethodChannel + events) written in a new
`RoutineNative.kt` and registered with ONE added line in `FluteEngine.kt`; Dart in `lib/agent/routines/`:
`routine.dart`, `routine_store.dart`, `routine_runner.dart`, `routine_native.dart`, `routine_tools.dart`; UI in
`lib/agent/ui/routines_page.dart` and `lib/agent/ui/routines_section.dart` (a settings section the owner wires); tests.
```dart
enum RoutineTrigger { daily, weekly, interval }   // daily: hh:mm; weekly: weekdays + hh:mm; interval: every N minutes (min 15)
class Routine { final String id, name, prompt; final RoutineTrigger trigger; final int minuteOfDay; final Set<int> weekdays; final int everyMinutes;
  final bool enabled; final bool allowWrites;       // default false: a routine only reads
  final bool speak; final String? modelOverride; final DateTime? lastRun; final String? lastResult /* trimmed */; ... toJson/fromJson/copyWith }
class RoutineStore extends ChangeNotifier { RoutineStore({required SharedPreferences prefs, RoutineNative? native}); Future<void> load();
  List<Routine> get routines; Future<Routine> save(Routine r); Future<void> remove(String id); Future<void> setEnabled(String id, bool on);
  List<RoutineRun> history(String id); }            // last 20 runs: when, ok/error, tokens, tps, result text (trimmed 4000)
class RoutineRunner { RoutineRunner({required Flute-independent deps: ProviderStore providers, List<ToolSource> toolSources, SkillManager skills,
    RoutineStore store, RoutineNative native, DateTime Function()? clock});
  Future<RoutineRun> run(Routine r);               // creates its OWN AgentRuntime (never the visible chat), sends the prompt, waits, posts a notification
  void start();                                    // listens to native fire events and to fires that happened while the app was dead (getPendingFires)
}
class RoutineTools implements ToolSource { RoutineTools(RoutineStore s, RoutineRunner r); }   // routine_list, routine_create, routine_update,
                                                    // routine_delete, routine_run_now (writes ask first; list is read, source 'launcher')
```
Behavior: the schedule lives in Android (AlarmManager `setExactAndAllowWhileIdle` when exact alarms are allowed, else
`setAndAllowWhileIdle`; rescheduled after boot, timezone change, package replace and each fire). When it fires and the Flutter engine
is not running, the receiver starts `FluteEngine.get(context)` (the shared engine) WITHOUT showing any activity, holds a short wake
lock, and queues the fire for Dart (Dart drains `getPendingFires()` when `RoutineRunner.start()` runs and also receives `fire` events); it
finishes within a bounded time (default 3 minutes; cancel and notify "timed out"). Run policy: the routine's `AgentRuntime` gets a
`Confirmer` that **denies every write** unless `allowWrites` is true, in which case a write is allowed only for tools whose risk is write
AND source is not `sandbox`/`launcher` mode-changes... (keep it simple: with allowWrites true, writes are allowed except sandbox code
execution and deleting anything; document the rule in the UI). The result is posted as a notification (title = routine name, big text =
first 400 chars of the answer, tap opens the Ask page with the full result as a message; actions "Run again"). If `speak` is on and the
screen is on, speak a one-sentence summary. Notification permission (Android 13) is requested from the UI when the first routine is
enabled. Every run records history with tokens and tokens/second. A routine that fails twice in a row is paused with a notification.
UI: a Routines page (list with next run time, enable switch, run now, last result), an editor (name, prompt, trigger picker, weekday chips,
interval, allow-writes switch with the rule explained, speak switch), empty state with 3 example routines ("Morning briefing:
today's calendar and weather", "Evening wind-down: switch to Sleep mode at 22:30 and say goodnight" (needs allowWrites), "Weekly: summarise
unread mail"). Also a "Routines" row in the agent settings section list (the owner wires `RoutinesSection`).

## Slice I: images (Main)

`lib/agent/tools/image_tools.dart`, `lib/agent/image/*`, `lib/agent/ui/image_canvas.dart`, `shaders/imagine.frag`.

- **Tool** `image_generate(prompt, shape=square|portrait|landscape)`, risk `write` (it spends credits, so it asks), `makesImages` true.
  It calls `POST {baseUrl}/images/generations` with `{model, prompt, n:1, size}` on an OpenAI-compatible provider and reads
  `data[0].b64_json` (or an https `url`). The reply is parsed off the UI isolate. The file goes to
  `<app support>/images/img_<ms>.<png|jpg|webp>` (extension from the bytes, newest 60 kept). The model only gets a short text; the
  path travels in `ToolResult.images` and `ToolItem.images`.
- **Detection** (`ImageModels.candidates`): a gateway rarely says which models draw. A model counts when its list entry says so
  (`capabilities.imageOutput`, `output_modalities` has `image`), or its id contains a known name (`gpt-image`, `dall-e`, `imagen`,
  `flux`, `sdxl`, `stable-diffusion`, `nano-banana`, `flash-image`, `-image-`). On a gateway that lists `cx/` or `gemini/` models,
  `cx/gpt-image-2` and `gemini/gemini-3.1-flash-image-preview` / `gemini/gemini-2.5-flash-image` are added (they work but are not
  listed; probed on the real gateway). `cx/gpt-image-1` is refused by Codex with a ChatGPT account. The user's choice goes first; up
  to three models are tried, a refusal moves to the next, a network error stops.
- **Animation**: while the tool runs, the card shows a 1:1 canvas drawn by `shaders/imagine.frag` (domain-warped colour fields and a
  light sweep, GPU; `uTime` is seconds modulo 60 so the loop has no seam) with an elapsed counter; the picture then fades and settles in.
  Reduced motion draws one still frame.

## Pitfall: pin jni

A fresh `pub get` on a new build box resolved `jni 1.2.0` / `jni_flutter 1.1.0` (used by `path_provider_android` and
`shared_preferences_android`), and the app died at start with `ClassNotFoundException: Landroid/content/Context;`. `pubspec.yaml`
pins `jni: 1.1.2` and `jni_flutter: 1.0.4+1` in `dependency_overrides`. `pubspec.lock` is not part of the resolution on the build box.

## Slice N: sandbox network and files (Main)

**Network for local Python** (`native/hub/src/net_shim.py`, `wasm.rs`, `lib/agent/sandbox/local_net.dart`). WASI has no sockets.
With `network` on, a run is started as `python -c <boot> <program>`: the boot script swaps `http.client.HTTPConnection/HTTPSConnection`
(and stubs `_create_https_context`, so `urllib.request` offers https) for classes that write one marked line
(`\x01FLUTE-NET {json}`) to stdout and read one JSON line from stdin. Rust filters those lines out of the captured output,
relays each to Dart (`WasmNetRequest` / `WasmNetResponse`) and blocks the run's thread for the answer (90 s, 100 calls per run).
`LocalNetBridge` performs it with `package:http`: http/https only, GET/HEAD/POST/PUT/PATCH/DELETE, request body <= 2 MB, response <= 5 MB,
no redirects (urllib follows them, every hop comes back to be checked), and every resolved address must be public
(`isPublicAddress`: not loopback, private, link-local, CGNAT, multicast, unspecified, unique-local, or mapped from those). The program is
passed with `-c` because stdin carries the answers. Setting `sandbox.localNetwork` (default on). Remote sandboxes have their own network.
Fuel is not wall time; see PERFORMANCE.md.

**Showing files** (`lib/agent/sandbox/sandbox_outputs.dart`, `sandbox_tools.dart`). A sandbox is shut down after each tool call, so files
are collected inside the same call: `sandbox_python` and `sandbox_shell` take `show_files` (paths in the sandbox); the local runtime also
reports everything the program wrote to `/out` (a per-session host directory preopened by Rust as `/out`, deleted on close). Each file
is copied to `<app support>/outputs/<us>_<name>` (<= 20 MB, <= 8 per call, newest 100 kept) and returned as `ToolResult.files` (`ToolFile`);
the chat shows pictures inline and other files as rows with open, share and save (to Downloads).

