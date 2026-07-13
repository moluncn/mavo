# QDC507 loadable APRv3 + minimal AFE audio stack

## Result and safety scope

Two ARMv7 kernel modules were built successfully without modifying the boot
image:

- `qdc507_aprv3.ko` - APRv3 over SMD plus the vendor voice-service endpoint.
- `qdc507_afe.ko` - audio calibration, audio ION, Q6 AFE, Q6 DAI, AFE PCM,
  stub codec, and a fixed-index seven-link sound card.

The first live load proved `qdc507_aprv3.ko` starts, then exposed a NULL
dereference in the old AFE card glue before any route or call command ran.
The fault was mapped to `fmt_single_name()` dereferencing
`dev->driver->name`: the old glue registered an ASoC component on an unbound
synthetic platform device. Runtime revision `.2` replaces that glue; the new
AFE artifact below has completed offline build and symbol audit and still
requires a cold-boot live validation. No flash, boot, MTD, DIAG, or EDL write
was performed.

## Build identity

- Kernel source: `quectel_eg25_kernel`, commit
  `82ed00908b3e8efc3ff0de27d2b5a7c0524ecd7f`
- Baseline config: `/private/tmp/qdc507-current.config`
- Baseline release: `3.18.44`
- Baseline `Module.symvers`: 6,213 exports, SHA-256
  `0fab4c179816b7f9dd9ffae3ae7e4fb1d0de14ba6eef9b7ad8843009a47bbdce`
- Module vermagic: `3.18.44 preempt mod_unload ARMv7 p2v8`
- Toolchain: AOSP ARM GCC 4.9 (`arm-linux-androideabi-`)
- `CONFIG_MODULES=y`, `CONFIG_MODULE_UNLOAD=y`, `CONFIG_MODVERSIONS=n`,
  `CONFIG_MODULE_SIG=n`, `CONFIG_KALLSYMS=n`

The Android GCC defaults to PIC. Both module Makefiles explicitly use
`-fno-pic -fno-pie`; this removes `R_ARM_GOT_*`/`R_ARM_BASE_PREL`
relocations that the 3.18 ARM module loader cannot apply. Final relocation
types are limited to `R_ARM_NONE`, `R_ARM_ABS32`, `R_ARM_CALL`,
`R_ARM_JUMP24`, and `R_ARM_PREL31`, all handled by this kernel.

## Artifacts

| File | Bytes | SHA-256 |
|---|---:|---|
| `qdc507_aprv3.ko` | 36,648 | `9f2cc3d2c376c30588e6334c01de560d2748232f3c069667930c2f90b3697e25` |
| `qdc507_afe.ko` | 228,004 | `8559986a13485bde6c111f90bcb8a2bd191b4d0517b66b446f944590b41fdacb` |

`qdc507_afe.ko` carries `depends=qdc507_aprv3`; load APR first and unload it
last.

## Symbol audit

- `qdc507_aprv3.ko`: 57 undefined imports; all 57 are present in the
  stock-config baseline `Module.symvers`.
- `qdc507_afe.ko`: 117 undefined imports; 112 are present in the baseline
  and these five are exported by `qdc507_aprv3.ko`:
  `apr_register`, `apr_deregister`, `apr_send_pkt`, `apr_reset`, and
  `apr_get_q6_state`.
- Final missing imports: zero.
- Both builds completed `MODPOST` and final `LD [M]` without compiler errors
  or unresolved-symbol warnings. The container reports only a harmless
  2-3 ms host/container timestamp skew while generating `.mod.c`.

`CONFIG_KALLSYMS=n` is not a blocker: module relocation uses the kernel's
export table (`__ksymtab`), represented by `Module.symvers`, rather than
runtime kallsyms lookup.

## Init, rollback, and unload design

The vendor sources assumed built-in initcalls. A small bundler records their
callbacks by initcall level, provides one `init_module`, and invokes exit
callbacks in reverse object order. A unit is marked initialized only after
its callback succeeds, so a later failure skips exits for units that never
started.

APR order:

1. `apr_init`
2. `apr_tal_init`
3. `voice_svc_init`
4. `apr_late_init`

APR unload reverses the voice-service driver, TAL drivers/channels, subsystem
and panic notifiers, IPC log context, and APR reset workqueue.

AFE order:

1. `audio_cal_init` (subsystem level)
2. `msm_audio_ion_init`
3. `afe_init`
4. `msm_stub_init`
5. `msm_dai_q6_init`
6. AFE PCM platform init
7. fixed-index card init

AFE unload reverses that order. The card glue now binds a real
`platform_driver` to the active `qcom,mdm9607-audio-tomtom` DT sound node,
registers the index component only from its bound probe, and resolves the
AFE platform, Q6 CPU DAIs, and stub codec through that node's phandles. It
fails closed unless ALSA card 0 contains playback device 5 and capture device
6. The original incomplete Q6 DAI exit path now
unregisters TDM, SPDIF, MI2S, Q6-device, Q6, and AUXPCM drivers in strict
reverse registration order. `afe_init` now rolls back its mutex/wakeup source
if calibration setup fails; the card has local error unwinding; audio-cal and
audio-ION registration failures do not leave registered external resources.

The installed DT requests `qcom,scm-mp-enabled` and attaches a 4 MiB reusable
CMA `memory-region` to the audio-ION device. The loadable version preserves the
original secure-memory call. It reads `base_pfn`/`count` from the CMA area
already attached to that device and calls the exported `scm_call`, avoiding
only the non-exported `cma_get_base`/`cma_get_size` wrappers.

## Why D5 playback and D6 capture are deterministic

The custom card has seven links. Links 0 through 4 are unused index-holder
PCMs. Link 5 is `msm-dai-q6-dev.241` through `msm-pcm-afe` and is playback
only. Link 6 is `msm-dai-q6-dev.240` through `msm-pcm-afe` and is capture
only.

This kernel's ASoC core calls `soc_new_pcm(rtd, link_index)`, so a successfully
instantiated card creates:

- `/dev/snd/controlC0`
- `/dev/snd/pcmC0D5p`
- `/dev/snd/pcmC0D6c`

This assumes no other ALSA card claims index 0 first, which matches the
observed stock state (`--- no soundcards ---`). The existing `u_uac1` helper's
hard-coded D5 playback/D6 capture paths therefore match the module card.

The static path is compatible with the installed firmware's supported
application sequence `S -> dial -> media -> hang up -> T`: `S` asks the vendor
daemon to route voice through AFE, while UAC opens `hw:0,5` for playback and
`hw:0,6` for capture. The observed daemon does not implement the `A/B`
commands used by some other firmware branches. DSP-firmware routing and
nonzero samples still require one controlled live validation; they cannot be
proven by offline linking.

## Deferred live validation commands (not executed)

Run these only after copying the two `.ko` files to the owned module and
confirming that no call or audio stream is active:

```sh
uname -r
sha256sum qdc507_aprv3.ko qdc507_afe.ko

insmod ./qdc507_aprv3.ko
insmod ./qdc507_afe.ko

cat /proc/modules | grep -E 'qdc507_(aprv3|afe)'
cat /proc/asound/cards
cat /proc/asound/pcm
ls -l /dev/snd/controlC0 /dev/snd/pcmC0D5p /dev/snd/pcmC0D6c
dmesg | tail -n 120
```

The expected `uname -r` is `3.18.44`. Do not proceed if it differs. Also stop
if either `insmod` reports an unknown symbol, invalid module format, or an
ASoC deferred-probe component that is absent from the installed DT.

Unload only after closing UAC/ALSA and voice-service file descriptors:

```sh
driver=/sys/bus/platform/drivers/qdc507-afe-card
for entry in "$driver"/*; do
    test -L "$entry" || continue
    printf '%s\n' "${entry##*/}" > "$driver/unbind"
done
rmmod qdc507_afe
rmmod qdc507_aprv3
```

The unbind removes the card first so ASoC releases its component references.
Do not use forced unload. If `rmmod` reports busy, find and stop the holder
instead.

## Remaining compatibility boundary

The public tree is not the complete QDC507 vendor tree. Same release and
matching exported symbol names are strong static evidence, especially with
`CONFIG_MODVERSIONS=n`, but they do not prove private structure/layout ABI or
DSP firmware behavior. The first live step should therefore be reversible
`insmod` plus readback only; no boot write is required for this design.
