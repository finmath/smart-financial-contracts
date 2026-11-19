import hre from "hardhat";
import { AbiCoder, keccak256, sha256, toUtf8Bytes } from "ethers";
import { confirmReviewedClientData } from "./clientRegistry.js";

export const utc = date => BigInt(Date.parse(`${date}T00:00:00Z`) / 1000);
export const DEMO_DATES = {
    clock: utc("2040-01-01"), pricing: utc("2040-03-28"), issue: utc("2040-04-01"),
    settlement: utc("2040-04-02"), firstCoupon: utc("2040-07-01"), maturity: utc("2041-01-01")
};
const TERMS_TYPE = "tuple(address buyer,uint256 initialAggregateAmount,uint256 specifiedDenomination,uint64 maturityDate,uint256 issuePrice,uint256 finalRedemptionPercentage,uint256 interestRate,uint8 couponsPerYear,uint64 pricingDate,uint64 issueDate,uint64 settlementDate)";
const PERIOD_TYPE = "tuple(uint64 startDate,uint64 endDate,uint64 paymentDate,uint64 referenceStartDate)";

export function encodeBondPayload(terms, couponPeriods) {
    return AbiCoder.defaultAbiCoder().encode(
        [`tuple(${TERMS_TYPE} terms,${PERIOD_TYPE}[] couponPeriods)`], [{ terms, couponPeriods }]
    );
}

export async function advanceTo(ethers, timestamp) {
    await ethers.provider.send("evm_setNextBlockTimestamp", [Number(timestamp)]);
    await ethers.provider.send("evm_mine", []);
}

export function outcomeKeys(label) {
    const success = toUtf8Bytes(`${label}:success`);
    const failure = toUtf8Bytes(`${label}:failure`);
    return { success, failure, successHash: sha256(success), failureHash: sha256(failure) };
}

export async function eventArgs(transaction, contract, name) {
    const receipt = await transaction.wait();
    for (const log of receipt.logs) {
        if (log.address.toLowerCase() !== contract.target.toLowerCase()) continue;
        const event = contract.interface.parseLog(log);
        if (event?.name === name) return event.args;
    }
    throw new Error(`Missing ${name} event`);
}

/** A local demonstration using existing fixed-supply tokens and operator-driven payment outcomes. */
export async function deployFixedRateBondDemo() {
    const { ethers } = await hre.network.create();
    const [operator, issuer, buyer, outsider] = await ethers.getSigners();
    await advanceTo(ethers, DEMO_DATES.clock);
    async function deploy(name, args = [], options = {}) {
        const instance = await (await ethers.getContractFactory(name, options)).deploy(...args);
        await instance.waitForDeployment();
        return instance;
    }

    const clients = await deploy("ClientRegistry", [operator.address]);
    const registry = await deploy("ProductDefinitionRegistry", [clients.target]);
    const tradingFactory = await ethers.getContractAt("TradingContractFactory", await registry.tradingContractFactory());
    const cash = await deploy("DemoToken", ["Demo cash (minor units)", "DCASH", operator.address, 200_000n]);
    const token = await deploy("DemoToken", ["Demo fixed-rate bond units", "DBOND", issuer.address, 3n]);
    const payment = await deploy("DemoPayment", [operator.address, cash.target]);
    const indications = await deploy("CurveIndications", [issuer.address]);
    const productLib = await deploy("ProductLib");
    const bondLib = await deploy("FixedRateBondLib");
    const factory = await deploy("FixedRateBondFactory",
        [registry.target, indications.target, payment.target, token.target],
        { libraries: { ProductLib: productLib.target, FixedRateBondLib: bondLib.target } });

    const termsText = '<FixedRateBond demo="true"/>';
    async function resource(type, mediaType, text) {
        const content = toUtf8Bytes(text);
        return deploy("TextResource", [issuer.address, type, mediaType, content, keccak256(content)]);
    }
    const termsResource = await resource(await factory.productTermsTemplateResourceType(), "application/xml", termsText);
    for (const client of [issuer, buyer]) {
        await clients.registerClient({ client: client.address, lei: "00000000000000000098", bic: "DEMOXXXX" });
        await confirmReviewedClientData(clients, client, "00000000000000000098", "DEMOXXXX");
        await tradingFactory.connect(client).createTradingContract();
    }
    const issuerDesk = await ethers.getContractAt("TradingContract", await tradingFactory.tradingContractOf(issuer.address), issuer);
    const buyerDesk = await ethers.getContractAt("TradingContract", await tradingFactory.tradingContractOf(buyer.address), buyer);

    const name = "Fixed-rate bond local demonstration";
    const definitionId = await registry.computeProductDefinitionId(name);
    await registry.connect(operator).publishProductDefinition({ name, productDefinition: {
        productFactory: factory.target, productTermsTemplate: termsResource.target
    } });
    const terms = {
        buyer: buyer.address, initialAggregateAmount: 30_003n, specifiedDenomination: 10_001n,
        maturityDate: DEMO_DATES.maturity, issuePrice: 985_000n,
        finalRedemptionPercentage: 1_000_000n, interestRate: 41_296n, couponsPerYear: 2,
        pricingDate: DEMO_DATES.pricing, issueDate: DEMO_DATES.issue, settlementDate: DEMO_DATES.settlement
    };
    const couponPeriods = [
        { startDate: DEMO_DATES.issue, endDate: DEMO_DATES.firstCoupon,
            paymentDate: DEMO_DATES.firstCoupon, referenceStartDate: DEMO_DATES.clock },
        { startDate: DEMO_DATES.firstCoupon, endDate: DEMO_DATES.maturity,
            paymentDate: DEMO_DATES.maturity, referenceStartDate: DEMO_DATES.firstCoupon }
    ];
    const requestedTerms = { ...terms, issuePrice: 980_000n };
    const requestedPayload = encodeBondPayload(requestedTerms, couponPeriods);
    const payload = encodeBondPayload(terms, couponPeriods);
    const definitionVersion = (await registry.getProductDefinition(definitionId)).version;
    const requested = await eventArgs(await buyerDesk.sendTradeRequest(
        issuerDesk.target, definitionId, definitionVersion, requestedPayload), issuerDesk, "TradeRequested");
    const issued = await eventArgs(await issuerDesk.issueProductForRequests(
        [requested.tradeRequestId], payload), registry, "ProductIssued");
    const bond = await ethers.getContractAt("FixedRateBond", issued.product);

    const issuanceConditions = await resource(keccak256(toUtf8Bytes("demo:issuance-conditions")), "text/plain",
        "Coupons and principal are payable in the cash asset specified by this bond.");
    const manifestText = JSON.stringify({ documents: [{
        role: "issuance-conditions", mediaType: "text/plain", uri: await issuanceConditions.web3Url(),
        contentHash: await issuanceConditions.contentHash()
    }] });
    const manifest = await resource(keccak256(toUtf8Bytes("demo:legal-manifest")), "application/json", manifestText);
    const abi = AbiCoder.defaultAbiCoder();
    const payloadHash = keccak256(abi.encode(["address", "address", TERMS_TYPE, PERIOD_TYPE + "[]"],
        [bond.target, issuer.address, terms, couponPeriods]));
    const economicTermsHash = keccak256(abi.encode(["bytes32", "bytes32"],
        [payloadHash, keccak256(toUtf8Bytes(termsText))]));
    function agreementHash(manifestHash) {
        return keccak256(abi.encode(["bytes32", "bytes32", "address", "address"],
            [economicTermsHash, manifestHash, token.target, payment.target]));
    }
    const offeredTermsHash = agreementHash(keccak256(toUtf8Bytes(manifestText)));
    await payment.setProductAuthorized(bond.target, true);
    await cash.transfer(issuer.address, 100_000n);
    await cash.transfer(buyer.address, 100_000n);
    await cash.connect(issuer).approve(payment.target, 100_000n);
    await cash.connect(buyer).approve(payment.target, 100_000n);

    async function agree() {
        await bond.connect(issuer).inceptTrade(manifest.target);
        await bond.connect(buyer).confirmTrade(issuer.address, offeredTermsHash, terms.initialAggregateAmount, 0, "");
    }
    return { ethers, operator, issuer, buyer, outsider, clients, registry, cash, token, payment,
        factory, bondLib, bond, issuerDesk, terms, couponPeriods, definitionId, definitionVersion, requestId: requested.tradeRequestId,
        termsResource, issuanceConditions, manifest, agreementHash, offeredTermsHash, agree, payload, requestedTerms };
}
