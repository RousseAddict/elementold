#include "opus_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ogg/ogg.h>
#include <opus/opus.h>

/* Opus always decodes to 48 kHz; 5760 samples/channel = 120 ms, the largest
   frame a single Opus packet can produce. */
#define OPUS_OUT_RATE 48000
#define MAX_FRAME     5760

static void write_le32(unsigned char *p, unsigned int v) {
    p[0] = (unsigned char)(v);       p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}
static void write_le16(unsigned char *p, unsigned short v) {
    p[0] = (unsigned char)(v); p[1] = (unsigned char)(v >> 8);
}

/* Overwrites the reserved 44 bytes at the start of `f` with a canonical PCM
   WAV header now that the total data size is known. */
static int write_wav_header(FILE *f, int channels, int sampleRate, unsigned int dataBytes) {
    unsigned char h[44];
    unsigned int byteRate = (unsigned int)(sampleRate * channels * 2);
    memcpy(h, "RIFF", 4);
    write_le32(h + 4, 36 + dataBytes);
    memcpy(h + 8, "WAVE", 4);
    memcpy(h + 12, "fmt ", 4);
    write_le32(h + 16, 16);
    write_le16(h + 20, 1);                              /* PCM */
    write_le16(h + 22, (unsigned short)channels);
    write_le32(h + 24, (unsigned int)sampleRate);
    write_le32(h + 28, byteRate);
    write_le16(h + 32, (unsigned short)(channels * 2)); /* block align */
    write_le16(h + 34, 16);                             /* bits per sample */
    memcpy(h + 36, "data", 4);
    write_le32(h + 40, dataBytes);
    if (fseek(f, 0, SEEK_SET) != 0) return -1;
    if (fwrite(h, 1, 44, f) != 44) return -1;
    return 0;
}

int opus_ogg_to_wav(const char *inPath, const char *outPath) {
    FILE *in = fopen(inPath, "rb");
    if (!in) return -1;
    FILE *out = fopen(outPath, "wb");
    if (!out) { fclose(in); return -2; }

    /* Reserve space for the header; patched in once dataBytes is known. */
    unsigned char zero[44];
    memset(zero, 0, sizeof(zero));
    fwrite(zero, 1, 44, out);

    ogg_sync_state oy;
    ogg_stream_state os;
    ogg_page og;
    ogg_packet op;
    ogg_sync_init(&oy);

    int stream_init = 0;
    int have_head = 0;
    long packet_count = 0;
    int channels = 0;
    int err = 0;
    long skip_remaining = 0;      /* OpusHead pre-skip, discarded from output */
    OpusDecoder *dec = NULL;
    opus_int16 *pcm = NULL;
    unsigned int dataBytes = 0;
    int rc = 0;
    int eof = 0;

    while (!eof) {
        char *buf = ogg_sync_buffer(&oy, 4096);
        size_t n = fread(buf, 1, 4096, in);
        ogg_sync_wrote(&oy, (long)n);
        if (n == 0) eof = 1;

        while (ogg_sync_pageout(&oy, &og) == 1) {
            if (!stream_init) {
                ogg_stream_init(&os, ogg_page_serialno(&og));
                stream_init = 1;
            }
            if (ogg_stream_pagein(&os, &og) != 0) continue;

            while (ogg_stream_packetout(&os, &op) == 1) {
                if (packet_count == 0) {
                    /* OpusHead: "OpusHead"(8) ver(1) channels(1) preskip(2 LE) ... */
                    if (op.bytes < 19 || memcmp(op.packet, "OpusHead", 8) != 0) { rc = -3; goto done; }
                    channels = op.packet[9];
                    if (channels < 1 || channels > 2) { rc = -4; goto done; }
                    skip_remaining = (long)(op.packet[10] | (op.packet[11] << 8));
                    dec = opus_decoder_create(OPUS_OUT_RATE, channels, &err);
                    if (!dec || err != OPUS_OK) { rc = -5; goto done; }
                    pcm = (opus_int16 *)malloc(sizeof(opus_int16) * MAX_FRAME * channels);
                    if (!pcm) { rc = -6; goto done; }
                    have_head = 1;
                } else if (packet_count == 1) {
                    /* OpusTags comment header — ignore. */
                } else {
                    int samples = opus_decode(dec, op.packet, (opus_int32)op.bytes,
                                              pcm, MAX_FRAME, 0);
                    if (samples > 0) {
                        int start = 0;
                        if (skip_remaining > 0) {
                            int s = samples < skip_remaining ? samples : (int)skip_remaining;
                            start = s;
                            skip_remaining -= s;
                        }
                        int frames = samples - start;
                        if (frames > 0) {
                            size_t count = (size_t)frames * (size_t)channels;
                            if (fwrite(pcm + (size_t)start * (size_t)channels,
                                       sizeof(opus_int16), count, out) != count) { rc = -7; goto done; }
                            dataBytes += (unsigned int)(count * 2);
                        }
                    }
                    /* samples < 0 -> corrupt packet; skip it and keep going. */
                }
                packet_count++;
            }
        }
    }
    if (!have_head) rc = -8;

done:
    if (dec) opus_decoder_destroy(dec);
    if (pcm) free(pcm);
    if (stream_init) ogg_stream_clear(&os);
    ogg_sync_clear(&oy);

    if (rc == 0) {
        if (write_wav_header(out, channels, OPUS_OUT_RATE, dataBytes) != 0) rc = -9;
    }
    fclose(out);
    fclose(in);
    if (rc != 0) remove(outPath);
    return rc;
}
