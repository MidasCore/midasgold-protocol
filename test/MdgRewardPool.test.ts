import chai, {expect} from 'chai';
import {ethers} from 'hardhat';
import {solidity} from 'ethereum-waffle';
import {Contract, ContractFactory, BigNumber, utils} from 'ethers';
import {Provider} from '@ethersproject/providers';
import {SignerWithAddress} from 'hardhat-deploy-ethers/dist/src/signer-with-address';

import {
    ADDRESS_ZERO,
    advanceBlock,
    advanceTimeAndBlock, fromWei,
    getLatestBlockNumber,
    maxUint256,
    mineBlocks,
    toWei
} from './shared/utilities';

chai.use(solidity);

async function latestBlocktime(provider: Provider): Promise<number> {
    const {timestamp} = await provider.getBlock('latest');
    return timestamp;
}

async function latestBlocknumber(provider: Provider): Promise<number> {
    return await provider.getBlockNumber();
}

describe('MdgRewardPool.test', () => {
    const {provider} = ethers;

    let operator: SignerWithAddress;
    let reserveFund: SignerWithAddress;
    let bob: SignerWithAddress;
    let carol: SignerWithAddress;
    let david: SignerWithAddress;

    before('provider & accounts setting', async () => {
        [operator, reserveFund, bob, carol, david] = await ethers.getSigners();
    });

    // core
    let MdgRewardPool: ContractFactory;
    let MdgLocker: ContractFactory;
    let MidasGoldToken: ContractFactory;
    let MockERC20: ContractFactory;

    before('fetch contract factories', async () => {
        MdgRewardPool = await ethers.getContractFactory('MdgRewardPool');
        MdgLocker = await ethers.getContractFactory('MdgLocker');
        MidasGoldToken = await ethers.getContractFactory('MidasGoldToken');
        MockERC20 = await ethers.getContractFactory('MockERC20');
    });

    let pool: Contract;
    let locker: Contract;
    let mdg: Contract;
    let mdo: Contract;
    let bcash: Contract;
    let lpMain: Contract;
    let lpFee: Contract;

    let startBlock: BigNumber;
    let rewardPerBlock: BigNumber;

    before('deploy contracts', async () => {
        mdg = await MidasGoldToken.connect(operator).deploy(toWei('1000000'));
        mdo = await MockERC20.connect(operator).deploy('Midas Dollar', 'MDO', 18);
        bcash = await MockERC20.connect(operator).deploy('bCash', 'bCash', 18);
        lpMain = await MockERC20.connect(operator).deploy('lpMain', 'lpMain', 18);
        lpFee = await MockERC20.connect(operator).deploy('lpFee', 'lpFee', 18);

        startBlock = BigNumber.from(await latestBlocknumber(provider)).add(10);
        locker = await MdgLocker.connect(operator).deploy(mdg.address, startBlock.add(100), startBlock.add(200));

        pool = await MdgRewardPool.connect(operator).deploy();
        rewardPerBlock = toWei('0.2');
        await pool.connect(operator).initialize(mdg.address, mdo.address, bcash.address, rewardPerBlock, startBlock, startBlock.add(100), locker.address, reserveFund.address, operator.address);

        await pool.connect(operator).add(20000, lpMain.address, 0, startBlock.add(20));
        await pool.connect(operator).add(6000, lpFee.address, 400, 0);

        await mdg.connect(operator).addMinter(pool.address);
        await mdg.connect(operator).mint(bob.address, toWei('1000'));
        await mdg.connect(bob).approve(pool.address, maxUint256);

        await lpMain.mint(bob.address, toWei('1000'));
        await lpMain.connect(bob).approve(pool.address, maxUint256);

        await lpFee.mint(bob.address, toWei('1000'));
        await lpFee.connect(bob).approve(pool.address, maxUint256);

        await mdo.mint(pool.address, toWei('1000'));
        await bcash.mint(pool.address, toWei('1000'));
    });

    describe('#initialize', () => {
        it('should works correctly', async () => {
            expect(String(await pool.mdg())).to.eq(mdg.address);
            expect(String(await pool.startBlock())).to.eq(startBlock);
            expect(String(await pool.lockUntilBlock())).to.eq(startBlock.add(100));
            expect(String(await pool.rewardPerBlock())).to.eq(toWei('0.2'));
            expect(String(await pool.mdoPerBlock())).to.eq(toWei('0.01'));
            expect(String(await pool.bcashPerBlock())).to.eq(toWei('0.01'));
            expect(String(await pool.totalAllocPoint())).to.eq('6000'); // 20x pool has not started
        });
    });

    describe('#deposit', () => {
        it('bob deposit 10 lpMain (no fee)', async () => {
            await expect(async () => {
                await pool.connect(bob).deposit(0, toWei('10'));
            }).to.changeTokenBalances(lpMain, [bob, pool, reserveFund], [toWei('-10'), toWei('10'), toWei('0')]);
            const _userInfo = await pool.userInfo(0, bob.address);
            // console.log(_userInfo);
            expect(_userInfo.amount).to.eq(toWei('10'));
        });

        it('bob deposit 10 lpFee (4% fee)', async () => {
            await expect(async () => {
                await pool.connect(bob).deposit(1, toWei('10'));
            }).to.changeTokenBalances(lpFee, [bob, pool, reserveFund], [toWei('-10'), toWei('9.6'), toWei('0.4')]);
            const _userInfo = await pool.userInfo(1, bob.address);
            // console.log(_userInfo);
            expect(_userInfo.amount).to.eq(toWei('9.6'));
        });

        it('bob withdraw some lpMain', async () => {
            expect(String(await pool.pendingReward(0, bob.address))).to.eq(toWei('0'));
            expect(String(await pool.pendingMdo(0, bob.address))).to.eq(toWei('0'));
            expect(String(await pool.pendingBcash(0, bob.address))).to.eq(toWei('0'));
            await mineBlocks(ethers, 20);
            await pool.connect(bob).deposit(0, toWei('10'));
            expect(String(await pool.totalAllocPoint())).to.eq('26000'); // 20x pool has started
            // console.log('currentBlk = %s', await getLatestBlockNumber(ethers));
            await mineBlocks(ethers, 1);
            expect(String(await pool.pendingReward(0, bob.address))).to.eq(toWei('0.15384615384615384'));
            expect(String(await pool.pendingMdo(0, bob.address))).to.eq(toWei('0.00769230769230768'));
            expect(String(await pool.pendingBcash(0, bob.address))).to.eq(toWei('0.00769230769230768'));
            // console.log('burnPercent = %s', String (await pool.burnPercent()));
            // await pool.connect(bob).withdraw(1, toWei('0'));
            // await expect(pool.connect(bob).withdraw(1, toWei('0'))).to.emit(mdg, "Transfer").withArgs(pool.address, ADDRESS_ZERO, toWei('0.026538461538461535'));
            // console.log('debug_burnAmount = %s', String (await pool.debug_burnAmount()));
            let _beforeMdg = await mdg.balanceOf(bob.address);
            let _beforeReserve = await mdg.balanceOf(reserveFund.address);
            await expect(async () => {
                await pool.connect(bob).withdraw(0, toWei('0'));
            }).to.changeTokenBalances(mdo, [bob, pool], [toWei('0.01538461538461538'), toWei('-0.01538461538461538')]);
            let _afterMdg = await mdg.balanceOf(bob.address);
            let _afterReserve = await mdg.balanceOf(reserveFund.address);
            expect(_afterMdg.sub(_beforeMdg)).to.eq(toWei('0.076923076923076920'));
            expect(_afterReserve.sub(_beforeReserve)).to.eq(toWei('0.030769230769230768'));
            expect(String(await mdg.balanceOf(locker.address))).to.eq(toWei('1.038461538461538450'));
            expect(String(await locker.lockOf(bob.address))).to.eq(toWei('1.038461538461538450'));
        });

        it('bob withdraw all lpFee', async () => {
            await expect(pool.connect(bob).withdraw(1, toWei('9.61'))).to.revertedWith('withdraw: not good');
            let _beforeMdg = await mdg.balanceOf(bob.address);
            let _beforeReserve = await mdg.balanceOf(reserveFund.address);
            await expect(async () => {
                await pool.connect(bob).withdraw(1, toWei('9.6'));
            }).to.changeTokenBalances(mdo, [bob, pool], [toWei('0.057692307692307686'), toWei('-0.057692307692307686')]);
            let _afterMdg = await mdg.balanceOf(bob.address);
            let _afterReserve = await mdg.balanceOf(reserveFund.address);
            expect(_afterMdg.sub(_beforeMdg)).to.eq(toWei('0.288461538461538461'));
            expect(_afterReserve.sub(_beforeReserve)).to.eq(toWei('0.115384615384615384'));
        });

        it('bob unlock MDG from locker', async () => {
            const fullLockedAmount = toWei('1.903846153846153832');
            expect(String(await locker.lockOf(bob.address))).to.eq(fullLockedAmount);
            expect(String(await locker.released(bob.address))).to.eq(toWei('0'));
            expect(String(await locker.canUnlockAmount(bob.address))).to.eq(toWei('0'));
            // console.log('currentBlk = %s', await getLatestBlockNumber(ethers));
            await mineBlocks(ethers, 100);
            // console.log('currentBlk = %s', await getLatestBlockNumber(ethers));
            expect(String(await locker.canUnlockAmount(bob.address))).to.eq(toWei('0.590192307692307687'));
            await mineBlocks(ethers, 100);
            // console.log('currentBlk = %s', await getLatestBlockNumber(ethers));
            expect(String(await locker.canUnlockAmount(bob.address))).to.eq(fullLockedAmount);
            expect(String(await locker.released(bob.address))).to.eq(toWei('0'));
            await expect(async () => {
                await locker.connect(bob).unlock();
            }).to.changeTokenBalances(mdg, [bob, locker], [fullLockedAmount, toWei('-1.903846153846153832')]);
            expect(String(await locker.released(bob.address))).to.eq(fullLockedAmount);
        });
    });
});
