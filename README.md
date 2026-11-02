# Sooth Protocol (SOOTH)

`src/SoothToken.sol:SoothToken` is a fixed-supply ERC-20. Its constructor mints
the entire supply to its immediate caller, `msg.sender`, once.

| Property | Value |
| --- | --- |
| Solidity contract identifier | `SoothToken` |
| Token name | `Sooth Protocol` |
| Symbol | `SOOTH` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Constructor payment | None; constructor is nonpayable |
| Initial recipient | Deploying caller; the factory during the specified launch |
| Application contracts | None |

The named constant `INITIAL_SUPPLY` is expressed in smallest units. The token
inherits the unchanged ERC-20 implementation from OpenZeppelin Contracts v5.0.2.
It adds only this constant and the constructor mint. No public or external
function can mint or burn. There is no owner, administrator, initializer,
upgrade mechanism, pause, blacklist, seizure, transfer tax, vesting, or rebase.

## Behavior and assumptions

The brief is interpreted as an ordinary fungible ERC-20: holders transfer their
own tokens and approved spenders use `transferFrom`. Successful transfers and
approvals return `true`; invalid calls revert with OpenZeppelin's ERC-6093
custom errors. Transfers deliver exactly the requested amount, including to
the factory, distributor, and pool manager, without exemptions or address lists.

Zero-value transfers and transfers to the sender are supported. Transfers to
the zero address and approvals to the zero spender are rejected. A finite
allowance decreases when spent; `type(uint256).max` is an unlimited allowance
and remains unchanged. `approve` replaces an existing allowance. Explicit
approvals emit `Approval`; transfers emit `Transfer`. OpenZeppelin v5 does not
emit a new `Approval` event when `transferFrom` spends an allowance, so indexers
should query `allowance` for its current value.

The deploying address has no special authority after the constructor. The
contract neither calls recipients nor depends on external contracts, oracles,
block numbers, timestamps, an RPC endpoint, or chain-specific addresses.
Native-currency payments through ordinary calls are rejected. Tokens sent to
this token contract, or to another address unable to transfer them, cannot be
rescued by an administrator. Such transfers do not reduce `totalSupply`.

## Build and test

Install Foundry and make Solidity **0.8.26** available to it. The repository
contains all Solidity dependencies as ordinary files under `lib/`; it needs
no Git submodules, package installation, environment file, or network access
to build once the pinned compiler is installed.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x45af49bb6f057b30e0c6400032b6aad0ed666e260d9a75751c558f3aed622016 forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, the Cancun EVM target, optimizer enabled
with 200 runs, and `bytecode_hash = "none"`. It enables neither FFI nor filesystem
permissions. No compiler binary is included. Fuzz tests use 1,024 cases each;
stateful invariants use 128 sequences of up to 64 calls. Tests have isolated
setups and do not read or mutate environment variables. The shell seed above
configures Foundry itself.

`test/SoothToken.t.sol` covers metadata, the single constructor mint event,
CREATE2 factory deployment, exact launch allocation/claim transfers, both
directions of pool transfers, balances, allowances, events, zero and maximum
amounts, rejected inputs, unauthorized spending, and rollback on failure. It
also probes absent mint, burn, administration, and upgrade entry points.
`test/SoothToken.invariant.t.sol` checks balances, total supply, and all modeled
allowances after sequences of transfers, approvals, revocations, delegated
spending, and attempted overspending.

The factory and participant addresses in tests are local test fixtures only.
The launch-flow unit test checks token movements, not Uniswap pricing or swaps.
The supplied protected harness additionally checks actual pool seeding and
swaps in the launch verifier. That harness references launch infrastructure and
configuration not included in this project and is not part of the local suite.

## Deployment parameters and responsibilities

Build the `SoothToken` creation bytecode using this root configuration. Deploy
that bytecode with **no constructor arguments and no native currency**. The
creation code has no external library links or constructor dependencies.

For the assigned launch, the target is Robinhood Chain, chain ID **4663**, as
specified by the assignment. The launch factory must be the immediate creator:
it receives all `10^27` units. An intermediate deployment helper would receive
them instead, so the launch must use the token's own creation bytecode directly.
Direct deployment by a wallet gives that wallet the full supply. No recipient,
owner, key, factory address, or pool address is embedded in the token.

The launch service owns manifest generation, transaction submission, source
verification, distribution, and liquidity setup. The assignment supplies the
following launch economics; they are external factory operations and are not
performed by the token constructor:

- 10% (100,000,000 SOOTH) is forwarded to the launch's MerkleDistributor.
- 80% (800,000,000 SOOTH; `poolBps = 8000`) is allocated to pool seeding.
- 10% (100,000,000 SOOTH) is the remainder for
  `0xbb85c1b7540d9e7b56f7a595fc1ff7dd07cb0823`.
- The paired currency is the assignment's 18-decimal IMD token at
  `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`.
- The pool fee is `12500` (1.25%), tick spacing is `60`, and
  `initialMarketCapWei` is `3000000000000000000000` (3,000 IMD).
- The specified provenance `initialPrice` is
  `79228162514264337593543950336`; the deployer derives the actual opening
  price from the launch economics, supply, and token address.

The constructor allocates nothing separately to a distributor, pool, or
recipient. This repository contains no launch manifest or broadcasting script.
Before launch, the launch operator should verify the compiled artifact, chain,
full factory balance immediately after creation, metadata, and supply, then
perform the required distribution and integration checks.

## After launch

There are no settings, privileged roles, keepers, or initialization calls.
Holders are responsible for their balances and approvals. Applications should
use smallest-unit amounts, verify recipient addresses, and request only the
allowance they need. When replacing a nonzero allowance, revoke it and wait
for confirmation before setting the new amount to reduce the usual ERC-20
approval race. Revocation cannot reverse spending already included onchain.
The factory and liquidity operators are responsible for launch distribution
and pool operation; the token cannot correct an erroneous allocation or
reverse a transfer. Chain availability and transaction inclusion remain
properties of the target network.

## Dependencies and review

Vendored sources and licenses are included from
[OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2)
and [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7).
Only the OpenZeppelin ERC-20 dependency closure is included; forge-std is used
only by tests. `lib/dependencies.json` records upstream archive URLs and SHA-256
hashes for the archives and every vendored file. Vendored code is unmodified.

The implementation review is recorded in `docs/REVIEW.md`. Local tests and
review do not replace the launch network's independent adversarial review.
