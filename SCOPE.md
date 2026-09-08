# Scope — what is open source, and what is not

**Spojiti Private Messenger Core** is the free text-messaging path of Spojiti:
the client half
([spojiti-core-app](https://github.com/Spojiti/spojiti-core-app)) and the relay
half ([spojiti-core-relay](https://github.com/Spojiti/spojiti-core-relay)),
under the GNU AGPL v3. This document is the same in both repositories.

The Spojiti product is not open source. This is a deliberate line, and it is
worth stating plainly rather than leaving people to work it out from what is
missing.

## What is here

Everything the free tier needs to carry a text message end to end:

* the identity — twelve words, and every key derived from them;
* the session — X3DH with an ML-KEM-1024 leg, then a Double Ratchet;
* post-quantum authentication — ML-DSA-65 over the classical prekey, gated by
  NIST vectors that run on the device;
* sealed sender — the envelope the relay cannot attribute, and the anonymous
  socket that carries it;
* the relay — registration, the prekey directory, the queue, the sealed lane,
  retention and deletion;
* the tests that hold all of it to its claims.

In the client repository, the files under `lib/crypto/` and `lib/net/` are
byte-identical to the ones in the shipping app. That is the property that makes
this code worth auditing rather than merely worth reading.

## What is not here

Groups, voice and video calls, media of any kind, presence, receipts, typing
indicators, multi-device, push notifications, public communities, the
operations console, the fallback and disaster-recovery paths, the store and
web billing, and every paid tier. The product UI is not here either.

A fork of this repository is a working private messenger. It is not Spojiti,
and it should not be called Spojiti — the name and the mark are not licensed
with the code.

## Why this line

The architecture claim — that the service knows no one — is a claim about the
protocol and the relay, and a claim like that is worthless unless someone
outside the company can check it. So the protocol and the relay are published.
The rest of the product is how the company stays alive to keep running it.

The independent security audit covers the full product, not only this
repository. Independent audit in progress — expected by end of 2026, on track.

## Reporting a problem

Security reports: https://spojiti.world/.well-known/security.txt

Please report anything that affects users of the shipping app privately and
first, whether you found it here or there.
