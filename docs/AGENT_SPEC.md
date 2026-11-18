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
