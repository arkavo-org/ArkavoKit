# NTDF Streaming Status - 2025-12-11

## Current State: Frame Forwarding & Decryption Fixed, Testing Display

### What's Working
1. **v12 (L1L) header format** - OpenTDFKit NanoTDFCollectionBuilder now defaults to v12
2. **GMAC binding** - Fixed arkavo-rs to use 8 bytes (not 16) per NanoTDF spec 3.3.1.3
3. **KAS rewrap** - Successfully returns wrapped key (60 bytes) and session key (33 bytes)
4. **Session key parsing** - Client now handles raw SEC1 65-byte format from server
5. **Symmetric key unwrap** - 256-bit key successfully derived
6. **Decryptor initialization** - Reports success
7. **Sequence headers** - Video (SPS/PPS) and Audio (48kHz stereo) parsed correctly
8. **Publisher video frames** - ArkavoCreator now sends video frames correctly
9. **Server frame forwarding** - arkavo-rs now relays client-encrypted NTDF frames to subscribers
10. **Subscriber frame reception** - iOS app receives video/audio frames from server

### Recent Fixes (2025-12-11)

#### arkavo-rs RTMP Server (`session.rs`)
**Bug:** When `encryption_mode` was `Encrypted` but `collection` was `None` (client-side encryption), frames were silently dropped.

**Fix:** Added else branch to relay frames as-is when server has no collection (client did encryption):
```rust
EncryptionMode::Encrypted => {
    if let Some(ref collection) = self.collection {
        // Server-side encryption
        let encrypted = encrypt_item(collection, data)?;
        self.relay_frame(RelayFrame { ... data: encrypted });
    } else {
        // Client-side encryption (NTDF): relay frames as-is
        self.relay_frame(RelayFrame { ... data: data.to_vec() });
    }
}
```

#### ArkavoKit Subscriber (`NTDFStreamingSubscriber.swift`)
**Bug:** Subscriber tried to decrypt entire FLV frame including 5-byte video header or 2-byte audio header.

**Fix:** Strip FLV header before decryption, then reconstruct:
```swift
// Video: 5-byte FLV header [frameType|codec][packetType][compositionTime x3]
let flvHeader = frame.data.prefix(5)
let encryptedPayload = frame.data.dropFirst(5)
let decryptedPayload = try await decryptor.decrypt(Data(encryptedPayload))
decryptedData = Data(flvHeader) + decryptedPayload

// Audio: 2-byte FLV header [soundFormat|rate|size|channels][aacPacketType]
let flvHeader = frame.data.prefix(2)
let encryptedPayload = frame.data.dropFirst(2)
```

### What's Still Being Tested
- **Video display** - Verifying decrypted frames display correctly on AVSampleBufferDisplayLayer
- **Audio playback** - Verifying decrypted audio frames play correctly

### Key Files Modified
- `/Users/paul/Projects/arkavo/arkavo-rs/src/modules/rtmp/session.rs` - Server frame relay fix
- `/Users/paul/Projects/arkavo/app/ArkavoKit/Sources/ArkavoStreaming/RTMP/NTDFStreamingSubscriber.swift` - FLV header stripping

### Wire Format Reminder
- FLV Video: `[1-byte header][1-byte packetType][3-byte compositionTime][NTDF encrypted payload]`
- FLV Audio: `[1-byte header][1-byte packetType][NTDF encrypted payload]`
- NTDF Collection item: `[3-byte IV][3-byte length][ciphertext+16-byte tag]`
- Publisher sends NTDF header frame before each keyframe for late-joining subscribers
- Magic bytes `NTDF` (0x4E544446) identify header frames in video stream

### Logs to Look For
After server fix:
- `🎬 [NTDFSub] Frame #N ARRIVING:` - frames now arriving
- `🎬 [NTDFSub] Decrypted frame #N:` - successful decryption
- `📺 [LiveStreamVM] Frame #N ENQUEUED` - frames sent to display layer
