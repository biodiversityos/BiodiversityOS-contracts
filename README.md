# BiodiversityOS — Registry Contracts

`BiodiversityRegistry` is an append-only registry of wildlife sightings on Celo.

## Design

Records are **not stored on-chain**. `submitRecord` emits an event and returns an
id; the indexer replays those events into Postgres and serves them over GraphQL.
Only `recordReporter[id]` is kept in storage, which is what makes authorship
enforceable without paying to store the record itself.

Consequences worth knowing before you touch the data:

- **Emitted events are permanent.** `voidRecord` tells indexers to drop a row and
  `updateRecord` supersedes one, but neither erases the original event from chain
  history. Anything published here — including free text in `comment` — is public
  forever. Treat the import as a publication, not a database write.
- The indexer database is the only queryable view. Losing it means re-indexing
  from `START_BLOCK`, which must equal the registry's deployment block.

## Access model

Writing is curated, not open:

- `owner` administers the whitelist and can transfer ownership.
- Only whitelisted addresses may `submitRecord`.
- Only a record's original reporter, or the owner, may `updateRecord` / `voidRecord`.
- The deployer is whitelisted by the constructor, so it can seed data immediately.

## Development

```bash
forge build
forge test
```

## Runbook

Everything below assumes `.env` holds `PRIVATE_KEY` and `CELO_SEPOLIA_RPC_URL`.

### 1. Deploy

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url celo_sepolia --broadcast
```

Record two things from the output: the **contract address** and the **block
number** it landed in. The indexer needs the block as `START_BLOCK`; starting
lower just wastes RPC calls, starting higher silently loses records.

### 2. Accredit reporters

```bash
REGISTRY=0x… REPORTERS=0xaaa,0xbbb GRANT=true \
  forge script script/Whitelist.s.sol:Whitelist --rpc-url celo_sepolia --broadcast
```

`GRANT=false` revokes. Revoking does not strand a reporter's existing records —
they can still correct them.

### 3. Prepare field data

```bash
python3 tools/prepare_data.py 'sharks database.xlsx' -o data/sightings.json
```

Defaults to `--privacy redact`, which strips observer names and URLs from the
free text. `--privacy raw` publishes observations verbatim; only use it when
every named person has consented to permanent publication. `--privacy drop`
omits comments entirely.

Read the summary it prints. Species it cannot map fall back to `unknown` and are
reported as warnings — fix the mapping rather than importing `unknown` rows.

### 4. Import

```bash
cd tools && npm install
node import.mjs --registry 0x… --dry-run     # estimate gas, broadcast nothing
node import.mjs --registry 0x…               # for real
```

The importer resumes from `nextRecordId`, so a run interrupted halfway can be
restarted without duplicating rows. Batches default to 25 records; 40 fits
comfortably in a block and costs roughly 37k gas per record.

### 5. Point the indexer at the new registry

Set `CONTRACT_ADDRESS` and `START_BLOCK` in the indexer's `.env`, wipe its
database volume, and redeploy. A stale database indexed against a previous
registry will silently mix old and new record ids.

## Retiring a key

`transferOwnership` moves administration. It does **not** move the whitelist
entry — grant the new owner explicitly if it should also be able to submit.
