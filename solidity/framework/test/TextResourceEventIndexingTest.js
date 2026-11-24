import hre from "hardhat";
import { expect } from "chai";
import { AbiCoder, keccak256, toUtf8Bytes } from "ethers";

describe("TextResource event filtering", function () {
    it("filters a staged chunk by index while retaining its length in event data", async function () {
        const { ethers } = await hre.network.create();
        const [owner] = await ethers.getSigners();
        const content = toUtf8Bytes("firstsecond");
        const resource = await (await ethers.getContractFactory("TextResource")).deploy(
            owner.address, keccak256(toUtf8Bytes("example:text")), "text/plain", "0x", keccak256(content)
        );
        await resource.waitForDeployment();
        const first = await (await resource.appendChunk(toUtf8Bytes("first"))).wait();
        const second = await (await resource.appendChunk(toUtf8Bytes("second"))).wait();

        const logs = await resource.queryFilter(
            resource.filters.ChunkAppended(owner.address, null, 1), first.blockNumber, second.blockNumber
        );
        expect(logs).to.have.length(1);
        expect(logs[0].topics).to.have.length(4);
        expect(logs[0].args.sender).to.equal(owner.address);
        expect(logs[0].args.chunkIndex).to.equal(1n);
        expect(logs[0].args.chunkLength).to.equal(6n);
        expect(AbiCoder.defaultAbiCoder().decode(["uint256"], logs[0].data)[0]).to.equal(6n);
        expect(await resource.queryFilter(
            resource.filters.ChunkAppended(null, null, 2), first.blockNumber, second.blockNumber
        )).to.have.length(0);
        await resource.finalize(keccak256(content));
        expect(await resource.text()).to.equal("firstsecond");
    });
});
