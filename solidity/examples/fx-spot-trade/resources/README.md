# FX Spot Trade XML profile

[fx-spot-trade-template.xml](fx-spot-trade-template.xml) represents the latest
trade through ERC-8100 bindings. It uses the same `SmartFinancialProduct` envelope
as `smart-bond-contract`, described by the shared
[ProductLib](../../../framework/contracts/smartProductFramework/products/ProductLib.sol)
and [envelope schema](../../../origins/representable-contract-state/representable-contract-state-core/src/main/resources/xsd/smart-product-framework/smart-financial-product-envelope.xsd).

| Selector | Value |
| --- | --- |
| Envelope namespace | `urn:smart-product-framework:financial-product:1.0` |
| `schemaVersion` | `1.0.0` |
| Product `type` / `typeVersion` | `FxSpotTrade` / `1.0.0` |
| Terms `type` / `version` | `FxSpotTradeState` / `1.0.0` |
| Terms namespace | `urn:example:fx-spot-trade` |

`DeploymentState` exposes the shared settlement router. `ProductResources`
contains `ProductTermsTemplate` with the inline `FxSpotTrade` state and a
`ProductDocumentationTemplate` stylesheet reference. All 12 calls are evaluated
at one fixed block. The state profile is defined in
[fx-spot-trade-state.xsd](fx-spot-trade-state.xsd).

The trade API and lifecycle are unchanged. This template follows the latest
`tradeId`; earlier trades remain accessible through `getTrade(id)`. Amounts stay
signed integers in the token's smallest unit, viewed from the inceptor: positive
receives and negative delivers. `tradeData` and `initialSettlementData` remain
escaped, opaque strings; their contents are not inserted as XML nodes.

## Relationship to FpML

FpML's [`fxSingleLeg`](https://www.fpml.org/about/product-summary/) represents FX
spot and forward trades. It is the semantic reference for these two currency-token
legs. This profile describes on-chain token state; it is not a schema-conformant
FpML confirmation document and does not use the FpML namespace.

| Contract state | FpML projection |
| --- | --- |
| `baseToken`, `position` | `exchangedCurrency1` |
| `quoteToken`, `paymentAmount` | `exchangedCurrency2` |
| Inceptor and counterparty | Each leg's payer and receiver references, chosen from the amount's sign |
| Absolute token amount | `paymentAmount/amount`, divided by `10^decimals` to obtain currency units |
| Two scaled amounts | `exchangeRate`, with an explicit quote convention |

For a positive signed amount, the counterparty pays the inceptor; for a negative
amount, the inceptor pays the counterparty. A quote-per-base rate is
`(abs(paymentAmount) / 10^quoteDecimals) / (abs(position) / 10^baseDecimals)`.

A complete FpML projection needs trusted currency codes, token decimal scales,
party identifiers, a contractual value date and a quote convention. The contract
does not supply all of these. Token symbols are not ISO currency codes, and the
snapshot block date is not a contractual value date. The repository's
[FpML 5.9 confirmation schema](../../../../src/main/resources/schemas/fpml-schemas/fpml-fx-5-9.xsd)
requires two payment legs, settlement date information and an exchange rate;
[payment amounts](../../../../src/main/resources/schemas/fpml-schemas/fpml-shared-5-9.xsd)
are nonnegative quantities in currency units.

[CDM](https://cdm.finos.org/docs/product-model/#settlementpayout) can also model FX
spot and PvP settlement. Its documented
[serialization](https://cdm.finos.org/docs/serialization/) is JSON, so this XML
profile does not claim a standardized CDM serialization.

## Documentation and generation

[fx-spot-trade-documentation.xslt](fx-spot-trade-documentation.xslt) formats the
business state as HTML. The envelope references its exact bytes through a base64
data URI and a Keccak-256 integrity digest; no resource contract is needed.
Consumers verify the digest, extract the `FxSpotTrade` element from the rendered
envelope, and apply the stylesheet to that element. Use secure XSLT processing
with external access and extension functions disabled.

After editing the XML or stylesheet, run from the example directory:

```sh
python3 scripts/generate-xml-template.py
```

The generator requires Python 3 and Foundry's `cast`. It refreshes the stylesheet
reference and digest in the XML, then emits
[FxSpotTradeXml.sol](../contracts/FxSpotTradeXml.sol), which supplies the contract's
`stateXmlTemplate()` response.

New factory/trade deployments emit this envelope. Existing deployments retain
their original template bytes. Run `mvn -B -f test/xml/pom.xml test` after
`forge build` to validate real renderer output on an isolated chain (Java 21).
