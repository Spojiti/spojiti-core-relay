# Spojiti Private Messenger Core — relay

The relay half of **Spojiti Private Messenger Core**: the free text-messaging
path of [Spojiti](https://spojiti.world), published so the zero-PII
architecture and the cryptography can be verified line by line, and so anyone
can run the relay for themselves.

Licence: GNU AGPL v3 (see `LICENSE`). Copyright (C) 2026 CognitionX Logic India
Pvt Limited.

## What this is

A blind relay for end-to-end encrypted messaging. It holds live WebSocket
connections, stores sealed envelopes until they are collected, and deletes
them on delivery. Its whole durable set is public keys, one prekey directory
per account, and envelopes with an expiry. There is no name, phone number,
e-mail address, contact list, device list or sender anywhere in it — the
`priv/repo/migrations` folder is the proof, and it is one file.

What the relay learns: which random account id an envelope is for, the
ciphertext in transit, and the network address a connection came from. What
it never learns: who an account belongs to, what a message says, or — for a
sealed envelope — who wrote it.

## The doors

HTTP (`lib/spojiti_relay_web/router.ex`):

| Door | What |
|---|---|
| `GET /api/health` | liveness + version |
| `GET /api/pow` · `POST /api/register` | registration behind a proof of work; the account is an identity key, a signing key, a signed prekey, one-time prekeys and (optionally) an ML-KEM-1024 prekey with an ML-DSA-65 signature |
| `GET /api/keys/:account_id` | a peer's public key bundle (one one-time prekey is consumed per read) |
| `POST /api/login/challenge` · `/verify` | re-authentication by signing a 32-byte challenge |
| `POST /api/keys` · `/keys/pq` · `/keys/pqauth` · `/keys/caps` | replenish one-time prekeys, publish the post-quantum prekey and signing key, publish capabilities (`sealed`) |

Sockets (`lib/spojiti_relay_web/endpoint.ex`):

* `/socket` — the authenticated queue (`queue:<account_id>`): flush on join,
  `message:send`, `message:send_batch`, `message:ack`.
* `/sealed` — the anonymous lane (`sealed:lobby`): `sealed:send`,
  `sealed:send_batch`. No token, no account. A sealed envelope arrives here so
  the relay never sees a sender on the socket that carries it, and the row is
  stored with no sender. Per-connection, per-recipient and per-address rate
  limits; an optional proof of work at join (`SEALED_POW_REQUIRED`).

Both lanes feed one delivery door (`lib/spojiti_relay_web/delivery.ex`).

## Run it

Elixir 1.15+, Erlang/OTP 25+, PostgreSQL 14+.

```
mix deps.get
mix ecto.create && mix ecto.migrate
mix phx.server          # http://localhost:4000/api/health
mix test
```

Production: set `DATABASE_URL`, `SECRET_KEY_BASE` (`mix phx.gen.secret`),
`PHX_HOST`, `PORT`; put a TLS terminator in front (the relay speaks plain
HTTP on `PORT`). Optional: `POW_BITS` (18), `POW_REQUIRED` (true),
`SEALED_CONNECTS_PER_MIN` (600), `SEALED_POW_REQUIRED` (false).

## What is deliberately not here

Media, calls, payments, multi-device, push notifications, public communities
(Echoes), the operations console, the fallback and disaster-recovery paths,
and every paid tier. Those are the product. This is the path that proves the
architecture: one device per account, one retention window, text.

## Verify the claims

* No PII column: `priv/repo/migrations/*_create_core.exs`.
* No sender on a sealed envelope: `lib/spojiti_relay_web/channels/sealed_channel.ex`
  and `test/spojiti_relay_web/channels/sealed_channel_test.exs`.
* Envelopes die on delivery: `lib/spojiti_relay/messaging.ex` (`ack/2`) and
  `test/spojiti_relay_web/channels/queue_channel_test.exs`.
* Logs redact who talks to whom: `config/config.exs` (`filter_parameters`).

Security reports: https://spojiti.world/.well-known/security.txt
