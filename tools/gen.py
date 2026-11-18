#!/usr/bin/env python3
"""Asset generation: images, voice (TTS) and background music (BGM).

  python3 tools/gen.py image OUT.png "prompt" [--model cx/gpt-6.1-sol|gemini-3.1-flash-image] [--size 1024x1024]
  python3 tools/gen.py tts   OUT.wav "text"   [--model gemini-3.8-flash-tts] [--voice Kore]
  python3 tools/gen.py bgm   OUT.mp3 "prompt" [--model lyria-3.5]

Credentials come from the first of: $FOCUS_ENV, ./.env
  URL, KEY      OpenAI-compatible gateway (models named cx/*)
  GEMINI_KEY    Google Generative Language API (models without a "cx/" prefix)
Secrets are never printed or copied. Runs on this machine (stdlib only) or on the rflutter box.
"""
import argparse, base64, json, os, pathlib, struct, subprocess, sys, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
GEMINI = "https://generativelanguage.googleapis.com/v1beta/models"


def load_env():
    cands = [os.environ.get("FOCUS_ENV"), ROOT / ".env"]
    for c in cands:
        if c and pathlib.Path(c).is_file():
            env = {}
            for line in pathlib.Path(c).read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
            return env
    sys.exit("no .env found (set FOCUS_ENV, or put .env in the project root)")


def post(url, body, headers, timeout=300):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "curl/8.5.0", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def gemini(env, model, body):
    return post(f"{GEMINI}/{model}:generateContent", body, {"x-goog-api-key": env["GEMINI_KEY"]})


def inline(resp):
    for p in resp["candidates"][0]["content"]["parts"]:
        if "inlineData" in p:
            return p["inlineData"]["mimeType"], base64.b64decode(p["inlineData"]["data"])
    sys.exit("no media in response: " + json.dumps(resp)[:300])


def save(out, data):
    out = pathlib.Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print("wrote", out, len(data), "bytes")


def cmd_image(a, env):
    if a.model.startswith("cx/"):
        base = env["URL"].rstrip("/")
        base += "" if base.endswith("/v1") else "/v1"
        d = post(base + "/images/generations", {"model": a.model, "prompt": a.prompt, "size": a.size, "n": 1}, {"Authorization": "Bearer " + env["KEY"]})
        data = base64.b64decode(d["data"][0]["b64_json"])
    else:
        mime, data = inline(gemini(env, a.model, {"contents": [{"parts": [{"text": a.prompt}]}], "generationConfig": {"responseModalities": ["IMAGE"]}}))
        if mime == "image/jpeg" and pathlib.Path(a.out).suffix.lower() == ".png":  # Gemini returns JPEG; honour the extension
            data = subprocess.run(["ffmpeg", "-v", "error", "-i", "-", "-f", "image2pipe", "-c:v", "png", "-"], input=data, capture_output=True, check=True).stdout
    save(a.out, data)


def cmd_tts(a, env):
    body = {"contents": [{"parts": [{"text": a.prompt}]}], "generationConfig": {"responseModalities": ["AUDIO"], "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": a.voice}}}}}
    mime, data = inline(gemini(env, a.model, body))
    if "L16" in mime or "pcm" in mime:  # raw 16-bit PCM: wrap in a WAV header
        rate = int(mime.split("rate=")[1]) if "rate=" in mime else 24000
        data = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(data)) + data
    save(a.out, data)


def cmd_bgm(a, env):
    _, data = inline(gemini(env, a.model, {"contents": [{"parts": [{"text": a.prompt}]}], "generationConfig": {"responseModalities": ["AUDIO", "TEXT"]}}))
    save(a.out, data)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn, model in (("image", cmd_image, "cx/gpt-6.1-sol"), ("tts", cmd_tts, "gemini-3.8-flash-tts"), ("bgm", cmd_bgm, "lyria-3.5")):
        p = sub.add_parser(name)
        p.add_argument("out")
        p.add_argument("prompt")
        p.add_argument("--model", default=model)
        if name == "image":
            p.add_argument("--size", default="1024x1024")
        if name == "tts":
            p.add_argument("--voice", default="Kore")
        p.set_defaults(fn=fn)
    a = ap.parse_args()
    a.fn(a, load_env())


if __name__ == "__main__":
    main()
