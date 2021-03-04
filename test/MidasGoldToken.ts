// @ts-ignore
import chai from "chai";
import {deployments, ethers} from 'hardhat';
import {expect} from './chai-setup';
import {solidity} from 'ethereum-waffle';
import {Contract, ContractFactory, BigNumber, utils} from "ethers";
import {SignerWithAddress} from 'hardhat-deploy-ethers/dist/src/signer-with-address';
import {toWei} from "./shared/utilities";

chai.use(solidity);

describe("MidasGoldToken", () => {
    const ETH = utils.parseEther("1");
    const ZERO = BigNumber.from(0);
    const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

    const {provider} = ethers;

    let operator: SignerWithAddress;
    let rewardPool: SignerWithAddress;

    before("setup accounts", async () => {
        [operator, rewardPool] = await ethers.getSigners();
    });

    let MidasGoldToken: ContractFactory;

    before("fetch contract factories", async () => {
        MidasGoldToken = await ethers.getContractFactory("MidasGoldToken");
    });

    describe("MidasGoldToken", () => {
        let token: Contract;

        before("deploy token", async () => {
            token = await MidasGoldToken.connect(operator).deploy(toWei('1000000'));
            await token.connect(operator).mint(operator.address, ETH);
        });

        it("mint", async () => {
            await expect(token.connect(operator).mint(operator.address, ETH)).to.emit(token, "Transfer").withArgs(ZERO_ADDR, operator.address, ETH);
            expect(await token.balanceOf(operator.address)).to.eq(ETH.mul(2));
        });

        it("burn", async () => {
            await expect(token.connect(operator).burn(ETH)).to.emit(token, "Transfer").withArgs(operator.address, ZERO_ADDR, ETH);
            expect(await token.balanceOf(operator.address)).to.eq(ETH);
        });

        it("burnFrom", async () => {
            await expect(token.connect(operator).approve(operator.address, ETH));
            await expect(token.connect(operator).burnFrom(operator.address, ETH)).to.emit(token, "Transfer").withArgs(operator.address, ZERO_ADDR, ETH);
            expect(await token.balanceOf(operator.address)).to.eq(ZERO);
        });
    });
});
