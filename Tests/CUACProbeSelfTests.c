#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Compile the implementation into this isolated test translation unit so its
 * realtime ring and format converters can be exercised without USB hardware. */
#include "../Sources/CUACProbe/CUACProbe.c"

static void test_ring_wrap_and_capacity(void) {
    UACPCMRing ring = {0};
    int16_t source[MAVO_UAC_PCM_RING_FRAMES];
    int16_t output[MAVO_UAC_PCM_RING_FRAMES];
    for (size_t index = 0; index < MAVO_UAC_PCM_RING_FRAMES; index++) {
        source[index] = (int16_t)index;
    }

    pcm_ring_reset(&ring);
    assert(pcm_ring_write(&ring, source, MAVO_UAC_PCM_RING_FRAMES) ==
           MAVO_UAC_PCM_RING_FRAMES);
    assert(pcm_ring_write(&ring, source, 1) == 0);
    assert(atomic_load_explicit(&ring.dropped_frames, memory_order_relaxed) == 1);

    assert(pcm_ring_read(&ring, output, 1024) == 1024);
    for (size_t index = 0; index < 1024; index++) {
        assert(output[index] == (int16_t)index);
    }
    assert(pcm_ring_write(&ring, source, 1024) == 1024);
    assert(pcm_ring_read(&ring, output, MAVO_UAC_PCM_RING_FRAMES) ==
           MAVO_UAC_PCM_RING_FRAMES);
    for (size_t index = 0; index < 1024; index++) {
        assert(output[index] == (int16_t)(index + 1024));
        assert(output[index + 1024] == (int16_t)index);
    }
}

static void test_float_downlink_conversion(void) {
    MaVoUACProbe probe = {0};
    float input[] = {0.0f, -1.0f, 0.5f, 1.0f};
    AudioBufferList buffers = {0};
    int16_t output[4] = {0};

    probe.input.sample_kind = MAVO_UAC_SAMPLES_FLOAT32;
    probe.input.bytes_per_frame = sizeof(float);
    pcm_ring_reset(&probe.downlink_ring);
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = 1;
    buffers.mBuffers[0].mDataByteSize = sizeof(input);
    buffers.mBuffers[0].mData = input;

    enqueue_input_pcm(&probe, &buffers);
    assert(pcm_ring_read(&probe.downlink_ring, output, 4) == 4);
    assert(output[0] == 0);
    assert(output[1] == INT16_MIN);
    assert(output[2] == 16384);
    assert(output[3] == INT16_MAX);
}

static void test_float_uplink_and_flush(void) {
    MaVoUACProbe probe = {0};
    int16_t input[] = {INT16_MIN, 0, 16384, INT16_MAX};
    float output[4] = {0};
    AudioBufferList buffers = {0};

    probe.output.sample_kind = MAVO_UAC_SAMPLES_FLOAT32;
    probe.output.bytes_per_frame = sizeof(float);
    pcm_ring_reset(&probe.uplink_ring);
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = 1;
    buffers.mBuffers[0].mDataByteSize = sizeof(output);
    buffers.mBuffers[0].mData = output;

    assert(pcm_ring_write(&probe.uplink_ring, input, 4) == 4);
    write_output_pcm(&probe, &buffers);
    assert(fabsf(output[0] + 1.0f) < 0.000001f);
    assert(fabsf(output[1]) < 0.000001f);
    assert(fabsf(output[2] - 0.5f) < 0.000001f);
    assert(fabsf(output[3] - ((float)INT16_MAX / 32768.0f)) < 0.000001f);

    assert(pcm_ring_write(&probe.downlink_ring, input, 4) == 4);
    assert(pcm_ring_write(&probe.uplink_ring, input, 4) == 4);
    mavo_uac_probe_flush_pcm(&probe);
    assert(pcm_ring_read(&probe.downlink_ring, input, 4) == 0);
    for (size_t index = 0; index < 4; index++) {
        output[index] = 1.0f;
    }
    write_output_pcm(&probe, &buffers);
    for (size_t index = 0; index < 4; index++) {
        assert(output[index] == 0.0f);
    }
}

int main(void) {
    MaVoUACProbe *lifecycle = mavo_uac_probe_create();
    assert(lifecycle != NULL);
    assert(mavo_uac_probe_try_destroy(lifecycle) == MAVO_UAC_OK);
    test_ring_wrap_and_capacity();
    test_float_downlink_conversion();
    test_float_uplink_and_flush();
    puts("CUACProbe self-tests passed (ring, Float32/PCM16, flush).");
    return 0;
}
