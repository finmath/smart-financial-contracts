# ERC-6123 specification and reference implementation

This package started from `ERCS/erc-6123.md` and `assets/erc-6123/`
in `~/git/ERCs` at
[`56c2308c8d69e75e417bc2d2d551ff6f463ec18d`](https://github.com/finmath/ERCs/commit/56c2308c8d69e75e417bc2d2d551ff6f463ec18d).
It now develops the explicit-party draft revision described below. This revision
has not been copied back to that source checkout.

The local build uses Node.js 22.13 or newer, Hardhat 2, Solidity 0.8.24 and
OpenZeppelin 5.0.2. A lockfile fixes the dependency versions. Solidity 0.8.24 is
required by the included FX reference example; its `ISDCTrade` import is adjusted
for its directory within this package. Package metadata points to this repository.

The maintained [FX Atomic Swap demo](../../examples/fx-atomic-swap/README.md)
provides a Foundry lifecycle suite and renderer walkthrough. Its implementation and
the FX reference copy under `contracts/examples/` use the same trade conventions.

## Explicit-party draft revision

Inception returns a generated identifier. Confirmation and cancellation supply that
identifier together with the complete inception tuple:

```solidity
string memory tradeId = inceptTrade(inceptor, counterparty, tradeData, position, paymentAmount, initialSettlementData);
confirmTrade(tradeId, inceptor, counterparty, tradeData, position, paymentAmount, initialSettlementData);
cancelTrade(tradeId, inceptor, counterparty, tradeData, position, paymentAmount, initialSettlementData);
```

The contract generates a nonempty `tradeId` at inception and returns it to the caller.
That identifier is lifetime-unique within the contract.
Confirmation and cancellation repeat it together with every original term. A used
identifier cannot be reused after cancellation or completion. In `SDCSingleTrade`,
canceling an unconfirmed quote permits a fresh inception with a new identifier;
stale confirmation or cancellation calls cannot consume that new quote, even when
its economic terms are identical.

The derivative and FX references share `TradeIdGenerator`, which generates decimal
identifiers from a per-contract counter starting at `1`. The counter never resets,
including after cancellation; a reverted transaction does not consume an identifier.

The inceptor's amounts and participant order remain unchanged at confirmation.
Each termination method takes `(tradeId, requestingParty, terminationPayment,
terminationTerms)`, with the payment always viewed from the original requesting
party. These are breaking ABI and amount-convention changes; use the updated
interfaces and examples together. Legacy derivatives in `../../derivatives/` retain
their older ABI.

The reference implementations inherit `TradeAuthorizable`. A participant can
submit its own trade actions or authorize an operator on that particular contract:

```solidity
// Sent by the participant that grants the authority:
setTradeOperator(operator, true);
// Sent by that same participant to revoke it:
setTradeOperator(operator, false);
```

An approval covers all six trade methods for the granting participant's role on
that instance. Inception and cancellation require the inceptor's authority;
confirmation requires the counterparty's authority. Termination request/cancellation
require the requester's authority; confirmation requires the opposite party's
independent authority. Approving one party's operator grants no authority for the
other party. Revocation is checked when each action executes, and token allowances
and settlement callbacks retain separate authorization.

The shared trade interface does not prescribe this approval mechanism. An
implementation may use a different authenticated operator or signature policy.
Events continue to identify the economic participants, including when operators
submit transactions. Transfer destinations remain the stored parties.

Run from this directory:

```sh
npm ci --ignore-scripts
npm test
```

## Description

The reference SDC implementation can be unit tested with Hardhat to understand the trade process logic.

### Compile and run tests with Hardhat

We provide the essential steps to compile the contracts and run the provided unit tests.

### Provided Contracts and Tests

#### Interfaces

- `contracts/ISDC.sol` - Interface contract (aggregation of `ISDCTrade`, `ISDCSettlement`, `IAsyncTransferCallback`)
- `contracts/ISDCTrade.sol` - Interface related to trade incept/confirm/terminate
- `contracts/ISDCSettlement.sol` - Interface related to settlement initiate/perform/after
- `contracts/IAsyncTransferCallback.sol` - Interface related to transfer.

- `contracts/IAsyncTransfer.sol` - Asynchronous transfer interface for settlement tokens used in `SDCSingleTradePledgedBalance`.

#### Implementations

- `contracts/TradeAuthorizable.sol` - Per-contract, revocable operator approvals used by the reference implementations
- `contracts/TradeIdGenerator.sol` - Contract-generated decimal identifiers that are never reused
- `contracts/SDCSingleTrade.sol` - SDC abstract contract for an OTC Derivative (single trade case only)
- `contracts/SDCSingleTradePledgedBalance.sol` - SDC full implementation for an OTC Derivative (single trade case only)
- `contracts/ERC20Settlement.sol` - Mintable ERC-20 settlement token implementing `IAsyncTransfer` for unit tests

#### Tests

- `test/SDCTests.js` - SDC lifecycle and balance tests
- `test/TradeOperatorsTest.js` - Delegated trades, exact matching, revocation and replay checks

### Compile and run tests with Hardhat

Install dependencies:
```shell
npm ci --ignore-scripts
```

Compile:
```shell
npx hardhat compile
```

Run all tests:
```shell
npx hardhat test
```

### Configuration files

- `package.json` - JavaScript package definition.
- `hardhat.config.js` - Hardhat config.

### Used javascript-based testing libraries for solidity

- `ethereum-waffle`: Waffle is a Solidity testing library. It allows you to write tests for your contracts with JavaScript.
- `chai`: Chai is an assertion library and provides functions like expect.
- `ethers`: This is a popular Ethereum client library. It allows you to interface with blockchains that implement the Ethereum API.
- `solidity-coverage`: This library gives you coverage reports on unit tests with the help of Istanbul.

## Version history / release notes

### Unreleased

- Contract-generated, lifetime-unique trade IDs returned by inception and required for confirmation and cancellation.
- Explicit trade participants and termination requester, independent of the caller.
- Identical participant order and signed amounts across proposal, confirmation and cancellation.
- Complete context matching and per-contract operator approvals in the reference implementations.
- The SDC trade ID is no longer mutable through a public setter; settlement callbacks require the configured token.

### 0.8.0

- Re-introduced the method `afterSettlement` that can be used to check pre-conditions of the next settlement cycle, e.g., triggered by a time-oracle.
- Added the event `SettlementAwaitingInitiation` which should be issued when the trade goes active and when `afterSettlement` veryfied that the trade is ready for the next settlement.
