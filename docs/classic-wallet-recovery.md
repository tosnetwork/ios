# Classic wallet recovery

New wallets use Quantum. Existing classic wallets remain usable. Recovery does
not ask users to choose a contract revision or add revision badges to wallets.

Mnemonic **format** confirmation remains necessary: TOS and legacy phrases use
different derivation salts. Hiding a contract-version menu must not silently
change the recovered key. After explicit format resolution, recovery derives
the addresses locally and keeps only that format's candidates.

Recovery retains every candidate with a positive native balance, indexed token
or NFT assets, or unknown account/index state. It falls back to the format's
default revision only when every candidate is known empty. Index queries use
`getAccountTokens` and `getAccountNfts` with `limit: 1`; both lists must explicitly
report boolean `index_state.complete: true` before absence is considered known.
These ordinary RPC results are discovery hints, never authenticated balances or
signing authorization. Multiple recovered wallets receive numeric labels; a
single wallet retains the user's chosen label.

The hardware account picker retains account selection and hardware/watch tags,
without contract revision labels. W4/W5 creation promotions and their unused
coordinator are removed.

Validation uses the repository Makefile. `ClassicWalletRecoveryTests` covers
unsigned amounts, token/NFT hints, uncertainty retention, bounds, duplicate
addresses and numeric labels. `TOSRPCClientTests` exercises the native method
names, bounded parameters and discovery failure through URLSession.

The optional UI test
`testClassicRecoveryAutomaticallyRetainsSixAccountsWithoutVersionMenu` uses
`scripts/tests/classic_recovery_fixture.py` on loopback port 18648. This fixture
returns public, synthetic account balances for the published test phrase. It
accepts at most 512 requests and stops after ten minutes. It never broadcasts,
reads custody or supplies chain proofs. This UI test does not establish actual
network balances or mobile payment correctness.
