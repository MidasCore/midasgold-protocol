// SPDX-License-Identifier: MIT

/*
.___  ___.  __   _______       ___           _______.     _______   ______    __       _______
|   \/   | |  | |       \     /   \         /       |    /  _____| /  __  \  |  |     |       \
|  \  /  | |  | |  .--.  |   /  ^  \       |   (----`   |  |  __  |  |  |  | |  |     |  .--.  |
|  |\/|  | |  | |  |  |  |  /  /_\  \       \   \       |  | |_ | |  |  |  | |  |     |  |  |  |
|  |  |  | |  | |  '--'  | /  _____  \  .----)   |      |  |__| | |  `--'  | |  `----.|  '--'  |
|__|  |__| |__| |_______/ /__/     \__\ |_______/        \______|  \______/  |_______||_______/
 */

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/ILiquidityMigrator.sol";
import "./interfaces/ILayeredMdgToken.sol";

contract LayerRewardPool {// all 'mdg' in this contract represents MDG2, MDG3, etc.
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

//    uint256 public constant BLOCKS_PER_DAY = 28800; // 86400 / 3;
    uint256 public constant BLOCKS_PER_WEEK = 201600; // 28800 * 7;

    address public operator = address(0xD025628eEe504330f1282C96B28a731E3995ff66); // governance
    bool public initialized = false;
    address public reserveFund = address(0x39d91fb1Cb86c836da6300C0e700717d5dFe289F);
    uint256 public reservePercent = 0; // 1% ~ 100
    uint256 public lockPercent = 5000; // 50%
    uint256 public rewardHalvingRate = 7500; // 75%
    address public mdg; // address of Mdg[N]Token
    uint256 public mdgPoolId;
    uint256 public layerId; // from 2
    uint256 public totalAllocPoint = 0;// Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public rewardPerBlock; // 0.1 * 1e18
    uint256 public startBlock;    // The block number when Mdg[N] mining starts.
    uint256 public endBlock; // default = startBlock + 8 weeks
    uint256 public bigHalvingBlock; // The block to reduce 50% of rewardPerBlock. Default = startBlock + 2 weeks
    uint256 public lockUntilBlock; // default = startBlock + 4 weeks
    uint256 public nextHalvingBlock;
    uint256 public halvingPeriod; // default = 1 week;

    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lockDebt;
        uint256 reward2Debt;
    }

    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        address reward2; // additional reward
        uint256 allocPoint; // How many allocation points assigned to this pool. Mdg[N]s to distribute per block.
        uint256 lastRewardBlock; // Last block number that Mdg[N]s distribution occurs.
        uint256 accMdgPerShare; // Accumulated Mdg[N] per share, times 1e18. See below.
        uint256 accLockPerShare;
        uint256 accReward2PerShare;
        uint256 reward2PerBlock; // 0.1 * 1e18
        uint256 reward2EndBlock;
        uint16 depositFeeBP; // Deposit fee in basis points
        bool isStarted; // if lastRewardBlock has passed
    }

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.

    // The liquidity migrator contract. It has a lot of power. Can only be set through governance (owner).
    ILiquidityMigrator public migrator;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    bool public halvingChecked = true;

    /* ========== EVENTS ========== */
    event Initialized(address indexed executor, uint256 at);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, address indexed token, uint256 amount);

    // Locker {
    uint256 public startReleaseBlock;
    uint256 public endReleaseBlock;

    uint256 public totalLock;
    mapping(address => uint256) public mdgLocked;
    mapping(address => uint256) public mdgReleased;

    event Lock(address indexed to, uint256 value);
    // }

    function initialize(
        uint256 _layerId,
        address _mdg, // Mdg[N]Token contract
        uint256 _rewardPerBlock,//0.06 * 1e18
        uint256 _startBlock,
        address _reserveFund,
        address _operator
    ) public {
        require(!initialized || (startBlock > block.number && poolInfo.length == 0 && operator == msg.sender), "initialized");
        require(block.number < _startBlock, "late");
        require(_layerId >= 2, "from 2");
//        require(_endReleaseBlock > _startReleaseBlock, "endReleaseBlock < startReleaseBlock");

        layerId = _layerId;
        mdg = _mdg;
        rewardPerBlock = _rewardPerBlock; // start at 0.1 Mdg[N] per block for the first week
        startBlock = _startBlock;
        endBlock = _startBlock + BLOCKS_PER_WEEK * 8;
        bigHalvingBlock = _startBlock + BLOCKS_PER_WEEK * 2;
        lockUntilBlock = _startBlock + BLOCKS_PER_WEEK * 4;// _startBlock + 4 weeks
        nextHalvingBlock = startBlock.add(BLOCKS_PER_WEEK);
        reserveFund = _reserveFund;
        operator = _operator;
        halvingChecked = true;

        halvingPeriod = BLOCKS_PER_WEEK;
        reservePercent = 0; // 1% ~ 100
        lockPercent = 5000; // 50%
        rewardHalvingRate = 7500; // 75%
        totalAllocPoint = 0;

        // Locker
        startReleaseBlock = lockUntilBlock;//_startReleaseBlock;
        endReleaseBlock = endBlock;//_endReleaseBlock;

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "LayerRewardPool: caller is not the operator");
        _;
    }

    modifier checkHalving() {
        if (halvingChecked) {
            halvingChecked = false;
            uint256 target = block.number < endBlock ? block.number : endBlock;
            while (target >= nextHalvingBlock) {
                massUpdatePools(nextHalvingBlock);
                if (nextHalvingBlock >= bigHalvingBlock && nextHalvingBlock.sub(halvingPeriod) < bigHalvingBlock) {
                    rewardPerBlock = rewardPerBlock.mul(5000).div(10000); // decrease 50%
                } else {
                    rewardPerBlock = rewardPerBlock.mul(rewardHalvingRate).div(10000); // x75% (25% decreased every-week)
                }
                nextHalvingBlock = nextHalvingBlock.add(halvingPeriod);
            }
            halvingChecked = true;
        }
        _;
    }

    function setHalvingPeriod(uint256 _halvingPeriod, uint256 _nextHalvingBlock) external onlyOperator {
        require(_halvingPeriod >= 100, "zero"); // >= 5 minutes
        require(_nextHalvingBlock > block.number, "over");
        halvingPeriod = _halvingPeriod;
        nextHalvingBlock = _nextHalvingBlock;
    }

    function setReserveFund(address _reserveFund) external onlyOperator {
        reserveFund = _reserveFund;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(ILiquidityMigrator _migrator) public onlyOperator {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract.
    function migrate(uint256 _pid) public onlyOperator {
        require(block.number >= startBlock + BLOCKS_PER_WEEK * 4, "DON'T migrate too soon sir!");
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    function checkPoolDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].lpToken != _lpToken, "LayerRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _lastRewardBlock
    ) public onlyOperator {
        require(_allocPoint <= 500000, "too high allocation point"); // <= 500x
        require(_depositFeeBP <= 1000, "too high fee"); // <= 10%
        checkPoolDuplicate(_lpToken);
        massUpdatePools();
        if (block.number < startBlock) {
            // chef is sleeping
            if (_lastRewardBlock == 0) {
                _lastRewardBlock = startBlock;
            } else {
                if (_lastRewardBlock < startBlock) {
                    _lastRewardBlock = startBlock;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardBlock == 0 || _lastRewardBlock < block.number) {
                _lastRewardBlock = block.number;
            }
        }
        bool _isStarted = (_lastRewardBlock <= startBlock) || (_lastRewardBlock <= block.number);
        poolInfo.push(
            PoolInfo({
            lpToken: _lpToken,
            reward2: address(0),
            allocPoint: _allocPoint,
            lastRewardBlock: _lastRewardBlock,
            accMdgPerShare: 0,
            accLockPerShare: 0,
            accReward2PerShare: 0,
            reward2PerBlock: 0,
            reward2EndBlock: 0,

            depositFeeBP: _depositFeeBP,
            isStarted: _isStarted
            })
        );
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
        if (mdgPoolId == 0 && _lpToken == IERC20(mdg)) {
            mdgPoolId = poolInfo.length - 1;
        }
    }

    // Update the given pool's Mdg[N] allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) public onlyOperator {
        require(_allocPoint <= 500000, "too high allocation point"); // <= 500x
        require(_depositFeeBP <= 1000, "too high fee"); // <= 10%
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
        pool.depositFeeBP = _depositFeeBP;
    }

    // Add additional reward for a pool
    function setReward2(uint256 _pid, address _reward2, uint256 _reward2PerBlock, uint256 _reward2EndBlock) external onlyOperator {
        PoolInfo storage pool = poolInfo[_pid];
        require(_reward2 != address(0), "address(0)");
        require(_reward2PerBlock < 0.9 ether, "too high reward");
        if (_reward2 == pool.reward2) {// update info
            updatePool(_pid);
            if (_reward2EndBlock > 0) {
                require(pool.reward2EndBlock > block.number, "reward2 is over");
                require(_reward2EndBlock > block.number, "late");
                require(_reward2EndBlock <= endBlock, "reward2 is redundant");
                pool.reward2EndBlock = _reward2EndBlock;
            }
            pool.reward2PerBlock = _reward2PerBlock;
        } else {
            require(pool.reward2 == address(0), "don't support multiple additional rewards in a pool");
//            require(!pool.isStarted, "Pool started");
            require(_reward2EndBlock > block.number, "late");
            require(_reward2PerBlock > 0, "zero");
            pool.reward2 = _reward2;
            pool.accReward2PerShare = 0;
            pool.reward2PerBlock = _reward2PerBlock;
            pool.reward2EndBlock = _reward2EndBlock > endBlock ? endBlock : _reward2EndBlock;
        }
    }

    // Return accumulate rewarded blocks over the given _from to _to block.
    function getRewardBlocks(uint256 _from, uint256 _to, uint256 _endBlock) internal view returns (uint256) {
        if (_from >= _to) return 0;
        if (_from >= _endBlock) return 0;
        if (_to <= startBlock) return 0;
        if (_to > _endBlock) _to = _endBlock;
        return _to.sub(_from <= startBlock ? startBlock : _from);
    }

    // View function to see pending Mdg[N]s on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMdgPerShare = pool.accMdgPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _generatedReward = getRewardBlocks(pool.lastRewardBlock, block.number, endBlock).mul(rewardPerBlock);
            uint256 _mdgReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accMdgPerShare = accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMdgPerShare).div(1e18).sub(user.rewardDebt);
    }

    function pendingReward2(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.reward2 == address(0)) return 0;
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accReward2PerShare = pool.accReward2PerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _reward2 = getRewardBlocks(pool.lastRewardBlock, block.number, pool.reward2EndBlock).mul(pool.reward2PerBlock);
            accReward2PerShare = accReward2PerShare.add(_reward2.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accReward2PerShare).div(1e18).sub(user.reward2Debt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public checkHalving {
        massUpdatePools(block.number);
    }

    function massUpdatePools(uint256 _targetTime) private {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid, _targetTime);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public checkHalving {
        updatePool(_pid, block.number);
    }

    function updatePool(uint256 _pid, uint256 _targetTime) private {
        PoolInfo storage pool = poolInfo[_pid];
        if (_targetTime <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = _targetTime;
            return;
        }
        if (!pool.isStarted) { // note: pool.lastRewardBlock < _targetTime  <= block.number
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getRewardBlocks(pool.lastRewardBlock, _targetTime, endBlock);
            uint256 _mdgReward = _generatedReward.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            pool.accMdgPerShare = pool.accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
            if (pool.lastRewardBlock < lockUntilBlock) {
                pool.accLockPerShare = pool.accLockPerShare.add(_mdgReward.mul(lockPercent).div(10000).mul(1e18).div(lpSupply));
            }
            if (pool.lastRewardBlock < pool.reward2EndBlock) {
                uint256 _reward2 = getRewardBlocks(pool.lastRewardBlock, _targetTime, pool.reward2EndBlock).mul(pool.reward2PerBlock);
                pool.accReward2PerShare = pool.accReward2PerShare.add(_reward2.mul(1e18).div(lpSupply));
            }
        }
        pool.lastRewardBlock = _targetTime;
    }

    function _harvestReward(uint256 _pid, address _account) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        uint256 newRewardDebt = user.amount.mul(pool.accMdgPerShare).div(1e18);
        uint256 newLockDebt = user.amount.mul(pool.accLockPerShare).div(1e18);
        uint256 newReward2Debt = user.amount.mul(pool.accReward2PerShare).div(1e18);
        uint256 _pendingReward = newRewardDebt.sub(user.rewardDebt);
        uint256 _pendingLock = newLockDebt.sub(user.lockDebt);
        uint256 _pendingReward2 = newReward2Debt.sub(user.reward2Debt);
        user.rewardDebt = newRewardDebt;
        user.lockDebt = newLockDebt;
        user.reward2Debt = newReward2Debt;
        if (_pendingReward > 0) {
            _safeMdgMint(_account, _pendingReward, _pendingLock);
            emit RewardPaid(_account, mdg, _pendingReward);
        }
        if (_pendingReward2 > 0) {
            _safeTokenTransfer(pool.reward2, _account, _pendingReward2);
            emit RewardPaid(_account, pool.reward2, _pendingReward2);
        }
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public checkHalving {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid, block.number);
        if (user.amount > 0) {
            _harvestReward(_pid, _sender);
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(_sender, address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 _depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(reserveFund, _depositFee);
                user.amount = user.amount.add(_amount).sub(_depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accMdgPerShare).div(1e18);
        user.lockDebt = user.amount.mul(pool.accLockPerShare).div(1e18);
        user.reward2Debt = user.amount.mul(pool.accReward2PerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public checkHalving {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid, block.number);
        _harvestReward(_pid, _sender);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMdgPerShare).div(1e18);
        user.lockDebt = user.amount.mul(pool.accLockPerShare).div(1e18);
        user.reward2Debt = user.amount.mul(pool.accReward2PerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    function harvestAllRewards() public checkHalving {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; ++_pid) {
            if (userInfo[_pid][msg.sender].amount > 0) {
                withdraw(_pid, 0);
            }
        }
    }

    function harvestAndRestake() external {
        require(mdgPoolId > 0, "Stake pool hasn't been opened");// pool-0 is always LP of previous layer MDG[N-1]
        harvestAllRewards();
        uint256 _mdgBal = IERC20(mdg).balanceOf(msg.sender);
        if (_mdgBal > 0) {
            IERC20(mdg).safeIncreaseAllowance(address(this), _mdgBal);
            deposit(mdgPoolId, _mdgBal);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external checkHalving {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.lockDebt = 0;
        user.reward2Debt = 0;
        pool.lpToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    function _safeMdgMint(address _to, uint256 _amount, uint256 _lockAmount) internal {
        if (ILayeredMdgToken(mdg).isMinter(address(this)) && _to != address(0)) {
            ILayeredMdgToken mdgToken = ILayeredMdgToken(mdg);
            uint256 _totalSupply = IERC20(mdg).totalSupply() + mdgToken.getBurnedAmount();
            uint256 _cap = mdgToken.cap();
            uint256 _mintAmount = (_totalSupply.add(_amount) <= _cap) ? _amount : _cap.sub(_totalSupply);
            if (_mintAmount > 0) {
                mdgToken.mint(address(this), _mintAmount);
                uint256 _transferAmount = _mintAmount;
                if (_lockAmount > 0) {
                    if (_lockAmount > _mintAmount) _lockAmount = _mintAmount;
                    _transferAmount = _transferAmount.sub(_lockAmount);
                    mdgLocked[_to] = mdgLocked[_to].add(_lockAmount);
                    totalLock = totalLock.add(_lockAmount);
                    emit Lock(_to, _lockAmount);
                }
                IERC20(mdg).safeTransfer(_to, _transferAmount);
                if (reservePercent > 0 && reserveFund != address(0)) {
                    uint256 _reserveAmount = _mintAmount.mul(reservePercent).div(10000);
                    _totalSupply = IERC20(mdg).totalSupply() + mdgToken.getBurnedAmount();
                    _cap = mdgToken.cap();
                    _reserveAmount = (_totalSupply.add(_reserveAmount) <= _cap) ? _reserveAmount : _cap.sub(_totalSupply);
                    if (_reserveAmount > 0) {
                        mdgToken.mint(reserveFund, _reserveAmount);
                    }
                }
            }
        }
    }

    function _safeTokenTransfer(address _token, address _to, uint256 _amount) internal {
        uint256 _tokenBal = IERC20(_token).balanceOf(address(this));
        if (_amount > _tokenBal) {
            _amount = _tokenBal;
        }
        if (_amount > 0) {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function setMdgPoolId(uint256 _mdgPoolId) external onlyOperator {
        mdgPoolId = _mdgPoolId;
    }

    function setRates(uint256 _reservePercent, uint256 _lockPercent, uint256 _rewardHalvingRate) external onlyOperator { // tune and vote
        require(_rewardHalvingRate < 10000, "exceed 100%");
        require(_rewardHalvingRate > 0, "shouldn't set to 0%"); // can't trace
        require(_reservePercent <= 2000, "exceed 20%");
        require(_lockPercent <= 9000, "exceed 90%");
        massUpdatePools();
        reservePercent = _reservePercent;
        lockPercent = _lockPercent;
        rewardHalvingRate = _rewardHalvingRate;
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOperator {
        require(_rewardPerBlock <= 0.2 ether, "too high reward"); // <= 0.2 MDG per block
        massUpdatePools();
        rewardPerBlock = _rewardPerBlock;
    }

    function setHalvingChecked(bool _halvingChecked) external onlyOperator {
        halvingChecked = _halvingChecked;
    }

    function setLastRewardBlock(uint256 _pid, uint256 _lastRewardBlock) external onlyOperator {
        require(_lastRewardBlock >= startBlock, "bad _lastRewardBlock");
        require(_lastRewardBlock > block.number, "late");
        PoolInfo storage pool = poolInfo[_pid];
        require(!pool.isStarted || startBlock > block.number, "Pool started!");
        require(_lastRewardBlock != pool.lastRewardBlock, "no change");
        pool.lastRewardBlock = _lastRewardBlock;
        if (pool.isStarted) {
            pool.isStarted = false;
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint);
        } else if (_lastRewardBlock == startBlock) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
    }

    function setStartBlock(uint256 _startBlock, uint256 _lockUntilBlock, uint256 _bigHalvingBlock, uint256 _endBlock) external onlyOperator {
        if (_startBlock > block.number) {
            require(block.number < startBlock, "The layer started!");
            startBlock = _startBlock;
            nextHalvingBlock = startBlock.add(BLOCKS_PER_WEEK);
            bigHalvingBlock = startBlock + BLOCKS_PER_WEEK * 2;
            lockUntilBlock = startBlock + BLOCKS_PER_WEEK * 4;
            endBlock = startBlock + BLOCKS_PER_WEEK * 8;
            uint256 plen = poolInfo.length;
            for (uint256 pid = 0; pid < plen; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                if (pool.isStarted) {
                    pool.lastRewardBlock = startBlock;
                } else {
                    if (pool.lastRewardBlock <= startBlock) {
                        pool.isStarted = true;
                        pool.lastRewardBlock = startBlock;
                        totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
                    }
                }
            }
        }
        if (_bigHalvingBlock > block.number) bigHalvingBlock = _bigHalvingBlock;
        if (_endBlock > block.number) {
            require(block.number < endBlock, "Layer finished");
            endBlock = _endBlock;
        }
        if (_lockUntilBlock > block.number) {
            require(block.number < lockUntilBlock, "Lock has released");
            require(_lockUntilBlock > startBlock, "Bad _lockUntilBlock");
            lockUntilBlock = _lockUntilBlock;
        }
        if (lockUntilBlock > endBlock) lockUntilBlock = endBlock;
        startReleaseBlock = lockUntilBlock;
        endReleaseBlock = endBlock;
    }

    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    // locker_field {
    function canUnlockAmount(address _account) public view returns (uint256) {
        if (block.number < startReleaseBlock) return 0;
        if (block.number >= endReleaseBlock) return mdgLocked[_account].sub(mdgReleased[_account]);
        uint256 _releasedBlock = block.number.sub(startReleaseBlock);
        uint256 _totalVestingBlock = endReleaseBlock.sub(startReleaseBlock);
        return mdgLocked[_account].mul(_releasedBlock).div(_totalVestingBlock).sub(mdgReleased[_account]);
    }

    function unlock() external {
        require(block.number > startReleaseBlock, "still locked");
        require(mdgLocked[msg.sender] >= mdgReleased[msg.sender], "no locked");

        uint256 _amount = canUnlockAmount(msg.sender);

        IERC20(mdg).safeTransfer(msg.sender, _amount);
        mdgReleased[msg.sender] = mdgReleased[msg.sender].add(_amount);
        totalLock = totalLock.sub(_amount);
    }
    // } end_locker_field

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.number < startBlock + BLOCKS_PER_WEEK * 104) {
            // do not allow to drain lpToken if less than 2 years after farming
            require(address(_token) != mdg, "mdg");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.lpToken, "!pool.lpToken");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
