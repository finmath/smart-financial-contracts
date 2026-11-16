# ERC-6123 specification and reference implementation

This package is synchronized from `ERCS/erc-6123.md` and `assets/erc-6123/`
in the local `~/git/ERCs` checkout. The latest commit affecting those paths is
[`56c2308c8d69e75e417bc2d2d551ff6f463ec18d`](https://github.com/finmath/ERCs/commit/56c2308c8d69e75e417bc2d2d551ff6f463ec18d).
The specification content and five interface files match that revision.

The local build uses Node.js 22.13 or newer, Hardhat 2, Solidity 0.8.24 and
OpenZeppelin 5.0.2. A lockfile fixes the dependency versions. Solidity 0.8.24 is
required by the included FX reference example; its `ISDCTrade` import is adjusted
for its directory within this package. Package metadata points to this repository.

The maintained [FX Atomic Swap demo](../../examples/fx-atomic-swap/README.md)
includes additional lifecycle checks and tests. The example under this package's
`contracts/examples/` is the reference copy accompanying the imported standard.

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

- `contracts/SDCSingleTrade.sol` - SDC abstract contract for an OTC Derivative (single trade case only)
- `contracts/SDCSingleTradePledgedBalance.sol` - SDC full implementation for an OTC Derivative (single trade case only)
- `contracts/ERC20Settlement.sol` - Mintable ERC-20 settlement token implementing `IAsyncTransfer` for unit tests

#### Tests

- `test/SDCTests.js` - Unit tests for the life-cycle of the sdc implementation

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

### 0.8.0

- Re-introduced the method `afterSettlement` that can be used to check pre-conditions of the next settlement cycle, e.g., triggered by a time-oracle.
- Added the event `SettlementAwaitingInitiation` which should be issued when the trade goes active and when `afterSettlement` veryfied that the trade is ready for the next settlement.
