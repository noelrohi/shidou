import os

/// The two pairing failures a screen cannot show.
///
/// Everything else on this path already speaks for itself: a rejected code,
/// an unreachable daemon, and a bad token all put words in front of the user.
/// These two do not. A camera that never delivers a metadata object looks
/// identical to a user aiming badly, and a Keychain that refuses the write
/// looks like nothing at all. Streaming this subsystem is how the next device
/// session tells those apart.
///
/// Never log a token.
let pairingLog = Logger(subsystem: "dev.shidou.ios", category: "pairing")
