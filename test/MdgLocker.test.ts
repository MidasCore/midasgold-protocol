import chai, {expect} from 'chai';
import {ethers} from 'hardhat';
import {solidity} from 'ethereum-waffle';
import {Contract, ContractFactory, BigNumber, utils} from 'ethers';
import {Provider} from '@ethersproject/providers';
import {SignerWithAddress} from 'hardhat-deploy-ethers/dist/src/signer-with-address';

import {
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

describe('MdgLocker.test', () => {
    const {provider} = ethers;

    let operator: SignerWithAddress;
    let bob: SignerWithAddress;
    let carol: SignerWithAddress;
    let david: SignerWithAddress;

    before('provider & accounts setting', async () => {
        [operator, bob, carol, david] = await ethers.getSigners();
    });

    // core
    let MdgLocker: ContractFactory;
    let MidasGoldToken: ContractFactory;

    before('fetch contract factories', async () => {
        MdgLocker = await ethers.getContractFactory('MdgLocker');
        MidasGoldToken = await ethers.getContractFactory('MidasGoldToken');
    });

    let locker: Contract;
    let mdg: Contract;

    let startBlock: BigNumber;

    before('deploy contracts', async () => {
        mdg = await MidasGoldToken.connect(operator).deploy(toWei('1000000'));

        startBlock = BigNumber.from(await latestBlocknumber(provider)).add(10);
        locker = await MdgLocker.connect(operator).deploy(mdg.address, startBlock, startBlock.add(10));

        await mdg.mint(bob.address, toWei('1000'));
        await mdg.connect(bob).approve(locker.address, maxUint256);
    });

    describe('#constructor', () => {
        it('should works correctly', async () => {
            expect(String(await locker.mdg())).to.eq(mdg.address);
            expect(String(await locker.startReleaseBlock())).to.eq('11');
            expect(String(await locker.endReleaseBlock())).to.eq('21');
            expect(String(await locker.totalLock())).to.eq(toWei('0'));
            expect(String(await locker.lockOf(bob.address))).to.eq(toWei('0'));
        });
    });

    describe('#lock', () => {
        it('bob lock 10 MDG for carol', async () => {
            await expect(async () => {
                await locker.connect(bob).lock(carol.address, toWei('10'));
            }).to.changeTokenBalances(mdg, [bob, locker], [toWei('-10'), toWei('10')]);
            expect(String(await locker.totalLock())).to.eq(toWei('10'));
            expect(String(await locker.lockOf(bob.address))).to.eq(toWei('0'));
            expect(String(await locker.lockOf(carol.address))).to.eq(toWei('10'));
            expect(String(await locker.canUnlockAmount(carol.address))).to.eq(toWei('0'));
        });

        it('carol unlock 5 MDG', async () => {
            await expect(locker.connect(carol).unlock()).to.revertedWith('still locked');
            await mineBlocks(ethers, 9);
            const currentBlk = await getLatestBlockNumber(ethers);
            const canUnlockAmount = (currentBlk <= 11) ? toWei(0) : (currentBlk >= 21) ? toWei(10) : toWei(currentBlk - 11);
            console.log('currentBlk = %s, canUnlockAmount = %s MDG', currentBlk, fromWei(canUnlockAmount));
            expect(String(await locker.canUnlockAmount(carol.address))).to.eq(canUnlockAmount);
            await expect(async () => {
                await locker.connect(carol).unlock();
            }).to.changeTokenBalances(mdg, [carol, locker], [toWei('5'), toWei('-5')]);
            expect(String(await locker.totalLock())).to.eq(toWei('5'));
            expect(String(await locker.lockOf(carol.address))).to.eq(toWei('10'));
            expect(String(await locker.canUnlockAmount(carol.address))).to.eq(toWei('0'));
        });

        it('carol unlock all', async () => {
            await mineBlocks(ethers, 10);
            expect(String(await locker.canUnlockAmount(carol.address))).to.eq(toWei('5'));
            await expect(async () => {
                await locker.connect(carol).unlock();
            }).to.changeTokenBalances(mdg, [carol, locker], [toWei('5'), toWei('-5')]);
            expect(String(await locker.totalLock())).to.eq(toWei('0'));
            expect(String(await locker.lockOf(carol.address))).to.eq(toWei('10'));
            expect(String(await locker.canUnlockAmount(carol.address))).to.eq(toWei('0'));
        });

        it('revert if carol want to unlock more', async () => {
            await mineBlocks(ethers, 10);
            await expect(locker.connect(carol).unlock()).to.revertedWith('no locked');
        });
    });
});
