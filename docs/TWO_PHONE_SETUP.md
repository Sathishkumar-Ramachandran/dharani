# Two-phone setup: rider + driver, live translated call

One phone is the **rider** ("I need a ride"), the other is the **driver** (auto / cab / bike). A small server
matches them, relays the driver's live location and carries the translated conversation.

## 1. One command (phones plugged in over USB, same Wi-Fi as this Mac)

```bash
tools/two_phones.sh            # builds, installs on every connected phone, grants permissions, starts the server
```

It prints `Server address for BOTH phones: http://192.168.x.y:8080`. On each phone, first launch:

| Phone | Choose | Fill in |
|---|---|---|
| A | **I need a ride** | name, your language, server address |
| B | **I drive** | name, your language, vehicle type, registration number, server address |

Use different languages (e.g. rider Hindi, driver Tamil) to see the translation.

## 2. Try it
1. Phone B: **Drive** tab -> **Go online** (accept the notification/location prompts). Keep it near phone A or move the map.
2. Phone A: **Ride** tab -> pick a destination (search or long-press the map) -> choose the same vehicle type -> **Book**.
3. Phone B gets the offer -> **Accept**. Phone A shows driver, plate and a 4-digit OTP.
4. Phone B: **I have arrived** -> type the OTP -> **Start trip**.
5. **Live translation** card (both phones): tap the mic and speak; the other phone speaks your sentence in its language.
   Switch on **Hands-free** for continuous conversation. Typing works too.
6. Phone B: **Complete trip**.

First time only: Translate tab -> **Download & enable** (language packs + the NPU speech model, ~520 MB) on both phones.
Without it the Android recognizer is used.

## 2a. Voice call (real-time, both directions at once)
After a ride is assigned, either phone taps **Voice call** in the *Live translation* card. The other phone rings
with an Answer/Decline bar; once answered, microphone audio streams both ways as 20 ms frames (16 kHz mono) through the
server relay, with the platform echo canceller and noise suppression. Mute, speaker and hang-up are in the green bar.
**Interpreter mode** (default when the two phones have different languages and the NPU speech model is loaded):
the call's microphone is recognised on the NPU sentence by sentence, translated, and sent as text; the other phone speaks it
in its own language through the loudspeaker (the raw voice is not streamed). Tap the translate icon in the green bar to
switch to the speakers' original voices and back. Expect ~1.5-3 s from the end of a sentence to the spoken translation.
Both parties of the ride can call; nobody else can inject audio. Calls work while the app is in the foreground (push
wake-up for a closed app needs FCM, not built yet). The microphone is shared: voice-to-text translation pauses during a call.

## 2b. Fleet-style provisioning (no typing on the phone)
```bash
tools/provision_phone.sh <adb-serial> driver "Auto Murugan" ta http://<mac-ip>:8080 auto TN09AB4242 "Bajaj RE"
tools/provision_phone.sh <adb-serial> rider  "Customer Asha" hi http://<mac-ip>:8080
```

## 2c. No second phone yet
Rider onboarding has **Try with simulated drivers (no server)**. Everything but the human driver and the call is real.

## 3. Production notes
* Use **https/wss**: run the server with `--tls-cert/--tls-key` (or behind a TLS proxy) and switch the app's
  `usesCleartextTraffic` off in `AndroidManifest.xml`. Cleartext is enabled now only so a LAN IP works.
* Set `DHARANI_SECRET` (>= 16 random chars) so tokens survive restarts; otherwise phones silently re-register.
* The driver app uses a foreground service (visible notification) so GPS keeps flowing with the screen off.
  Disable battery optimisation for the app on the driver's phone (vivo/Oppo/Xiaomi kill background apps aggressively).
* Registration is open and rate limited. Put real identity (phone OTP) in front of `/v1/register` before launch.
* One server process, in-memory state. Active rides are lost on restart (phones reconnect, rides do not resume).
* The "call" is text translation relayed over the socket (each phone recognises + translates its owner's speech and the
  other phone speaks it); there is no VoIP audio channel. Add WebRTC if the two people should also hear each other's voice.

## 4. What was tested without phones
Server: 20 integration tests over real sockets (matching, accept race, cancellation, reconnect, auth, limits).
App: two simulated phones against the real server (booking, OTP, live location, translated chat both ways,
hands-free loop, network drop + resume, server restart with a new secret). Not tested: real GPS, real microphones,
two real devices, vivo background-kill behaviour.

## Languages
English, Hindi, Tamil, Telugu, Kannada, Marathi, Bengali, Gujarati, Urdu and French. To add one more: add it to
`packages/dharani_protocol` (`supportedLanguages`), `mobile-ui/lib/translate/languages.dart` (needs a Whisper language
token, an ML Kit `TranslateLanguage` and an Android TTS locale) and `mobile-ui/assets/ai_pack.json`, then re-run the tests.
