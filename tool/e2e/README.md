# Backend end-to-end tests

Exercises the generated backend against a **real MongoDB replica set**
(downloaded and run in-memory by `mongodb-memory-server` — no Docker, no
Atlas account, no network service).

```bash
cd example && dart run ../bin/setup.dart --force   # regenerate the backend
cd ../tool/e2e && npm install && npm test
```

It covers what unit tests cannot: ownership enforcement across two users,
field allowlisting, `$set` merge semantics, transactional batches, tombstone
delivery, and the incremental pull watermark.
