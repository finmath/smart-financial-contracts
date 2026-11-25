import hre from "hardhat";
import { expect } from "chai";
import { keccak256, toUtf8Bytes, MaxUint256, ZeroAddress, ZeroHash } from "ethers";
import { confirmReviewedClientData } from "./helpers/clientRegistry.js";

describe("Product definitions and per-party trading", function () {
    let ethers, owner, alice, bob, carol, clients, registry, factory, terms;
    let desks, aliceDesk, bobDesk;
    const LEI = "00000000000000000098";
    const BIC = "DEMOXXXX";
    const ACTIVE = 1n, SUSPENDED = 2n, RETIRED = 3n;
    const REQUEST = { active: 1n, fulfilled: 2n, withdrawn: 3n, rejected: 4n, expired: 5n };
    const CLIENT = { active: 2n, suspended: 3n, revoked: 4n };

    async function onboard(client) {
        await clients.registerClient({ client: client.address, lei: LEI, bic: BIC });
        await confirmReviewedClientData(clients, client, LEI, BIC);
        await desks.connect(client).createTradingContract();
        return ethers.getContractAt("TradingContract", await desks.tradingContractOf(client.address), client);
    }

    async function resource(type, mediaType, text) {
        const content = toUtf8Bytes(text);
        const result = await (await ethers.getContractFactory("TextResource")).deploy(
            owner.address, type, mediaType, content, keccak256(content)
        );
        await result.waitForDeployment();
        return result;
    }

    beforeEach(async function () {
        ({ ethers } = await hre.network.create());
        [owner, alice, bob, carol] = await ethers.getSigners();
        clients = await (await ethers.getContractFactory("ClientRegistry")).deploy(owner.address);
        await clients.waitForDeployment();
        registry = await (await ethers.getContractFactory("ProductDefinitionRegistry"))
            .deploy(clients.target);
        await registry.waitForDeployment();
        desks = await ethers.getContractAt("TradingContractFactory", await registry.tradingContractFactory());
        const library = await (await ethers.getContractFactory("ProductLib")).deploy();
        await library.waitForDeployment();
        factory = await (await ethers.getContractFactory("RegistryWorkflowFactoryMock", {
            libraries: { ProductLib: library.target }
        })).deploy(registry.target);
        await factory.waitForDeployment();
        terms = await resource(await factory.productTermsTemplateResourceType(), "application/xml", "<Terms/>");
        aliceDesk = await onboard(alice);
        bobDesk = await onboard(bob);
    });

    function components() {
        return {
            productFactory: factory.target,
            productTermsTemplate: terms.target
        };
    }

    async function publish(name) {
        const definition = await registry.computeProductDefinitionId(name);
        await registry.publishProductDefinition({ name, productDefinition: components() });
        return definition;
    }

    async function eventArgs(transaction, contract, eventName) {
        const receipt = await transaction.wait();
        for (const log of receipt.logs) {
            if (log.address.toLowerCase() !== contract.target.toLowerCase()) continue;
            const event = contract.interface.parseLog(log);
            if (event?.name === eventName) return event.args;
        }
        throw new Error(`Missing ${eventName} on ${contract.target}`);
    }

    async function request(recipient, sender, definition, version = 1n, payload = "0x") {
        const tx = await recipient.connect(sender).createTradeRequest(definition, version, payload);
        return (await eventArgs(tx, recipient, "TradeRequested")).tradeRequestId;
    }

    async function activeDefinitionIds() {
        return (await registry.getProductDefinitionStates(0, 100))
            .filter(item => item.status === ACTIVE).map(item => item.productDefinitionId);
    }

    it("tracks active definitions through publication, suspension, reactivation and retirement", async function () {
        expect(await registry.productDefinitionCount()).to.equal(0n);
        expect(await registry.getProductDefinitionStates(0, 100)).to.deep.equal([]);
        const first = await publish("First demo");
        const second = await publish("Second demo");
        const firstPage = await registry.getProductDefinitionStates(0, 1);
        const secondPage = await registry.getProductDefinitionStates(1, 1);
        expect([...firstPage, ...secondPage].map(item => item.productDefinitionId))
            .to.deep.equal([first, second]);
        expect(await registry.getProductDefinitionStates(0, 0)).to.deep.equal([]);
        expect(await registry.getProductDefinitionStates(2, 100)).to.deep.equal([]);
        expect(await registry.getProductDefinitionStates(MaxUint256, MaxUint256)).to.deep.equal([]);
        expect((await registry.getProductDefinitionStates(1, MaxUint256))
            .map(item => item.productDefinitionId)).to.deep.equal([second]);
        expect(await registry.productDefinitionCount()).to.equal(2n);
        expect(await activeDefinitionIds()).to.have.members([first, second]);
        expect((await registry.getProductDefinition(first)).name).to.equal("First demo");
        expect((await registry.getProductDefinition(second)).name).to.equal("Second demo");

        await registry.setProductDefinitionStatus(first, SUSPENDED);
        expect(await activeDefinitionIds()).to.deep.equal([second]);
        await registry.setProductDefinitionStatus(first, ACTIVE);
        expect(await activeDefinitionIds()).to.have.members([first, second]);
        await registry.setProductDefinitionStatus(second, RETIRED);
        expect(await activeDefinitionIds()).to.deep.equal([first]);
        expect(await registry.getProductDefinitionStatus(second)).to.equal(RETIRED);
        expect((await registry.getProductDefinitionStates(0, 100)).map(item => item.status))
            .to.deep.equal([ACTIVE, RETIRED]);
    });

    it("creates one addressable trading contract per active client and follows shared ownership", async function () {
        expect(aliceDesk.target).not.to.equal(bobDesk.target);
        expect(await aliceDesk.client()).to.equal(alice.address);
        expect(await desks.clientOf(bobDesk.target)).to.equal(bob.address);
        expect(await desks.tradingContractOf(owner.address)).to.equal(ZeroAddress);
        await expect(desks.connect(alice).createTradingContract())
            .to.be.revertedWithCustomError(desks, "TradingContractAlreadyExists");
        await clients.registerClient({ client: carol.address, lei: LEI, bic: BIC });
        await expect(desks.connect(carol).createTradingContract())
            .to.be.revertedWithCustomError(desks, "ClientNotActive");

        const definition = await publish("Shared administration");
        await clients.transferOwnership(carol.address);
        expect(await registry.owner()).to.equal(owner.address);
        await clients.connect(carol).acceptOwnership();
        expect(await registry.owner()).to.equal(carol.address);
        await expect(registry.setProductDefinitionStatus(definition, SUSPENDED))
            .to.be.revertedWithCustomError(registry, "UnauthorizedRegistryOwner").withArgs(owner.address);
        await registry.connect(carol).setProductDefinitionStatus(definition, SUSPENDED);
        expect(await registry.getProductDefinitionStatus(definition)).to.equal(SUSPENDED);
    });

    it("addresses either party directly and lets the requester withdraw and the recipient reject", async function () {
        const definition = await publish("Bilateral requests");
        const toBob = await request(bobDesk, alice, definition, 1n, "0x1234");
        const forwarded = await bobDesk.sendTradeRequest(aliceDesk.target, definition, 1n, "0xab");
        const toAlice = (await eventArgs(forwarded, aliceDesk, "TradeRequested")).tradeRequestId;

        expect(await bobDesk.getActiveTradeRequests(definition)).to.deep.equal([toBob]);
        expect(await aliceDesk.getActiveTradeRequests(definition)).to.deep.equal([toAlice]);
        const received = await bobDesk.tradeRequestState(toBob);
        expect(received.requester).to.equal(alice.address);
        expect(received.productPayload).to.equal("0x1234");
        expect(received.productDefinitionVersion).to.equal(1n);
        expect(received.product).to.equal(ZeroAddress);
        expect((await aliceDesk.tradeRequestState(toAlice)).requester).to.equal(bob.address);
        await expect(aliceDesk.tradeRequestState(toBob))
            .to.be.revertedWithCustomError(aliceDesk, "UnknownTradeRequest");
        await expect(bobDesk.withdrawTradeRequest(toBob))
            .to.be.revertedWithCustomError(bobDesk, "NotRequester");
        await expect(bobDesk.connect(alice).rejectTradeRequest(toBob))
            .to.be.revertedWithCustomError(bobDesk, "NotClient");

        await bobDesk.connect(alice).withdrawTradeRequest(toBob);
        await aliceDesk.rejectTradeRequest(toAlice);
        expect((await bobDesk.tradeRequestState(toBob)).status).to.equal(REQUEST.withdrawn);
        expect((await aliceDesk.tradeRequestState(toAlice)).status).to.equal(REQUEST.rejected);
        expect(await bobDesk.getActiveTradeRequests(definition)).to.deep.equal([]);
        expect(await aliceDesk.getActiveTradeRequests(definition)).to.deep.equal([]);
    });

    it("attributes delegated actions to the client and immediately revokes an operator's authority", async function () {
        const definition = await publish("Application access");
        await expect(aliceDesk.connect(carol).sendTradeRequest(bobDesk.target, definition, 1n, "0x"))
            .to.be.revertedWithCustomError(aliceDesk, "NotClient");
        await aliceDesk.setOperator(carol.address, true);
        const tx = await aliceDesk.connect(carol).sendTradeRequest(bobDesk.target, definition, 1n, "0x");
        const id = (await eventArgs(tx, bobDesk, "TradeRequested")).tradeRequestId;
        expect((await bobDesk.tradeRequestState(id)).requester).to.equal(alice.address);
        await expect(aliceDesk.connect(carol).setOperator(owner.address, true))
            .to.be.revertedWithCustomError(aliceDesk, "NotClient").withArgs(carol.address);

        await aliceDesk.setOperator(carol.address, false);
        await expect(aliceDesk.connect(carol).withdrawSentTradeRequest(bobDesk.target, id))
            .to.be.revertedWithCustomError(aliceDesk, "NotClient");
        await aliceDesk.withdrawSentTradeRequest(bobDesk.target, id);
        expect((await bobDesk.tradeRequestState(id)).status).to.equal(REQUEST.withdrawn);

        await bobDesk.setOperator(carol.address, true);
        const issuance = await bobDesk.connect(carol).issueProduct(definition, 1n, "0x");
        const issued = await eventArgs(issuance, registry, "ProductIssued");
        const product = await ethers.getContractAt("ProductXmlNoteMock", issued.product);
        expect(await product.productProvider()).to.equal(bob.address);
    });

    it("expires requests when their definition is revised or retired and pins direct issuance to its version", async function () {
        const definition = await publish("Changing definition");
        const first = await request(bobDesk, alice, definition);
        await registry.updateProductDefinition(definition, components());
        expect((await bobDesk.tradeRequestState(first)).status).to.equal(REQUEST.expired);
        expect(await bobDesk.getActiveTradeRequests(definition)).to.deep.equal([]);
        await expect(bobDesk.issueProductForRequests([first], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "InvalidTradeRequestStatus").withArgs(first, REQUEST.expired);
        await expect(bobDesk.issueProduct(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(bobDesk, "WrongDefinitionVersion").withArgs(1n, 2n);
        await expect(bobDesk.connect(alice).createTradeRequest(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(bobDesk, "WrongDefinitionVersion").withArgs(1n, 2n);

        const second = await request(bobDesk, alice, definition, 2n);
        expect((await bobDesk.tradeRequestState(second)).productDefinitionVersion).to.equal(2n);
        await registry.setProductDefinitionStatus(definition, RETIRED);
        expect((await bobDesk.tradeRequestState(second)).status).to.equal(REQUEST.expired);
        expect(await bobDesk.getActiveTradeRequests(definition)).to.deep.equal([]);
        await expect(bobDesk.issueProductForRequests([second], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "InvalidTradeRequestStatus").withArgs(second, REQUEST.expired);
        await expect(bobDesk.tradeRequestState(ZeroHash))
            .to.be.revertedWithCustomError(bobDesk, "UnknownTradeRequest");
    });

    it("rechecks both clients at request and issuance time while preserving withdrawal", async function () {
        const definition = await publish("Current eligibility");
        const first = await request(bobDesk, alice, definition);
        await clients.setClientStatus(alice.address, CLIENT.suspended);
        await expect(bobDesk.connect(alice).createTradeRequest(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(bobDesk, "ClientNotEligible").withArgs(alice.address, definition);
        await expect(bobDesk.issueProductForRequests([first], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "ClientNotEligible").withArgs(alice.address, definition);
        expect((await bobDesk.tradeRequestState(first)).status).to.equal(REQUEST.active);
        await bobDesk.connect(alice).withdrawTradeRequest(first);
        await clients.setClientStatus(alice.address, CLIENT.active);

        const second = await request(bobDesk, alice, definition);
        await clients.setClientStatus(bob.address, CLIENT.revoked);
        await expect(bobDesk.connect(alice).createTradeRequest(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(bobDesk, "ClientNotEligible").withArgs(bob.address, definition);
        await expect(bobDesk.issueProductForRequests([second], "0x"))
            .to.be.revertedWithCustomError(registry, "ClientNotEligible").withArgs(bob.address, definition);
        await expect(bobDesk.issueProduct(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(registry, "ClientNotEligible").withArgs(bob.address, definition);
        expect((await bobDesk.tradeRequestState(second)).product).to.equal(ZeroAddress);
    });

    it("keeps outstanding requests fulfillable during definition suspension and rejects new business", async function () {
        const definition = await publish("Suspended offering");
        const first = await request(bobDesk, alice, definition);
        await registry.setProductDefinitionStatus(definition, SUSPENDED);
        await expect(bobDesk.connect(alice).createTradeRequest(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(registry, "ProductDefinitionNotActive").withArgs(definition, SUSPENDED);
        await expect(bobDesk.issueProduct(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(registry, "ProductDefinitionNotActive").withArgs(definition, SUSPENDED);
        await bobDesk.issueProductForRequests([first], "0x");
        expect((await bobDesk.tradeRequestState(first)).status).to.equal(REQUEST.fulfilled);
    });

    it("issues through the anchored factory for the responding party and consumes each request once", async function () {
        const definition = await publish("Issued offering");
        await onboard(carol);
        const first = await request(bobDesk, alice, definition, 1n, "0x1234");
        const second = await request(bobDesk, carol, definition, 1n, "0xab");
        expect(await registry.isRegisteredProduct(factory.target)).to.equal(false);
        await expect(registry.issueProduct(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(registry, "UnrecognizedTradingContract").withArgs(owner.address);
        await expect(registry.connect(bob).issueProduct(definition, 1n, "0x"))
            .to.be.revertedWithCustomError(registry, "UnrecognizedTradingContract").withArgs(bob.address);
        await expect(bobDesk.connect(alice).issueProductForRequests([first], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "NotClient").withArgs(alice.address);
        await expect(bobDesk.issueProductForRequests([first, first], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "InvalidTradeRequestStatus").withArgs(first, REQUEST.fulfilled);
        const otherDefinition = await publish("Independent offering");
        const otherRequest = await request(bobDesk, alice, otherDefinition);
        await expect(bobDesk.issueProductForRequests([first, otherRequest], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "MismatchedRequest").withArgs(otherRequest);
        expect((await bobDesk.tradeRequestState(first)).status).to.equal(REQUEST.active);
        expect((await bobDesk.tradeRequestState(otherRequest)).status).to.equal(REQUEST.active);

        const issuance = await bobDesk.issueProductForRequests([first, second], "0x5678");
        const issued = await eventArgs(issuance, registry, "ProductIssued");
        const product = await ethers.getContractAt("ProductXmlNoteMock", issued.product);
        expect(await registry.isRegisteredProduct(product.target)).to.equal(true);
        expect(await factory.isFactoryDeployedProduct(product.target)).to.equal(true);
        expect(await product.productRegistry()).to.equal(registry.target);
        expect(await product.productFactory()).to.equal(factory.target);
        expect(await product.productProvider()).to.equal(bob.address);
        expect(await product.productDefinitionId()).to.equal(definition);
        expect(await product.productDefinitionVersion()).to.equal(1n);
        expect(await product.productTermsTemplate()).to.equal(terms.target);
        const issuedXml = await product.stateXmlTemplate();
        expect(issuedXml).to.contain(await terms.web3Url());
        expect(issuedXml).not.to.contain("<LegalDocumentation");
        expect(await bobDesk.getActiveTradeRequests(definition)).to.deep.equal([]);
        for (const id of [first, second]) {
            const record = await bobDesk.tradeRequestState(id);
            expect(record.status).to.equal(REQUEST.fulfilled);
            expect(record.product).to.equal(product.target);
        }
        await expect(bobDesk.issueProductForRequests([first], "0x"))
            .to.be.revertedWithCustomError(bobDesk, "InvalidTradeRequestStatus").withArgs(first, REQUEST.fulfilled);
        const direct = await eventArgs(await aliceDesk.issueProduct(definition, 1n, "0x"), registry, "ProductIssued");
        expect(direct.product).not.to.equal(product.target);
        expect(await registry.isRegisteredProduct(direct.product)).to.equal(true);
        const directProduct = await ethers.getContractAt("ProductXmlNoteMock", direct.product);
        expect(await directProduct.productProvider()).to.equal(alice.address);
        expect(await directProduct.productDefinitionVersion()).to.equal(1n);
        expect((await registry.productDefinitionState(definition)).version).to.equal(1n);
    });

    it("caps definition discovery without truncating the final page", async function () {
        const pageSize = Number(await registry.MAX_DISCOVERY_PAGE_SIZE());
        const ids = [];
        for (let i = 0; i <= pageSize; i++) ids.push(await publish(`Paged definition ${i}`));
        expect((await registry.getProductDefinitionStates(0, MaxUint256))
            .map(item => item.productDefinitionId)).to.deep.equal(ids.slice(0, pageSize));
        expect((await registry.getProductDefinitionStates(pageSize, MaxUint256))
            .map(item => item.productDefinitionId)).to.deep.equal(ids.slice(pageSize));
    });
});
