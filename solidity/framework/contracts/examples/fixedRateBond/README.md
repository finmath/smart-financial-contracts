# Fixed-rate bond with an existing ERC-20 asset

This example runs `FixedRateBond`, `FixedRateBondLib` and `FixedRateBondFactory`
against the maintained Smart Product Framework. The factory selects an existing
ERC-20 asset and a local payment adapter. Asset units and cash move between the
issuer's and buyer's wallets on the local test chain.

From `solidity/framework/`, run:

```sh
npm ci
npm run build
npm test
```

The executable walkthrough is
[`FixedRateBondDemoTest.js`](../../../test/FixedRateBondDemoTest.js), with deployment
and term construction in
[`fixedRateBondDemo.js`](../../../test/helpers/fixedRateBondDemo.js).
It needs no RPC endpoint, wallet, external service or real money. Normal Ethereum
contract-size limits remain enabled, including for factory deployment.

## Lifecycle

1. Deploy the existing asset, cash token, client and product registries, resources,
   indications, payment adapter and linked libraries. The registry administrator
   publishes a definition whose factory fixes the asset and payment addresses.
   The buyer and issuer each open a trading contract. The buyer sends a
   nonbinding request to the issuer's trading address. The issuer uses that
   contract to create the bond through the product registry at the requested
   definition revision. The payment operator authorizes the bond in the adapter.
2. The issuer calls ERC-6123 `inceptTrade(issuer, buyer, tradeData, position, paymentAmount, initialSettlementData)`.
   Its application prepares `tradeData` as a lowercase hex string encoding
   `abi.encode(legalDocumentationAddress, agreementHash)`. The address selects
   a finalized `TextResource` containing the text of the issuance conditions. The issuer
   offers the negative aggregate nominal position and positive issue-price payment.
   The buyer reads the legal documentation and verifies the agreement hash against
   the bond economics, documentation content hash, asset token and payment contract. To accept,
   the buyer calls `confirmTrade` with the generated trade ID and all six original
   fields from `TradeIncepted`. Confirmation enables delivery of the existing asset.
3. The issuer approves the asset escrow. The buyer incepts delivery and a matching
   payment. The operator commits two outcome hashes; the bond checks the payment
   context and locks the asset. Success moves cash and asset units atomically.
   Failure returns the units without paying cash. Missing balances or allowances
   leave the attempt recoverable once the participant supplies them.
4. On a coupon payment date, the buyer calls `payCoupon`. The issuer approves that
   payment and the operator completes and settles it. Amounts use ACT/ACT ICMA,
   including a short first period, with rounding down per denomination before
   multiplication by the number of units.
5. At maturity, the issuer requests redemption through `requestTradeTermination`,
   offering the negative redemption amount from the issuer's perspective. The buyer
   accepts through `confirmTradeTermination`, repeating the trade identifier,
   requesting issuer, same negative amount, and identical terms. Settlement returns the asset units to the
   issuer against the redemption payment. The existing token supply remains unchanged.

The four agreement states remain separate from `positionState`, which tracks
delivery, the redemption proposal, authorization to return the units, and repayment.
`tradeId()` exposes the first trade ID, derived from the bond address, even
before inception. To revise an offer, the issuer calls `cancelTrade` with the
pending trade ID and all six inception fields. After `TradeCanceled`, the issuer
can submit another `inceptTrade` on the same bond with the documentation address
fixed by its first successful offer. Using a different resource requires a new
bond. Each new `TradeIncepted` event supplies a fresh ID even when all offer
fields are identical. The buyer confirms the pending offer, and maturity
repayment uses the confirmed trade ID.
The requesting issuer can cancel an unmatched redemption proposal or an accepted
proposal before an asset attempt is active; a later request starts a new proposal.

All six ERC-6123 trade methods allow a participant's authorized operator to submit
the action. A participant calls `setTradeOperator(operator, true)` on this bond to
grant that authority and uses `false` to revoke it. Inception and cancellation
require issuer authority. Confirmation requires buyer authority. Termination
requests and cancellations require the requesting issuer's authority, while
termination confirmation requires buyer authority. Events identify those economic
participants, and all transfers continue between their stored wallets. Token
allowances and the payment adapter's operator role do not grant trade authority.

These approvals cover the bond's trade methods. Asset settlement, payment and
coupon calls retain their own participant and callback authorization rules.

## Components and scope

| Component | Local behavior |
| --- | --- |
| `ClientRegistry` | Shared participant onboarding and eligibility |
| `BondSettlementModules` | Immutable factory-selected asset and payment configuration |
| `DemoToken` | Ordinary integer ERC-20 test balances, allocated once at construction |
| `DemoPayment` | Explicit payer approval, operator-supplied outcome commitments and local cash transfers |
| `DemoAssetLocking` | Generated-key escrow, payment-context checks, delivery, cancellation and retry |
| `DemoInterfaces` | Narrow payment callback and context declarations |

The example has no token-creation or retirement service, securities-identifier
allocation, account-resolution or delegated-account integration. Participants
use their own wallets. It models one bilateral position, not a transferable
holder register or a securities administration service.

The payment adapter is a local demonstration. Its operator controls product
authorization and payment outcomes and must keep outcome preimages private.
It provides no encrypted oracle service, bank settlement or cross-chain finality.
Use ordinary ERC-20 tokens with the documented integer-unit convention;
transfer-tax or rebasing assets are outside this example's scope.

Only the configured payment adapter can submit outcome keys to the bond. This
ensures a visible key cannot release an asset or discharge a coupon before the
local cash transfer. Each coupon retains the single-attempt behavior: cancellation
marks it `Failed` and does not permit another request. Asset settlement supports
fresh attempts after cancellation or failure.

Existing SPDX identifiers and source notices on the retained bond, library and
factory remain applicable. The `demo/` adapters and walkthrough tests are local
integration code.
