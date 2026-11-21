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
2. The issuer makes an offer on the bond with `inceptTrade(manifestAddress)`.
   This selects a finalized on-chain `TextResource` listing the issuance
   conditions and their content hashes. The buyer reviews those documents and
   verifies the hash covering the bond economics, legal manifest, asset token
   and payment contract. The buyer then calls `confirmTrade` with the trade ID
   and the six original fields from `TradeIncepted`. These include the issuer,
   buyer, encoded manifest address and agreement hash, negative aggregate
   nominal position, positive issue-price payment and initial settlement data.
   The one-argument offer uses an empty settlement-data string. Applications
   supplying settlement data use the six-argument ERC-6123 method.
   Confirmation enables delivery of the existing asset.
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
before inception. While an offer is pending, the issuer can select a different
manifest using `inceptTrade(manifestAddress)`. This withdraws the previous offer
and emits `TradeCanceled` and `TradeIncepted` in order, with distinct IDs.
Each ERC-6123 inception tuple remains immutable. A buyer confirming an offer
uses its ID and exact terms. After confirmation or standalone cancellation the
bond cannot be offered again. Maturity repayment uses the confirmed trade ID.
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
