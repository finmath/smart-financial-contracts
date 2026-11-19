# Smart Product Framework

This directory contains the Smart Product Framework and demo implementations
originally distributed through the ERC-8100 repository
(`representable-contract-state`). The maintained core includes product definitions,
factories, client approval, indications, XML representation and settlement helpers.
The original bond and interest-rate-swap demos and the FX atomic swap demo have
separate Foundry projects.
The maintained [fixed-rate bond example](contracts/examples/fixedRateBond/README.md)
runs with the core Hardhat tests and uses an existing ERC-20 asset and a local
payment adapter for delivery, coupon payments and redemption between participant wallets.

## Build and test

Use Node.js 22.13 or later for the core package. Run each command block below from
the repository root:

```sh
cd solidity/framework
npm ci
npm run build
npm test
```

The lockfile pins dependencies. Hardhat downloads the Solidity compilers on the
first build. Tests use an isolated chain with normal deployment-size limits and
require no RPC endpoint, wallet or deployment configuration.

Run the original product demos with Node.js and Foundry:

```sh
cd solidity/examples/erc8100-products
npm ci
forge test
```

The independent [FX atomic swap demo](../examples/fx-atomic-swap/README.md) needs Foundry:

```sh
cd solidity/examples/fx-atomic-swap
forge test
```

The example guides describe the product lifecycles and ERC-8100 representation.
Their existing source copies in `representable-contract-state` remain available.

## Contents

| Location | Purpose |
| --- | --- |
| `contracts/smartProductFramework/` | Product definitions, factories, client registry, party trading contracts and indications |
| `contracts/erc8100/` | Representable-state interfaces and text resources |
| `contracts/dvp/` | Settlement and decryption helpers |
| [`contracts/examples/fixedRateBond/`](contracts/examples/fixedRateBond/README.md) | FixedRateBond, its library and factory, with local demo adapters |
| `contracts/mocks/`, `test/` | Core framework, representation and settlement regression tests |
| [`../examples/erc8100-products/`](../examples/erc8100-products/README.md) | Original bond and interest-rate-swap framework demos, with their own dependencies and tests |
| [`../examples/fx-atomic-swap/`](../examples/fx-atomic-swap/README.md) | FX atomic swap contracts, tests and renderer walkthrough |
| `../origins/representable-contract-state/` | Original extracted source history and reference material |
| `../origins/product-framework/` | Retained source license |

The original product demos use their original framework interfaces and an isolated
OpenZeppelin dependency. They are tested separately from the maintained core package.
The general ERC-8100 renderer remains a separate project and service.

## Trading between parties

Deploy `ProductDefinitionRegistry(clientRegistryAddress)`. Its administrative
owner follows `ClientRegistry.owner()`, including ownership transfers. The
administrator versions each definition as a pair consisting of its product
factory and finalized XML terms template. Providers can use different legal
documents when offering products created from the same definition revision.

An active client calls `createTradingContract()` on the factory returned by
`registry.tradingContractFactory()`. Applications use
`factory.tradingContractOf(client)` to discover that party's trading address.
A client can authorize an application with `setOperator(application, true)` on
its own trading contract and revoke it there later. This grants access to
requests and product issuance. Agreement and settlement use the permissions
of the individual product.

The following workflow shows a buyer approaching an issuer.

1. Read the current revision using `registry.productDefinitionState(id).version`.
   From the buyer's trading contract call
   `sendTradeRequest(issuerTradingAddress, id, version, payload)`. The buyer
   can also call `createTradeRequest(id, version, payload)` directly on the
   issuer's trading contract. Both routes record the same buyer identity.
2. Read the request ID from `TradeRequested` on the issuer's trading contract.
   That contract holds the request and exposes `tradeRequestState(requestId)`
   and `getActiveTradeRequests(id)`. The buyer may withdraw it and the issuer
   may reject it. A new definition revision or retirement expires open requests.
   Suspension pauses new requests while allowing existing requests to be fulfilled.
3. The issuer calls `issueProductForRequests(requestIds, productPayload)` on its
   own trading contract. The clients must still be eligible for the definition.
   The product registry deploys through the anchored factory and registers the
   product. A provider can also issue directly from an active definition through
   its trading contract's `issueProduct(id, version, productPayload)`. A fulfilled
   request points to this instance. A newly created bond is still `Inactive`.
4. To make an offer, the issuer calls `inceptTrade(manifestAddress)` on the bond.
   The buyer reviews the offered documents and economics, then calls
   `confirmTrade` with their combined hash. Confirmation enables delivery.

Use `registry.isRegisteredProduct(product)` to verify provenance. Index trading
contract events for request history and registry events for definitions and issues.
The active-request getter returns the entire set for a definition and recipient.
For large inboxes, index the events and check the current definition revision and status.
Deployments using the earlier registry keep their original addresses and state.
Applications integrating a new deployment should discover its trading factory and
read each request at the recipient's trading address.

### Legal documents at agreement

Publish and finalize a `TextResource` containing the manifest once. The same
address can be used for any number of offers. Each entry in the demo manifest
identifies a document by role, URI and content hash. Standard terms can live
in reusable on-chain resources, and private annexes can use access-controlled
locations. The manifest itself is publicly readable on a public chain.

At inception the bond checks the manifest's `ITextResource` interface and
finalization, then records its address and content hash. Applications can read
`legalDocumentsManifest()`, `legalDocumentsHash()` and `legalDocumentsURI()`.
To verify an offer, hash the exact bytes from the manifest's `content()` with
Keccak-256, check them against the recorded hash, and verify the documents
referenced in those bytes.

The issuer's offer and the buyer's confirmation use the same
`keccak256(abi.encode(economicTermsHash, legalDocumentsHash, assetToken, paymentContract))`.
While the offer is open the issuer can replace the manifest. If its content
changes, the buyer must submit the new hash. Once confirmed, the agreed
manifest is fixed. Before the first offer the product reports a zero manifest
address and hash. The [v2 product XML envelope](resources/smart-financial-product-envelope-v2.xsd)
includes `LegalDocuments` with `href` and `integrity` once the issuer selects a manifest.

Integrations using the five-argument `ISDCTrade.inceptTrade` pass the manifest
address as a `0x`-prefixed, 40-digit hex string in `tradeData`. The resulting
`TradeIncepted` event carries the combined agreement hash in its `tradeData`
field. After verifying that hash, the buyer supplies it as a `0x`-prefixed,
64-digit hex string in `ISDCTrade.confirmTrade`. Use the updated ABI when
connecting to new deployments.

## History and licensing

The integration retained the 98 original ERC-8100 framework commits by Christian
Fries (`cfries`) and Raphael Prandtl (`RKP1101`), including the framework branch,
with their history and author dates. Subsequent integration changes were
consolidated into one commit.

Preserve individual SPDX identifiers and license notices. Source licenses and
notices are retained under [`../origins/`](../origins/); dependency licenses remain applicable.
The private npm package metadata does not replace individual file licenses.
