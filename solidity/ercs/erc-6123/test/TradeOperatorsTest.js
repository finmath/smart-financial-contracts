const { ethers } = require("hardhat");
const { expect } = require("chai");

describe("ERC-6123 explicit parties and trade operators", () => {
  const initialBalance = 10000;
  const terms = "trade terms";
  const market = "initial market";

  async function fixture() {
    const [owner, a, b, operatorA, operatorB, outsider] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("ERC20Settlement")).deploy();
    const sdc = await (await ethers.getContractFactory("SDCSingleTradePledgedBalance"))
      .deploy(a.address, b.address, token.address, 0, 0);
    await token.mint(a.address, initialBalance);
    await token.mint(b.address, initialBalance);
    return { owner, a, b, operatorA, operatorB, outsider, token, sdc };
  }

  async function approveOperators(ctx) {
    await ctx.sdc.connect(ctx.a).setTradeOperator(ctx.operatorA.address, true);
    await ctx.sdc.connect(ctx.b).setTradeOperator(ctx.operatorB.address, true);
  }

  async function settle(ctx, position = 1) {
    const args = [ctx.a.address, ctx.b.address, terms, position, 0, market];
    await ctx.sdc.connect(ctx.a).inceptTrade(...args);
    await ctx.sdc.connect(ctx.b).confirmTrade(...args);
    return ctx.sdc.getTradeID();
  }

  it("settles delegated trades for either inceptor, both positions and both payment directions", async () => {
    for (const reverseParties of [false, true]) {
      for (const position of [1, -1]) {
        for (const payment of [100, -100]) {
          const ctx = await fixture();
          const { a, b, operatorA, operatorB, token, sdc } = ctx;
          await approveOperators(ctx);
          const [inceptor, counterparty, initiatingOperator, confirmingOperator] = reverseParties
            ? [b, a, operatorB, operatorA] : [a, b, operatorA, operatorB];
          const args = [inceptor.address, counterparty.address, terms, position, payment, market];
          const inception = await sdc.connect(initiatingOperator).inceptTrade(...args);
          const tradeId = await sdc.getTradeID();
          await expect(inception).to.emit(sdc, "TradeIncepted")
            .withArgs(inceptor.address, counterparty.address, tradeId, terms, position, payment, market);
          await expect(sdc.connect(confirmingOperator).confirmTrade(...args))
            .to.emit(sdc, "TradeConfirmed").withArgs(counterparty.address, tradeId);
          expect(await token.balanceOf(inceptor.address)).to.equal(initialBalance + payment);
          expect(await token.balanceOf(counterparty.address)).to.equal(initialBalance - payment);
          expect(await token.balanceOf(initiatingOperator.address)).to.equal(0);
          expect(await token.balanceOf(confirmingOperator.address)).to.equal(0);
          expect(await sdc.getReceivingParty()).to.equal(position === 1 ? inceptor.address : counterparty.address);
          await expect(sdc.connect(confirmingOperator).confirmTrade(...args)).to.be.reverted;
          await expect(sdc.connect(initiatingOperator).cancelTrade(...args)).to.be.reverted;
        }
      }
    }
  });

  it("requires separate authorization from each party and honors revocation", async () => {
    const { a, b, operatorA, operatorB, outsider, sdc, token } = await fixture();
    const args = [a.address, b.address, terms, 1, 100, market];
    // Self-granted approvals by an outsider do not confer authority over a party.
    await sdc.connect(outsider).setTradeOperator(operatorA.address, true);
    await expect(sdc.connect(operatorA).inceptTrade(...args)).to.be.reverted;
    await expect(sdc.connect(b).inceptTrade(...args)).to.be.reverted;
    await expect(sdc.connect(a).setTradeOperator(ethers.constants.AddressZero, true)).to.be.reverted;
    await expect(sdc.connect(a).setTradeOperator(operatorA.address, true))
      .to.emit(sdc, "TradeOperatorApproval").withArgs(a.address, operatorA.address, true);
    await sdc.connect(operatorA).inceptTrade(...args);
    await expect(sdc.connect(operatorA).confirmTrade(...args)).to.be.reverted;
    await expect(sdc.connect(operatorB).confirmTrade(...args)).to.be.reverted;
    await expect(sdc.connect(a).confirmTrade(...args)).to.be.reverted;
    await sdc.connect(b).setTradeOperator(operatorB.address, true);
    await sdc.connect(b).setTradeOperator(operatorB.address, false);
    expect(await sdc.isTradeOperator(b.address, operatorB.address)).to.equal(false);
    await expect(sdc.connect(operatorB).confirmTrade(...args)).to.be.reverted;
    expect(await token.balanceOf(a.address)).to.equal(initialBalance);
    await sdc.connect(b).confirmTrade(...args);
    expect(await token.balanceOf(a.address)).to.equal(initialBalance + 100);
  });

  it("matches every inception field without reversing party order or signs", async () => {
    const ctx = await fixture();
    const { a, b, operatorA, operatorB, outsider, sdc, token } = ctx;
    await approveOperators(ctx);
    const args = [a.address, b.address, terms, 1, 100, market];
    await sdc.connect(operatorA).inceptTrade(...args);
    const invalid = [
      [outsider.address, b.address, terms, 1, 100, market],
      [a.address, outsider.address, terms, 1, 100, market],
      [b.address, a.address, terms, 1, 100, market],
      [a.address, b.address, "changed terms", 1, 100, market],
      [a.address, b.address, terms, -1, 100, market],
      [a.address, b.address, terms, 1, -100, market],
      [a.address, b.address, terms, 1, 100, "changed market"],
      [ethers.constants.AddressZero, b.address, terms, 1, 100, market],
    ];
    for (const mismatch of invalid) {
      await expect(sdc.connect(operatorB).confirmTrade(...mismatch)).to.be.reverted;
      await expect(sdc.connect(operatorA).cancelTrade(...mismatch)).to.be.reverted;
    }
    expect(await sdc.getTradeState()).to.equal(1);
    expect(await token.balanceOf(a.address)).to.equal(initialBalance);
    await sdc.connect(operatorB).confirmTrade(...args);
    expect(await sdc.getTradeState()).to.equal(5);
  });

  it("allows only the inceptor's current authority to withdraw the exact quote", async () => {
    const ctx = await fixture();
    const { a, b, operatorA, operatorB, sdc, token } = ctx;
    await approveOperators(ctx);
    const args = [a.address, b.address, terms, 1, 100, market];
    await sdc.connect(operatorA).inceptTrade(...args);
    const tradeId = await sdc.getTradeID();
    await expect(sdc.connect(operatorB).cancelTrade(...args)).to.be.reverted;
    await sdc.connect(a).setTradeOperator(operatorA.address, false);
    await expect(sdc.connect(operatorA).cancelTrade(...args)).to.be.reverted;
    await sdc.connect(a).setTradeOperator(operatorA.address, true);
    await expect(sdc.connect(operatorA).cancelTrade(...args))
      .to.emit(sdc, "TradeCanceled").withArgs(a.address, tradeId);
    await expect(sdc.connect(operatorB).confirmTrade(...args)).to.be.reverted;
    await expect(sdc.connect(operatorA).cancelTrade(...args)).to.be.reverted;
    expect(await token.balanceOf(a.address)).to.equal(initialBalance);
    expect(await token.balanceOf(b.address)).to.equal(initialBalance);
  });

  it("settles delegated termination from either requester and either payment perspective", async () => {
    for (const requesterIsA of [false, true]) {
      for (const position of [1, -1]) {
        for (const payment of [125, -125]) {
          const ctx = await fixture();
          const { a, b, operatorA, operatorB, sdc, token } = ctx;
          await approveOperators(ctx);
          const tradeId = await settle(ctx, position);
          const [requester, confirmer, requestingOperator, confirmingOperator] = requesterIsA
            ? [a, b, operatorA, operatorB] : [b, a, operatorB, operatorA];
          const args = [tradeId, requester.address, payment, "termination terms"];
          await expect(sdc.connect(requestingOperator).requestTradeTermination(...args))
            .to.emit(sdc, "TradeTerminationRequest").withArgs(requester.address, tradeId, payment, "termination terms");
          await expect(sdc.connect(confirmingOperator).confirmTradeTermination(...args))
            .to.emit(sdc, "TradeTerminationConfirmed").withArgs(confirmer.address, tradeId, payment, "termination terms");
          expect(await token.balanceOf(requester.address)).to.equal(initialBalance + payment);
          expect(await token.balanceOf(confirmer.address)).to.equal(initialBalance - payment);
          expect(await token.balanceOf(requestingOperator.address)).to.equal(0);
          expect(await token.balanceOf(confirmingOperator.address)).to.equal(0);
          expect(await sdc.getTradeState()).to.equal(7);
          await expect(sdc.connect(confirmingOperator).confirmTradeTermination(...args)).to.be.reverted;
          await expect(sdc.connect(requestingOperator).cancelTradeTermination(...args)).to.be.reverted;
        }
      }
    }
  });

  it("requires the correct party's authority for every termination action", async () => {
    const ctx = await fixture();
    const { a, b, operatorA, operatorB, outsider, sdc } = ctx;
    const tradeId = await settle(ctx);
    const args = [tradeId, a.address, 100, "termination terms"];
    await expect(sdc.connect(outsider).requestTradeTermination(...args)).to.be.reverted;
    await approveOperators(ctx);
    await expect(sdc.connect(operatorB).requestTradeTermination(...args)).to.be.reverted;
    await sdc.connect(operatorA).requestTradeTermination(...args);
    await expect(sdc.connect(operatorA).confirmTradeTermination(...args)).to.be.reverted;
    await expect(sdc.connect(operatorB).cancelTradeTermination(...args)).to.be.reverted;
    await sdc.connect(b).setTradeOperator(operatorB.address, false);
    await expect(sdc.connect(operatorB).confirmTradeTermination(...args)).to.be.reverted;
    await sdc.connect(a).setTradeOperator(operatorA.address, false);
    await expect(sdc.connect(operatorA).cancelTradeTermination(...args)).to.be.reverted;
    await expect(sdc.connect(a).cancelTradeTermination(...args))
      .to.emit(sdc, "TradeTerminationCanceled").withArgs(a.address, tradeId, "termination terms");
    await expect(sdc.connect(b).confirmTradeTermination(...args)).to.be.reverted;
  });

  it("matches every termination argument and binds otherwise identical proposals to the requester", async () => {
    const ctx = await fixture();
    const { a, b, operatorA, operatorB, sdc, token } = ctx;
    await approveOperators(ctx);
    const tradeId = await settle(ctx);
    const args = [tradeId, a.address, 100, "termination terms"];
    await sdc.connect(operatorA).requestTradeTermination(...args);
    for (const mismatch of [
      ["different trade", a.address, 100, "termination terms"],
      [tradeId, b.address, 100, "termination terms"],
      [tradeId, a.address, -100, "termination terms"],
      [tradeId, a.address, 100, "different terms"],
      [tradeId, ethers.constants.AddressZero, 100, "termination terms"],
    ]) {
      await expect(sdc.connect(operatorB).confirmTradeTermination(...mismatch)).to.be.reverted;
      await expect(sdc.connect(operatorA).cancelTradeTermination(...mismatch)).to.be.reverted;
    }
    // B cannot turn A's proposal into a request from B, even though A's operator
    // is the appropriate confirmer for that falsely represented request.
    const requestB = [tradeId, b.address, 100, "termination terms"];
    await expect(sdc.connect(operatorA).confirmTradeTermination(...requestB)).to.be.reverted;
    await sdc.connect(operatorB).requestTradeTermination(...requestB);
    await sdc.connect(operatorA).cancelTradeTermination(...args);
    await expect(sdc.connect(operatorB).confirmTradeTermination(...args)).to.be.reverted;
    await sdc.connect(operatorA).confirmTradeTermination(...requestB);
    expect(await token.balanceOf(b.address)).to.equal(initialBalance + 100);
    expect(await token.balanceOf(a.address)).to.equal(initialBalance - 100);
  });

  it("does not grant settlement or callback authority to trade operators", async () => {
    const ctx = await fixture();
    const { operatorA, sdc } = ctx;
    await approveOperators(ctx);
    await settle(ctx);
    await expect(sdc.connect(operatorA).initiateSettlement()).to.be.revertedWith("You are not a counterparty.");
    await expect(sdc.connect(operatorA).afterTransfer(true, 0, "forged callback"))
      .to.be.revertedWith("Only settlement token may call afterTransfer");
    expect(await sdc.getTradeState()).to.equal(5);
  });

  it("retains the inception identity and rejects calls to the former public identity setter", async () => {
    const { a, b, outsider, sdc } = await fixture();
    const args = [a.address, b.address, terms, 1, 0, market];
    await sdc.connect(a).inceptTrade(...args);
    const tradeId = await sdc.getTradeID();
    const setter = new ethers.utils.Interface(["function setTradeId(string)"]);
    await expect(outsider.sendTransaction({
      to: sdc.address,
      data: setter.encodeFunctionData("setTradeId", ["replacement"]),
    })).to.be.reverted;
    expect(await sdc.getTradeID()).to.equal(tradeId);
    await sdc.connect(b).confirmTrade(...args);
    expect(await sdc.getTradeID()).to.equal(tradeId);
  });

  it("rejects invalid participants and unrepresentable signed payment magnitudes", async () => {
    const ctx = await fixture();
    const { a, b, outsider, sdc } = ctx;
    const min = ethers.BigNumber.from(2).pow(255).mul(-1);
    for (const pair of [[a.address, a.address], [a.address, outsider.address], [ethers.constants.AddressZero, b.address]]) {
      await expect(sdc.connect(a).inceptTrade(...pair, terms, 1, 0, market)).to.be.reverted;
    }
    await expect(sdc.connect(a).inceptTrade(a.address, b.address, terms, -1, min, market))
      .to.be.revertedWith("Payment amount cannot be int256 minimum");
    expect(await sdc.getTradeState()).to.equal(0);
    const tradeId = await settle(ctx);
    await expect(sdc.connect(a).requestTradeTermination(tradeId, a.address, min, "termination terms"))
      .to.be.revertedWith("Payment amount cannot be int256 minimum");
    expect(await sdc.getTradeState()).to.equal(5);
  });
});
