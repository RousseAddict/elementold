#ifndef opus_bridge_h
#define opus_bridge_h

/* Decode an Ogg/Opus file (e.g. a WhatsApp voice note bridged via
   mautrix-whatsapp) into a canonical 16-bit PCM WAV file that iOS 6's
   AVAudioPlayer can play (it has no Opus decoder).
   Returns 0 on success, a negative error code on failure. */
int opus_ogg_to_wav(const char *inPath, const char *outPath);

#endif /* opus_bridge_h */
