# Code-level live dial probe

`MaVoDialProbe` exercises the same `CModemBridge` USB/AT path as the menu
bar app, without launching or clicking the UI. It is intentionally a separate
executable so the app cannot hide command or state transitions.

Build only (does not touch the module):

```sh
swift build --package-path MaVo --product MaVoDialProbe
```

Live invocation (places a real call):

```sh
MaVo/.build/debug/MaVoDialProbe \
  --number 10000 \
  --confirm-live-call \
  --probe-voice-interface \
  --log /tmp/mavo-dial-10000.log
```

The command above only probes interface 1 and then runs a network-only dial.
To exercise the production transport sequence, explicitly select full flow:

```sh
MaVo/.build/debug/MaVoDialProbe \
  --number 10000 \
  --confirm-live-call \
  --full-flow \
  --log /tmp/mavo-dial-10000-full.log
```

To test the hypothesis that a nonstandard module rejects PCM setup until a
voice call exists, select the separate diagnostic after-connect flow:

```sh
MaVo/.build/debug/MaVoDialProbe \
  --number 10000 \
  --confirm-live-call \
  --full-flow-after-connect \
  --log /tmp/mavo-dial-10000-after-connect.log
```

For a QDC507 whose module-side call-audio route and PCM helper have already
been started by the production `ModuleVoiceRuntime`, use the explicitly
external-route mode:

The repository wrapper performs that complete setup and cleanup around the
same code-level dial probe (quit the menu-bar app first):

```sh
MaVo/scripts/run_qdc507_live_call_probe.sh \
  --number 10000 \
  --confirm-live-call \
  --observe-seconds 45 \
  --media-seconds 15 \
  --log /tmp/mavo-dial-10000-qdc-external-pcm.log
```

It deploys the bundled runtime over ADB, loads only the reversible kernel
modules when needed, starts the helper, runs the probe, prints the helper log,
and sends the supported `T` cleanup command even when the probe fails or is
interrupted. The wrapper never writes a flash partition.

To manage the external route separately, invoke the probe directly:

```sh
MaVo/.build/debug/MaVoDialProbe \
  --number 10000 \
  --confirm-live-call \
  --qdc-external-pcm-flow \
  --observe-seconds 45 \
  --media-seconds 15 \
  --log /tmp/mavo-dial-10000-qdc-external-pcm.log
```

This mode opens USB interface 1 before `ATD`, continuously writes zero-filled
8 kHz/16-bit mono uplink, and consumes little-endian PCM16 downlink. It does
not send any `QPCMV` command (including a capability/read-back query), and it
does not query, change, or restore the GPS outport. The process that created
the module-side route remains responsible for that route and must keep its
helper alive until the probe has finished.

Acceptance is deliberately stricter than a successful USB byte count. The
probe must observe an outgoing active `CLCC` call, then receive at least one
nonzero PCM16 downlink sample and write silent uplink bytes after that active
state. Cleanup must complete `ATH` followed by a successful empty `CLCC`.
All-zero downlink therefore exits `32`, even when interface 1 transferred
bytes normally.

After the module has already been configured to enumerate its USB Audio Class
device, exercise the separate UAC path with:

```sh
MaVo/.build/debug/MaVoDialProbe \
  --number 10000 \
  --confirm-live-call \
  --uac-flow \
  --log /tmp/mavo-dial-10000-uac.log
```

For QDC507, the repository can deploy the reversible APRv3/AFE modules, enable
only the external voice route, run that no-QPCMV UAC probe, and always send the
route cleanup command:

```sh
MaVo/scripts/run_qdc507_uac_live_call_probe.sh \
  --number 10000 \
  --confirm-live-call \
  --observe-seconds 45 \
  --media-seconds 15 \
  --log /tmp/mavo-dial-10000-qdc-uac.log
```

The wrapper does not start the interface-1 helper and never writes a flash
partition. The probe itself still sends silent uplink for deterministic media
evidence; the production app uses the same CoreAudio IOProc with PCM16 rings to
bridge the Mac microphone and speaker.

For customized firmware whose `QPCMV` writes are known to fail, a separately
managed, already-enabled modem audio route can be tested without sending any
`QPCMV` command:

```sh
MaVo/.build/debug/MaVoDialProbe \
  --number 10000 \
  --confirm-live-call \
  --uac-flow-no-qpcmv \
  --observe-seconds 45 \
  --media-seconds 15 \
  --log /tmp/mavo-dial-10000-direct-voc.log
```

This mode does not create, verify, or restore the external modem-side route.
The caller that enabled that route remains responsible for restoring it after
the probe has completed `ATH` and confirmed an empty voice `CLCC` state.

`--uac-flow` does not modify `USBCFG` or restart the module. It first requires
an alive 8 kHz full-duplex CoreAudio USB device whose CoreAudio UID maps through
`IOAudioEngine` to the same VID, PID, and USB location as the AT interface. It
then performs `QPCMV=1,2 -> ATD -> outgoing active CLCC -> CoreAudio IOProc`.
The IOProc consumes UAC input, writes zero-filled silence to UAC output, and
records callbacks, bytes, and frames in both directions. A `CONNECT` line alone
does not start CoreAudio or prove the UAC call. On every recoverable exit after
ATD, cleanup is `ATH -> empty CLCC (or explicit NO CARRIER) -> stop IOProc and
restore any changed sample rate -> QPCMV=0`.

The UAC acceptance test requires input and output frames plus downlink samples
above the reported PCM16 threshold after active `CLCC`. Output frames contain
silence, so they prove only that the UAC uplink callback ran; neither UAC mode
connects the Mac microphone or speakers and neither proves audible two-way
conversation.

If the current macOS audio driver does not publish an `IOAudioEngine` registry
mapping, run once to obtain the logged CoreAudio candidate UID, verify it in
Audio MIDI Setup, and repeat with `--uac-device-uid UID`. An explicit UID still
has to be an alive, full-duplex USB device supporting 8 kHz, and any available
USB registry identity must match the modem. Terminal may request Microphone
permission when the IOProc starts; denying it makes the media proof fail safely.

Quit the menu-bar app first because USB AT interface 2 is exclusive. For the
QDC external mode, arrange for the already-started module-side helper to remain
alive after the app releases its USB interfaces. The optional interface probe
only opens and closes interface 1; it never enables
`QPCMV` or performs PCM I/O. `--full-flow` instead performs
`QPCMV=1,0 -> open interface 1 -> ATD -> PCM I/O -> ATH/CLCC -> QPCMV=0`.
`--full-flow-after-connect` deliberately performs the alternate order
`outport none -> ATD -> outgoing active CLCC -> QPCMV=1,0 -> open interface 1
-> bidirectional PCM counts -> ATH -> empty CLCC -> QPCMV=0 -> restore
outport`. A `CONNECT` result alone does not unlock QPCMV in this mode; the
probe requires CLCC status 0 for an outgoing voice call.

This is a diagnostic fallback, not the Quectel standard sequence. Quectel's
audio design guidance says PCMV should be turned on or off only while there is
no call, so the supported/default full flow remains `QPCMV=1,0 -> ATD`. The
after-connect option is kept separate to gather decisive evidence from this
specific customized firmware and may legitimately return `ERROR`.

The two modem-managed raw PCM modes send zero-filled 8 kHz/16-bit mono silence,
discard received PCM, and never open the Mac microphone or speaker. Before
assigning interface 1 to PCM, those modes read `AT+QGPSCFG="outport"`; when USB
NMEA owns that interface, the probe temporarily sets the outport to `none`,
verifies it, then restores the exact captured value after call and QPCMV
cleanup. `--qdc-external-pcm-flow` is separate from this behavior: it analyzes
received PCM16 samples but never owns or changes either modem-side setting.

The transport modes, including `--qdc-external-pcm-flow` and `--uac-flow`, are
mutually exclusive. In after-connect mode, a `QPCMV=1,0` rejection or
interface-1 open failure returns immediately to
`ATH` plus `AT+CLCC` reconciliation. Only after that attempt does it send the
final `AT+QPCMV=0`, close interface 1, and restore the captured GPS outport.
The same call-cleanup-before-media-cleanup ordering applies to signal-driven
and other recoverable exits.

The preflight commands are query-only. The tool refuses to dial unless the SIM
is ready, CREG or CEREG is registered, and `AT+CLCC` proves there is no existing
voice call. IMS/VoLTE/MbN/radio query errors are preserved as evidence but do
not alone block dialing. A terminal ATD failure is followed immediately by
`AT+CEER`, before `AT+CLCC`. After `ATD`, all exits attempt `ATH` and require
either `NO CARRIER` or an empty `AT+CLCC` response before cleanup is confirmed.

Exit codes:

- `0`: the selected mode's connection/media proof passed and hangup was
  confirmed. QDC external PCM specifically requires active outgoing CLCC,
  post-connect nonzero PCM16 downlink, silent uplink bytes, and empty CLCC
  after ATH.
- `20`/`21`: the transport or read-only preflight failed before ATD.
- `22`: selected PCM flow could not complete its reversible pre-ATD preparation.
- `30`: a real dial was attempted but connection was not proved; hangup was confirmed.
- `31`: a dial was attempted and cleanup could not be confirmed.
- `32`: connection was proved, but PCM/UAC bidirectional media evidence or cleanup was incomplete.
- `64`/`70`/`73`: CLI, internal, or log-file setup failure.
