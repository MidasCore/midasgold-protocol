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
import "./interfaces/IMdgLocker.sol";

contract LayerRewardPool {// all 'mdg' in this contract represents MDG2, MDG3, etc.
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BLOCKS_PER_DAY = 28800; // 86400 / 3;
    uint256 public constant BLOCKS_PER_WEEK = 201600; // 28800 * 7;

    address public operator = address(0xD025628eEe504330f1282C96B28a731E3995ff66); // governance
    bool public initialized = false;
    address public reserveFund = address(0x39d91fb1Cb86c836da6300C0e700717d5dFe289F);
    uint256 public reservePercent = 1000; // 10%
    uint256 public lockPercent = 5000; // 50%
    uint256 public rewardHalvingRate = 7500; // 75%
    IMdgLocker private layeredMdgLocker;
    address public mdg; // address of Mdg[N]Token
    uint256 public mdgPoolId;
    uint256 public layerId; // from 2
    uint256 public totalAllocPoint = 0;// Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public rewardPerBlock; // 0.1
    uint256 public startBlock;    // The block number when Mdg[N] mining starts.
    uint256 public endBlock; // default = startBlock + 10 weeks
    uint256 public lockUntilBlock;
    uint256 public nextHalvingBlock;

    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Mdg[N]s to distribute per block.
        uint256 lastRewardBlock; // Last block number that Mdg[N]s distribution occurs.
        uint256 accMdgPerShare; // Accumulated Mdg[N] per share, times 1e18. See below.
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
    event RewardPaid(address indexed user, uint256 amount);

    function initialize(
        uint256 _layerId,
        address _mdg, // Mdg[N]Token contract
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _lockUntilBlock,
        address _layeredMdgLocker,
        address _reserveFund,
        address _operator
    ) public {
        require(!initialized || (startBlock > block.number && poolInfo.length == 0 && operator == msg.sender), "initialized");
        require(block.number < _startBlock, "late");
        require(_layerId >= 2, "from 2");
        layerId = _layerId;
        mdg = _mdg;
        rewardPerBlock = _rewardPerBlock; // start at 0.1 Mdg[N] per block for the first week
        startBlock = _startBlock;
        endBlock = _startBlock + BLOCKS_PER_WEEK * 10;
        lockUntilBlock = _lockUntilBlock;// _startBlock + 4 weeks
        nextHalvingBlock = startBlock.add(BLOCKS_PER_WEEK);
        layeredMdgLocker = IMdgLocker(_layeredMdgLocker);
        reserveFund = _reserveFund;
        operator = _operator;

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "LayerRewardPool: caller is not the operator");
        _;
    }

    modifier checkHalving() {
        if (halvingChecked && block.number < endBlock) {
            halvingChecked = false;
            while (block.number >= nextHalvingBlock) {
                massUpdatePools();
                if (nextHalvingBlock >= lockUntilBlock && lockUntilBlock > startBlock && nextHalvingBlock.sub(BLOCKS_PER_WEEK) < lockUntilBlock) {
                    rewardPerBlock = rewardPerBlock.mul(5000).div(10000); // decreased 50% when unlock has started
                } else {
                    rewardPerBlock = rewardPerBlock.mul(rewardHalvingRate).div(10000); // x75% (25% decreased every-week)
                }
                nextHalvingBlock = nextHalvingBlock.add(BLOCKS_PER_WEEK);
            }
            halvingChecked = true;
        }
        _;
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
        allocPoint: _allocPoint,
        lastRewardBlock: _lastRewardBlock,
        accMdgPerShare: 0,
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

    // Return accumulate rewarded blocks over the given _from to _to block.
    function getRewardBlocks(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_from >= _to) return 0;
        if (_from >= endBlock) return 0;
        if (_to <= startBlock) {
            return 0;
        } else {
            if (_from <= startBlock) {
                if (_to >= endBlock) return endBlock.sub(startBlock);
                return _to.sub(startBlock);
            } else {
                if (_to >= endBlock) return endBlock.sub(_from);
                return _to.sub(_from);
            }
        }
    }

    // View function to see pending Mdg[N]s on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMdgPerShare = pool.accMdgPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _generatedReward = getRewardBlocks(pool.lastRewardBlock, block.number).mul(rewardPerBlock);
            uint256 _mdgReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accMdgPerShare = accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMdgPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getRewardBlocks(pool.lastRewardBlock, block.number);
            uint256 _mdgReward = _generatedReward.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            pool.accMdgPerShare = pool.accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
    }

    function _harvestReward(uint256 _pid, address _account) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        uint256 _pendingReward = user.amount.mul(pool.accMdgPerShare).div(1e18).sub(user.rewardDebt);
        if (_pendingReward > 0) {
            _safeMdgMint(_account, _pendingReward);
            emit RewardPaid(_account, _pendingReward);
        }
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public checkHalving {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
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
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public checkHalving {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        _harvestReward(_pid, _sender);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMdgPerShare).div(1e18);
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

    function setMdgPoolId(uint256 _mdgPoolId) external onlyOperator {
        mdgPoolId = _mdgPoolId;
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external checkHalving {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    function _safeMdgMint(address _to, uint256 _amount) internal {
        if (ILayeredMdgToken(mdg).isMinter(address(this)) && _to != address(0)) {
            ILayeredMdgToken mdgToken = ILayeredMdgToken(mdg);
            uint256 _totalSupply = IERC20(mdg).totalSupply() + mdgToken.getBurnedAmount();
            uint256 _cap = mdgToken.cap();
            uint256 _mintAmount = (_totalSupply.add(_amount) <= _cap) ? _amount : _cap.sub(_totalSupply);
            if (_mintAmount > 0) {
                mdgToken.mint(address(this), _mintAmount);
                uint256 _transferAmount = _mintAmount;
                if (block.number < lockUntilBlock) {
                    uint256 _lockAmount = _mintAmount.mul(lockPercent).div(10000);
                    _transferAmount = _mintAmount.sub(_lockAmount);
                    IERC20(mdg).safeIncreaseAllowance(address(layeredMdgLocker), _lockAmount);
                    layeredMdgLocker.lock(_to, _lockAmount);
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

    function setRates(uint256 _reservePercent, uint256 _lockPercent, uint256 _rewardHalvingRate) external onlyOperator { // tune and vote
        require(_rewardHalvingRate < 10000, "exceed 100%");
        require(_rewardHalvingRate > 0, "shouldn't set to 0%"); // can't trace
        require(_reservePercent <= 2000, "exceed 20%");
        require(_lockPercent <= 9000, "exceed 90%");
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

    function setStartBlock(uint256 _startBlock, uint256 _lockUntilBlock) external onlyOperator {
        require(block.number < startBlock, "The layer started!");
        require(block.number < _startBlock, "late");
        startBlock = _startBlock;
        lockUntilBlock = _lockUntilBlock;
        nextHalvingBlock = startBlock.add(BLOCKS_PER_WEEK);
        endBlock = startBlock + BLOCKS_PER_WEEK * 10;
    }

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
