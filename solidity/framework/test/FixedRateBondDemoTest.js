import { expect } from "chai";
import { AbiCoder, keccak256, toUtf8Bytes, ZeroHash } from "ethers";
import {
    advanceTo, DEMO_DATES, deployFixedRateBondDemo, encodeBondPayload, outcomeKeys
} from "./helpers/fixedRateBondDemo.js";

const GENERATED_TRANSFER = "inceptTransfer(uint256,int256,address,address,bytes,address)";
const TRADE = { inactive: 0n, incepted: 1n, confirmed: 2n, cancelled: 3n };
const POSITION = { undelivered: 0n, outstanding: 1n, offered: 2n, authorized: 3n, repaid: 4n };

describe("FixedRateBond with local demo integrations", function () {
    let f;
    beforeEach(async function () { f = await deployFixedRateBondDemo(); });

    async function startAssetAttempt(token, label, redeeming = false, complete = true) {
        const { bond, payment, issuer, buyer } = f;
        const seller = redeeming ? buyer : issuer;
        const payer = redeeming ? issuer : buyer;
        const id = await bond.currentTransferId();
        const keys = outcomeKeys(label);
        const transaction = toUtf8Bytes(label);
        await token.connect(seller).approve(bond.target, 3n);
        await bond.connect(payer)[GENERATED_TRANSFER](id, 3n, seller.address, payer.address,
            transaction, payment.target);
        await payment.connect(seller).inceptTransfer(id,
            redeeming ? await bond.finalRedemptionAmount() : await bond.settlementAmount(),
            payer.address, seller.address, transaction, bond.target);
        if (complete) await payment.completeInception(id, keys.successHash, keys.failureHash);
        return { id, keys, payer };
    }

    async function paySuccessfulAttempt(attempt) {
        await f.payment.connect(attempt.payer).approvePayment(attempt.id);
        await f.payment.settle(attempt.id, true, attempt.keys.success);
    }

    async function issueAndSettle() {
        await f.agree();
        const { token } = f;
        await paySuccessfulAttempt(await startAssetAttempt(token, "issuance"));
        return token;
    }

    async function authorizeRedemption(terms = "maturity") {
        const { bond, issuer, buyer } = f;
        const id = await bond.tradeId();
        const amount = await bond.finalRedemptionAmount();
        await bond.connect(issuer).requestTradeTermination(id, issuer.address, -amount, terms);
        await bond.connect(buyer).confirmTradeTermination(id, issuer.address, -amount, terms);
        return { id, amount, terms };
    }

    async function startCoupon(index) {
        const { bond, buyer, payment, operator } = f;
        const keys = outcomeKeys(`coupon-${index}`);
        await bond.connect(buyer).payCoupon(index, toUtf8Bytes(`coupon-${index}`), operator.address);
        const id = BigInt(await bond.couponPaymentRequestId(index));
        await payment.completeInception(id, keys.successHash, keys.failureHash);
        return { id, keys, payer: f.issuer };
    }

    it("runs a registered bond from agreed resources through delivery, coupons and redemption", async function () {
        const { ethers, issuer, buyer, bond, registry, factory, termsResource, documentation,
            payment, cash, token, terms } = f;
        expect(await registry.productOf(f.requestId)).to.equal(bond.target);
        expect(await registry.isRegisteredProduct(bond.target)).to.equal(true);
        expect(await factory.isFactoryDeployedProduct(bond.target)).to.equal(true);
        expect(await bond.productRegistry()).to.equal(registry.target);
        expect(await bond.productFactory()).to.equal(factory.target);
        expect(await bond.productDefinitionId()).to.equal(f.definitionId);
        expect(await bond.issuer()).to.equal(issuer.address);
        expect(await bond.buyer()).to.equal(buyer.address);
        expect(await termsResource.isFinalized()).to.equal(true);
        expect(await documentation.isFinalized()).to.equal(true);
        expect(await bond.stateXmlTemplate()).to.include(await termsResource.web3Url())
            .and.to.include(await documentation.web3Url());
        expect(await bond.documentStatus()).to.equal("PENDING");
        expect(await bond.termsHash()).to.equal(keccak256(AbiCoder.defaultAbiCoder().encode(
            ["bytes32", "address", "address"], [await bond.economicTermsHash(), token.target, payment.target]
        )));
        expect(await bond.assetToken()).to.equal(token.target);
        expect(await factory.assetToken()).to.equal(token.target);
        expect(await token.totalSupply()).to.equal(3n);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);

        // Three denominations; the first ACT/ACT ICMA period is 91/182 of a regular half year.
        // Regular coupon = 10001 * 4.1296% / 2 = 206.500648 -> 206 minor units per token.
        // Short coupon = 103.250324 -> 103, rounded before multiplying by the three tokens.
        expect(await bond.assetTokenAmount()).to.equal(3n);
        expect(await bond.couponPeriodCount()).to.equal(2n);
        expect(await bond.couponAmount(0)).to.equal(309n);
        expect(await bond.couponAmount(1)).to.equal(618n);
        const schedule = await bond.couponSchedule();
        expect(schedule.map(coupon => coupon.amount)).to.deep.equal([103n, 206n]);
        expect(schedule.map(coupon => coupon.paymentDate)).to.deep.equal([DEMO_DATES.firstCoupon, DEMO_DATES.maturity]);
        expect(await bond.settlementAmount()).to.equal(29_552n);
        expect(await bond.finalRedemptionAmount()).to.equal(30_003n);
        expect(await bond.interestPaymentFrequency()).to.equal("SEMIANNUALLY");

        await advanceTo(ethers, DEMO_DATES.settlement);
        const hash = await bond.termsHash();
        await bond.connect(issuer).inceptTrade(issuer.address, buyer.address, hash, -terms.initialAggregateAmount, await bond.settlementAmount(), "");
        expect(await bond.tradeStatus()).to.equal(TRADE.incepted);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        await bond.connect(buyer).confirmTrade(issuer.address, buyer.address, hash, -terms.initialAggregateAmount, await bond.settlementAmount(), "");
        expect(await bond.agreedTermsHash()).to.equal(hash);
        expect(await bond.tradeStatus()).to.equal(TRADE.confirmed);
        expect(await token.totalSupply()).to.equal(3n);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await bond.documentStatus()).to.equal("PENDING");
        const issuance = await startAssetAttempt(token, "issuance");
        expect(await token.balanceOf(bond.target)).to.equal(3n);
        await paySuccessfulAttempt(issuance);
        expect(await bond.tradeStatus()).to.equal(TRADE.confirmed);
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        expect(await bond.documentStatus()).to.equal("ISSUED");
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
        expect(await cash.balanceOf(issuer.address)).to.equal(129_552n);
        expect(await cash.balanceOf(buyer.address)).to.equal(70_448n);
        await expect(bond.connect(issuer).requestTradeTermination(await bond.tradeId(), issuer.address, -30_003n, "maturity"))
            .to.be.revertedWithCustomError(bond, "NotMatured");

        await advanceTo(ethers, DEMO_DATES.firstCoupon);
        await paySuccessfulAttempt(await startCoupon(0));
        expect(await bond.couponPaymentStatus(0)).to.equal(2n);
        await advanceTo(ethers, DEMO_DATES.maturity);
        await paySuccessfulAttempt(await startCoupon(1));
        expect(await bond.couponPaymentStatus(1)).to.equal(2n);

        await authorizeRedemption();
        const redemption = await startAssetAttempt(token, "redemption", true);
        expect(redemption.id).to.not.equal(issuance.id);
        await paySuccessfulAttempt(redemption);
        expect(await bond.positionState()).to.equal(POSITION.repaid);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await token.balanceOf(buyer.address)).to.equal(0n);
        expect(await token.totalSupply()).to.equal(3n);
        expect(await token.balanceOf(bond.target)).to.equal(0n);
        expect(await cash.balanceOf(issuer.address)).to.equal(98_622n);
        expect(await cash.balanceOf(buyer.address)).to.equal(101_378n);
        expect(await cash.balanceOf(payment.target)).to.equal(0n);
        await expect(bond.connect(issuer).requestTradeTermination(await bond.tradeId(), issuer.address, -30_003n, "maturity"))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
    });

    it("requires the right parties and every inception field before enabling settlement", async function () {
        const { issuer, buyer, outsider, bond, token } = f;
        const args = await f.tradeArguments("initial market data");
        await expect(bond.connect(outsider).inceptTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller")
            .withArgs(outsider.address, issuer.address);
        const wrongHash = [...args]; wrongHash[2] = ZeroHash;
        await expect(bond.connect(issuer).inceptTrade(...wrongHash))
            .to.be.revertedWithCustomError(bond, "TermsMismatch");
        const invalidAmount = [...args]; invalidAmount[4] = 0;
        await expect(bond.connect(issuer).inceptTrade(...invalidAmount))
            .to.be.revertedWithCustomError(bond, "InvalidAmount");
        await bond.connect(issuer).inceptTrade(...args);
        await expect(bond.connect(issuer).inceptTrade(...args))
            .to.be.revertedWithCustomError(bond, "InvalidTradeStatus");
        await expect(bond.connect(outsider).confirmTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller")
            .withArgs(outsider.address, buyer.address);

        const changes = [
            [0, outsider.address, "InvalidCounterparty"],
            [1, outsider.address, "InvalidCounterparty"],
            [2, ZeroHash, "TermsMismatch"],
            [3, -args[3], "InvalidAmount"],
            [4, -args[4], "InvalidAmount"],
            [5, "changed initial data", "TermsMismatch"]
        ];
        for (const [index, value, error] of changes) {
            const changed = [...args]; changed[index] = value;
            await expect(bond.connect(buyer).confirmTrade(...changed))
                .to.be.revertedWithCustomError(bond, error);
            await expect(bond.connect(issuer).cancelTrade(...changed))
                .to.be.revertedWithCustomError(bond, error);
        }
        await expect(bond.connect(buyer)[GENERATED_TRANSFER](await bond.currentTransferId(), 3n,
            issuer.address, buyer.address, "0x01", f.payment.target))
            .to.be.revertedWithCustomError(bond, "InvalidTradeStatus");
        expect(await bond.tradeStatus()).to.equal(TRADE.incepted);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        await bond.connect(buyer).confirmTrade(...args);
        expect(await bond.tradeStatus()).to.equal(TRADE.confirmed);
        expect(await token.totalSupply()).to.equal(3n);
        expect(await bond.assetToken()).to.equal(token.target);
        await expect(bond.connect(buyer).confirmTrade(...args))
            .to.be.revertedWithCustomError(bond, "InvalidTradeStatus");
    });

    it("allows only the issuer or its current operator to cancel the exact unconfirmed agreement", async function () {
        const { issuer, buyer, outsider, bond, token, cash } = f;
        const args = await f.tradeArguments();
        await bond.connect(issuer).inceptTrade(...args);
        for (const caller of [outsider, buyer]) {
            await expect(bond.connect(caller).cancelTrade(...args))
                .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        }
        await bond.connect(issuer).setTradeOperator(outsider.address, true);
        await bond.connect(issuer).setTradeOperator(outsider.address, false);
        await expect(bond.connect(outsider).cancelTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await bond.connect(issuer).setTradeOperator(outsider.address, true);
        await expect(bond.connect(outsider).cancelTrade(...args))
            .to.emit(bond, "TradeCanceled").withArgs(issuer.address, await bond.tradeId());
        expect(await bond.tradeStatus()).to.equal(TRADE.cancelled);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await token.balanceOf(buyer.address)).to.equal(0n);
        expect(await cash.balanceOf(issuer.address)).to.equal(100_000n);
        expect(await cash.balanceOf(buyer.address)).to.equal(100_000n);
        for (const [caller, method] of [[issuer, "inceptTrade"], [buyer, "confirmTrade"], [outsider, "cancelTrade"]]) {
            await expect(bond.connect(caller)[method](...args))
                .to.be.revertedWithCustomError(bond, "InvalidTradeStatus");
        }
    });

    it("settles delegated agreement and redemption between the stored parties", async function () {
        const { ethers, issuer, buyer, operator, outsider, bond, token, cash, payment } = f;
        const args = await f.tradeArguments("delegated agreement");
        const id = await bond.tradeId();
        // Payment-adapter authority and standing allowances confer no trade authority.
        await expect(bond.connect(operator).inceptTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await bond.connect(issuer).setTradeOperator(operator.address, true);
        await expect(bond.connect(operator).inceptTrade(...args))
            .to.emit(bond, "TradeIncepted").withArgs(issuer.address, buyer.address, id,
                args[2], args[3], args[4], args[5]);
        await expect(bond.connect(operator).confirmTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        // An operator cannot grant authority on behalf of its represented party.
        await bond.connect(operator).setTradeOperator(outsider.address, true);
        await expect(bond.connect(outsider).confirmTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await bond.connect(buyer).setTradeOperator(outsider.address, true);
        await bond.connect(buyer).setTradeOperator(outsider.address, false);
        await expect(bond.connect(outsider).confirmTrade(...args))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await bond.connect(buyer).setTradeOperator(outsider.address, true);
        await expect(bond.connect(outsider).confirmTrade(...args))
            .to.emit(bond, "TradeConfirmed").withArgs(buyer.address, id);
        await paySuccessfulAttempt(await startAssetAttempt(token, "delegated issuance"));
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
        expect(await cash.balanceOf(issuer.address)).to.equal(129_552n);
        expect(await cash.balanceOf(buyer.address)).to.equal(70_448n);
        expect(await token.balanceOf(operator.address)).to.equal(0n);
        expect(await token.balanceOf(outsider.address)).to.equal(0n);

        await advanceTo(ethers, DEMO_DATES.maturity);
        const amount = -(await bond.finalRedemptionAmount());
        const terms = "delegated redemption";
        await expect(bond.connect(outsider).requestTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await expect(bond.connect(operator).requestTradeTermination(id, buyer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidCounterparty");
        await expect(bond.connect(operator).requestTradeTermination(id, issuer.address, amount, terms))
            .to.emit(bond, "TradeTerminationRequest").withArgs(issuer.address, id, amount, terms);
        await expect(bond.connect(operator).confirmTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await expect(bond.connect(outsider).confirmTradeTermination(id, buyer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidCounterparty");
        await expect(bond.connect(outsider).confirmTradeTermination(id, issuer.address, amount, terms))
            .to.emit(bond, "TradeTerminationConfirmed").withArgs(buyer.address, id, amount, terms);
        await paySuccessfulAttempt(await startAssetAttempt(token, "delegated redemption", true));
        expect(await bond.positionState()).to.equal(POSITION.repaid);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await token.balanceOf(buyer.address)).to.equal(0n);
        expect(await cash.balanceOf(issuer.address)).to.equal(99_549n);
        expect(await cash.balanceOf(buyer.address)).to.equal(100_451n);
        expect(await cash.balanceOf(payment.target)).to.equal(0n);
        await expect(bond.connect(outsider).confirmTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
    });

    it("checks current requester delegation and complete context when withdrawing redemption", async function () {
        const { ethers, issuer, buyer, operator, outsider, bond } = f;
        await issueAndSettle();
        await advanceTo(ethers, DEMO_DATES.maturity);
        const id = await bond.tradeId();
        const amount = -(await bond.finalRedemptionAmount());
        const terms = "cancel delegated redemption";
        await bond.connect(issuer).setTradeOperator(operator.address, true);
        await bond.connect(buyer).setTradeOperator(outsider.address, true);
        await bond.connect(operator).requestTradeTermination(id, issuer.address, amount, terms);
        await expect(bond.connect(outsider).cancelTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        for (const [changedId, requester, value, data, error] of [
            ["another trade", issuer.address, amount, terms, "InvalidTradeData"],
            [id, buyer.address, amount, terms, "InvalidCounterparty"],
            [id, issuer.address, -amount, terms, "InvalidAmount"],
            [id, issuer.address, amount, "changed terms", "RedemptionProposalMismatch"]
        ]) {
            await expect(bond.connect(operator).cancelTradeTermination(changedId, requester, value, data))
                .to.be.revertedWithCustomError(bond, error);
        }
        await bond.connect(issuer).setTradeOperator(operator.address, false);
        await expect(bond.connect(operator).cancelTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await bond.connect(issuer).setTradeOperator(operator.address, true);
        await expect(bond.connect(operator).cancelTradeTermination(id, issuer.address, amount, terms))
            .to.emit(bond, "TradeTerminationCanceled").withArgs(issuer.address, id, terms);
        expect(await bond.redemptionProposal()).to.equal(ZeroHash);
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        await expect(bond.connect(outsider).confirmTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
        await expect(bond.connect(operator).cancelTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
    });

    it("recovers from missing token allowances or balances without partially settling either leg", async function () {
        const { issuer, buyer, outsider, bond, token, cash, payment } = f;
        await f.agree();
        const id = await bond.currentTransferId();
        const amount = await bond.settlementAmount();
        const transaction = toUtf8Bytes("existing token delivery");
        const keys = outcomeKeys("existing token delivery");
        await bond.connect(buyer)[GENERATED_TRANSFER](id, 3n, issuer.address, buyer.address,
            transaction, payment.target);
        await payment.connect(issuer).inceptTransfer(id, amount, buyer.address, issuer.address,
            transaction, bond.target);
        const complete = () => payment.completeInception(id, keys.successHash, keys.failureHash);

        await expect(complete()).to.be.revertedWith("ERC20: insufficient allowance");
        expect(await bond.lockState()).to.equal(1n);
        expect(await payment.paymentStatus(id)).to.equal(1n);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await token.balanceOf(bond.target)).to.equal(0n);

        await token.connect(issuer).approve(bond.target, 3n);
        await token.connect(issuer).transfer(outsider.address, 3n);
        await expect(complete()).to.be.revertedWith("ERC20: transfer amount exceeds balance");
        expect(await token.allowance(issuer.address, bond.target)).to.equal(3n);
        expect(await payment.paymentStatus(id)).to.equal(1n);
        await token.connect(outsider).transfer(issuer.address, 3n);
        await complete();
        expect(await token.balanceOf(bond.target)).to.equal(3n);

        await payment.connect(buyer).approvePayment(id);
        await cash.connect(buyer).approve(payment.target, 0n);
        await expect(payment.settle(id, true, keys.success)).to.be.revertedWith("ERC20: insufficient allowance");
        expect(await bond.lockState()).to.equal(2n);
        expect(await payment.paymentStatus(id)).to.equal(2n);
        expect(await token.balanceOf(buyer.address)).to.equal(0n);
        expect(await cash.balanceOf(issuer.address)).to.equal(100_000n);
        expect(await cash.balanceOf(buyer.address)).to.equal(100_000n);
        await cash.connect(buyer).approve(payment.target, amount);
        await payment.settle(id, true, keys.success);
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
        expect(await cash.balanceOf(issuer.address)).to.equal(129_552n);
    });

    it("rejects payment on a cancelled lock, reclaims a failed lock and retries with distinct identifiers", async function () {
        const { issuer, buyer, outsider, bond, payment, cash } = f;
        await f.agree();
        const { token } = f;
        const cancelled = await startAssetAttempt(token, "cancelled", false, false);
        await payment.connect(buyer).approvePayment(cancelled.id);
        await expect(bond.connect(outsider)["cancelTransfer(uint256)"](cancelled.id))
            .to.be.revertedWithCustomError(bond, "DemoLockError");
        await bond.connect(issuer)["cancelTransfer(uint256)"](cancelled.id);
        await payment.completeInception(cancelled.id, cancelled.keys.successHash, cancelled.keys.failureHash);
        await expect(payment.settle(cancelled.id, true, cancelled.keys.success))
            .to.be.revertedWithCustomError(bond, "DemoLockError");
        expect(await payment.paymentStatus(cancelled.id)).to.equal(2n);
        expect(await cash.balanceOf(buyer.address)).to.equal(100_000n);
        await payment.settle(cancelled.id, false, cancelled.keys.failure);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);

        const failed = await startAssetAttempt(token, "failed");
        expect(failed.id).to.not.equal(cancelled.id);
        expect(await token.balanceOf(bond.target)).to.equal(3n);
        await payment.settle(failed.id, false, failed.keys.failure);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await bond.tradeStatus()).to.equal(TRADE.confirmed);
        expect(await cash.balanceOf(issuer.address)).to.equal(100_000n);

        const retried = await startAssetAttempt(token, "retried");
        expect(retried.id).to.not.equal(failed.id);
        await expect(payment.settle(retried.id, true, retried.keys.success))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(payment.connect(outsider).approvePayment(retried.id))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(payment.connect(outsider).settle(retried.id, false, retried.keys.failure))
            .to.be.revertedWith("Ownable: caller is not the owner");
        await expect(bond.connect(outsider).transferWithKey(retried.id, retried.keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await expect(bond.connect(buyer).transferWithKey(retried.id, retried.keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await paySuccessfulAttempt(retried);
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
        await expect(payment.settle(retried.id, true, retried.keys.success))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(bond.transferWithKey(retried.id, retried.keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
    });

    it("requires both parties to match a maturity proposal before enabling the return exchange", async function () {
        const { ethers, issuer, buyer, outsider, bond, token, payment } = f;
        const id = await bond.tradeId();
        const amount = await bond.finalRedemptionAmount();
        const terms = "repay at contractual maturity";
        await expect(bond.connect(issuer).requestTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
        await issueAndSettle();
        await expect(bond.connect(issuer).requestTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "NotMatured");
        await advanceTo(ethers, DEMO_DATES.maturity);
        await expect(bond.connect(buyer).requestTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await expect(bond.connect(buyer).confirmTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
        await expect(bond.connect(issuer).requestTradeTermination("another trade", issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidTradeData");
        await expect(bond.connect(issuer).requestTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidAmount");
        await expect(bond.connect(issuer).requestTradeTermination(id, issuer.address, -amount, terms))
            .to.emit(bond, "TradeTerminationRequest").withArgs(issuer.address, id, -amount, terms);
        expect(await bond.positionState()).to.equal(POSITION.offered);
        const proposal = await bond.redemptionProposal();
        await expect(bond.connect(issuer)[GENERATED_TRANSFER](await bond.currentTransferId(), 3n,
            buyer.address, issuer.address, "0x01", payment.target))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
        await expect(bond.connect(issuer).confirmTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await expect(bond.connect(buyer).confirmTradeTermination("another trade", issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidTradeData");
        await expect(bond.connect(buyer).confirmTradeTermination(id, issuer.address, amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidAmount");
        await expect(bond.connect(buyer).confirmTradeTermination(id, issuer.address, -amount, "changed terms"))
            .to.be.revertedWithCustomError(bond, "RedemptionProposalMismatch");
        await expect(bond.connect(outsider).cancelTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await expect(bond.connect(buyer).cancelTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "UnauthorizedTradeCaller");
        await expect(bond.connect(issuer).cancelTradeTermination(id, issuer.address, -amount, "changed terms"))
            .to.be.revertedWithCustomError(bond, "RedemptionProposalMismatch");
        expect(await bond.redemptionProposal()).to.equal(proposal);
        await bond.connect(issuer).cancelTradeTermination(id, issuer.address, -amount, terms);
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        await bond.connect(issuer).requestTradeTermination(id, issuer.address, -amount, terms);
        await expect(bond.connect(buyer).confirmTradeTermination(id, issuer.address, -amount, terms))
            .to.emit(bond, "TradeTerminationConfirmed").withArgs(buyer.address, id, -amount, terms);
        expect(await bond.dvpPaymentContext()).to.deep.equal([issuer.address, buyer.address, amount]);
        await expect(bond.connect(buyer).confirmTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "InvalidPositionState");
        const attempt = await startAssetAttempt(token, "accepted repayment", true, false);
        await expect(bond.connect(issuer).cancelTradeTermination(id, issuer.address, -amount, terms))
            .to.be.revertedWithCustomError(bond, "SettlementActive");
        await bond.connect(buyer)["cancelTransfer(uint256)"](attempt.id);
        await bond.connect(issuer).cancelTradeTermination(id, issuer.address, -amount, terms);
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
    });

    it("keeps a failed redemption redeemable and returns units only against successful repayment", async function () {
        const { ethers, issuer, buyer, bond, payment, cash } = f;
        const token = await issueAndSettle();
        await advanceTo(ethers, DEMO_DATES.maturity);
        const { id: tradeId, amount } = await authorizeRedemption();
        await bond.connect(issuer).cancelTradeTermination(tradeId, issuer.address, -amount, "maturity");
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        expect(await bond.redemptionProposal()).to.equal(ZeroHash);
        await authorizeRedemption();
        const failed = await startAssetAttempt(token, "redemption failure", true);
        await expect(bond.connect(issuer).cancelTradeTermination(tradeId, issuer.address, -amount, "maturity"))
            .to.be.revertedWithCustomError(bond, "SettlementActive");
        await payment.settle(failed.id, false, failed.keys.failure);
        expect(await bond.positionState()).to.equal(POSITION.authorized);
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
        expect(await cash.balanceOf(issuer.address)).to.equal(129_552n);
        expect(await token.balanceOf(issuer.address)).to.equal(0n);

        const retry = await startAssetAttempt(token, "redemption retry", true);
        expect(retry.id).to.not.equal(failed.id);
        await paySuccessfulAttempt(retry);
        expect(await bond.positionState()).to.equal(POSITION.repaid);
        expect(await token.balanceOf(issuer.address)).to.equal(3n);
        expect(await cash.balanceOf(buyer.address)).to.equal(100_451n);
        expect(await token.balanceOf(buyer.address)).to.equal(0n);
        expect(await token.totalSupply()).to.equal(3n);
    });

    for (const couponAlreadyPending of [false, true]) {
        it(`pays the final coupon after principal repayment (${couponAlreadyPending ? "pending" : "new"} claim)`, async function () {
            const { ethers, issuer, buyer, bond, token, payment, cash } = f;
            await issueAndSettle();
            await advanceTo(ethers, DEMO_DATES.maturity);
            let coupon = couponAlreadyPending ? await startCoupon(1) : undefined;
            const { id, amount, terms } = await authorizeRedemption();
            await paySuccessfulAttempt(await startAssetAttempt(token, "repay before coupon", true));
            expect(await bond.positionState()).to.equal(POSITION.repaid);
            expect(await bond.tradeStatus()).to.equal(TRADE.confirmed);
            expect(await bond.documentStatus()).to.equal("ISSUED");

            const issuerCash = await cash.balanceOf(issuer.address);
            const buyerCash = await cash.balanceOf(buyer.address);
            const issuerUnits = await token.balanceOf(issuer.address);
            await expect(bond.connect(issuer).requestTradeTermination(id, issuer.address, -amount, terms))
                .to.be.revertedWithCustomError(bond, "InvalidPositionState");
            await expect(bond.connect(buyer).confirmTradeTermination(id, issuer.address, -amount, terms))
                .to.be.revertedWithCustomError(bond, "InvalidPositionState");
            await expect(bond.connect(issuer).cancelTradeTermination(id, issuer.address, -amount, terms))
                .to.be.revertedWithCustomError(bond, "InvalidPositionState");
            await expect(bond.connect(issuer)[GENERATED_TRANSFER](await bond.currentTransferId(), 3n,
                buyer.address, issuer.address, "0x01", payment.target))
                .to.be.revertedWithCustomError(bond, "InvalidPositionState");
            expect(await token.balanceOf(issuer.address)).to.equal(issuerUnits);
            expect(await cash.balanceOf(issuer.address)).to.equal(issuerCash);
            expect(await cash.balanceOf(buyer.address)).to.equal(buyerCash);

            coupon ??= await startCoupon(1);
            await paySuccessfulAttempt(coupon);
            expect(await bond.couponPaymentStatus(1)).to.equal(2n);
            expect(await cash.balanceOf(issuer.address)).to.equal(issuerCash - 618n);
            expect(await cash.balanceOf(buyer.address)).to.equal(buyerCash + 618n);
            expect(await bond.positionState()).to.equal(POSITION.repaid);
            expect(await token.balanceOf(issuer.address)).to.equal(issuerUnits);
        });
    }

    it("prevents payment identifier preemption and binds each asset payment to its exact inception", async function () {
        const { issuer, buyer, outsider, bond, payment } = f;
        await f.agree();
        const { token } = f;
        const id = await bond.currentTransferId();
        const couponId = BigInt(await bond.couponPaymentRequestId(0));
        const transaction = toUtf8Bytes("bound issuance payment");
        const amount = await bond.settlementAmount();
        const incept = (caller, paymentId, value, from, to, data) => payment.connect(caller).inceptTransfer(
            paymentId, value, from.address, to.address, data, bond.target);

        // A participant cannot reserve a future asset or coupon id before the bond opens it.
        await expect(incept(outsider, id, amount, outsider, issuer, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(incept(buyer, couponId, 309n, buyer, issuer, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await token.connect(issuer).approve(bond.target, 3n);
        await bond.connect(buyer)[GENERATED_TRANSFER](id, 3n, issuer.address, buyer.address,
            transaction, payment.target);

        await expect(incept(outsider, id, amount, outsider, issuer, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(incept(buyer, id, amount, buyer, outsider, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(incept(buyer, id, amount + 1n, buyer, issuer, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(incept(buyer, id, amount, buyer, issuer, toUtf8Bytes("substituted transaction")))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(incept(outsider, id, amount, buyer, issuer, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(incept(buyer, couponId, amount, buyer, issuer, transaction))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        expect(await payment.paymentStatus(id)).to.equal(0n);
        expect(await payment.paymentStatus(couponId)).to.equal(0n);

        await incept(issuer, id, amount, buyer, issuer, transaction);
        const keys = outcomeKeys("bound issuance payment");
        await payment.completeInception(id, keys.successHash, keys.failureHash);
        await paySuccessfulAttempt({ id, keys, payer: buyer });
        expect(await bond.positionState()).to.equal(POSITION.outstanding);
        expect(await token.balanceOf(buyer.address)).to.equal(3n);
    });

    it("authenticates coupon callbacks and keys, and exposes the retained one-attempt coupon limitation", async function () {
        const { ethers, issuer, buyer, outsider, operator, bond, payment, cash } = f;
        await issueAndSettle();
        await expect(bond.connect(buyer).payCoupon(0, "0x01", operator.address))
            .to.be.revertedWithCustomError(bond, "CouponNotDue");
        await advanceTo(ethers, DEMO_DATES.firstCoupon);
        await expect(bond.connect(outsider).payCoupon(0, "0x01", operator.address))
            .to.be.revertedWithCustomError(bond, "NotBuyer");
        await expect(bond.connect(buyer).payCoupon(0, "0x01", outsider.address))
            .to.be.revertedWithCustomError(bond, "UnexpectedPaymentOracle");
        await bond.connect(buyer).payCoupon(0, "0x01", operator.address);
        const id = BigInt(await bond.couponPaymentRequestId(0));
        const keys = outcomeKeys("failed coupon");
        expect(await bond.couponPaymentStatus(0)).to.equal(1n);
        await expect(bond.connect(outsider).onInceptionCompleted(id))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await expect(bond.transferWithKey(id, keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await payment.completeInception(id, keys.successHash, keys.failureHash);
        await expect(payment.completeInception(id, keys.successHash, keys.failureHash))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(bond.connect(outsider).transferWithKey(id, keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await expect(bond.connect(buyer).transferWithKey(id, keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await expect(payment.settle(id, true, keys.failure))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        const before = await cash.balanceOf(issuer.address);
        await payment.settle(id, false, keys.failure);
        expect(await bond.couponPaymentStatus(0)).to.equal(3n);
        expect(await cash.balanceOf(issuer.address)).to.equal(before);
        await expect(bond.transferWithKey(id, keys.success))
            .to.be.revertedWithCustomError(bond, "NotDemoPaymentContract");
        await expect(payment.settle(id, false, keys.failure))
            .to.be.revertedWithCustomError(payment, "DemoPaymentError");
        await expect(bond.connect(buyer).payCoupon(0, "0x01", operator.address))
            .to.be.revertedWithCustomError(bond, "CouponAlreadyRequested");
        await advanceTo(ethers, DEMO_DATES.maturity + 86_400n);
        await expect(bond.connect(buyer).payCoupon(1, "0x02", operator.address))
            .to.be.revertedWithCustomError(bond, "CouponPaymentWindowClosed");
    });

    it("rejects invalid denominations and calendar schedules through the real factory", async function () {
        const { registry, issuer, bond, terms, couponPeriods, definitionId } = f;
        const issue = (changes, periods = couponPeriods) => registry.connect(issuer).issueProductWithoutRequests({
            productDefinitionId: definitionId,
            productPayload: encodeBondPayload({ ...terms, ...changes }, periods)
        });
        await expect(issue({ specifiedDenomination: 10_000n })).to.be.revertedWithCustomError(bond, "InvalidAmount");
        await expect(issue({ couponsPerYear: 3 })).to.be.revertedWithCustomError(bond, "InvalidCouponFrequency");
        const broken = couponPeriods.map(period => ({ ...period }));
        broken[1].startDate += 86_400n;
        await expect(issue({}, broken)).to.be.revertedWithCustomError(bond, "InvalidCouponPeriod");
        expect(await registry.isRegisteredProduct(bond.target)).to.equal(true);
    });
});
