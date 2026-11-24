# Smart Product Framework

This directory contains the Smart Product Framework and demo implementations
originally distributed through the ERC-8100 repository
(`representable-contract-state`). The maintained core includes product definitions,
factories, client approval, indications, XML representation and settlement helpers.
The original bond and interest-rate-swap demos and the FX Spot Trade demo have
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

The fixed-rate bond imports `ISDCTrade` through the local `@finmath.net/sdc`
dependency at [`../ercs/erc-6123/`](../ercs/erc-6123/README.md). Interface changes
there are therefore checked by the framework build and lifecycle tests.

Run the original product demos with Node.js and Foundry:

```sh
cd solidity/examples/erc8100-products
npm ci
forge test
```

The independent [FX Spot Trade demo](../examples/fx-spot-trade/README.md) needs Foundry:

```sh
cd solidity/examples/fx-spot-trade
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
| [`../examples/fx-spot-trade/`](../examples/fx-spot-trade/README.md) | FX Spot Trade contracts, tests and renderer walkthrough |
| `../origins/representable-contract-state/` | Original extracted source history and reference material |
| `../origins/product-framework/` | Retained source license |

The original product demos use their original framework interfaces and an isolated
OpenZeppelin dependency. They are tested separately from the maintained core package.
The general ERC-8100 renderer remains a separate project and service.

Text-resource `ChunkAppended` events index the sender, storage pointer and chunk
index for log filtering. The chunk length is in the event data. Event decoders
must use the ABI of the deployed resource.

## Trading between parties

Deploy `ProductDefinitionRegistry(clientRegistryAddress)`. Its administrative
owner follows `ClientRegistry.owner()`, including ownership transfers. The
administrator versions each definition as a pair consisting of its product
factory and finalized XML terms template. Each issued product can use its own
legal documentation, even when several products share a definition revision.

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
4. The issuer makes an offer through the bond's ERC-6123 `inceptTrade` method.
   Its `tradeData` contains the address of the finalized legal documentation
   and the agreement hash. The buyer reviews the text and economics, then calls `confirmTrade` with
   the generated trade ID and all six original inception fields. Confirmation
   fixes the agreement and enables delivery.

Use `registry.isRegisteredProduct(product)` to verify provenance. Index trading
contract events for request history and registry events for definitions and issues.
The active-request getter returns the entire set for a definition and recipient.
For large inboxes, index the events and check the current definition revision and status.
Deployments using the earlier registry keep their original addresses and state.
Applications integrating a new deployment should discover its trading factory and
read each request at the recipient's trading address.

### Legal documentation for an issued product

The issuer publishes the legal text in a single finalized `TextResource`.
The first successful `inceptTrade` records that resource's address and content
hash for the lifetime of the product. Several issued products can reuse the
same resource. The text is publicly readable on a public chain.

Applications can read the resource address from `legalDocumentation()`, its
recorded hash from `legalDocumentationHash()` and its URI from
`legalDocumentationURI()`. To verify the text, read the resource's `content()`,
compute Keccak-256 over those exact bytes and compare it with the recorded hash.

The issuer's application prepares the agreement hash as
`keccak256(abi.encode(economicTermsHash, legalDocumentationHash, assetToken, paymentContract))`,
using the finalized resource's content hash for `legalDocumentationHash`. It
encodes the resource address and agreement hash together as `tradeData`. In ethers, use
`AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [legalDocumentationAddress, agreementHash])`.
The issuer supplies the negative aggregate nominal position and the positive
issue-price payment. `TradeIncepted` emits the generated trade ID and the original
fields, including the initial settlement data.

To revise a pending offer, the issuer first calls `cancelTrade` with its ID and
exact inception fields. Once the cancellation succeeds, the issuer can call
`inceptTrade` again on the same bond using the exact same legal documentation
address. Each new offer receives a fresh ID. A different legal documentation
resource requires a new product instance. The issuer can authorize
a bond operator to offer or withdraw, and the buyer can authorize one to confirm.

Before the first successful offer the product reports a zero resource address
and hash. From that offer onward, its XML contains one `LegalDocumentation`
element with the resource URI in `href` and the content hash in `integrity`.
See the [v2 product XML envelope](resources/smart-financial-product-envelope-v2.xsd).

## History and licensing

The integration retained the 98 original ERC-8100 framework commits by Christian
Fries (`cfries`) and Raphael Prandtl (`RKP1101`), including the framework branch,
with their history and author dates. Subsequent integration changes were
consolidated into one commit.

Preserve individual SPDX identifiers and license notices. Source licenses and
notices are retained under [`../origins/`](../origins/); dependency licenses remain applicable.
The private npm package metadata does not replace individual file licenses.
