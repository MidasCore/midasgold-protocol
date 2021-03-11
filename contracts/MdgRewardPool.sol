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

import "./MidasGoldToken.sol";
import "./interfaces/ILiquidityMigrator.sol";
import "./interfaces/IMdgLocker.sol";

contract MdgRewardPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BLOCKS_PER_DAY = 28800; // 86400 / 3;
    uint256 public constant BLOCKS_PER_WEEK = 201600; // 28800 * 7;

    // governance
    address public operator = address(0xD025628eEe504330f1282C96B28a731E3995ff66);

    // flags
    bool public initialized = false;

    address public reserveFund;
    uint256 public reservePercent = 1000; // 100 = 1%
    uint256 public burnPercent = 250;

    uint256 public lockPercent = 7500; // 75%
    IMdgLocker mdgLocker;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 mdoDebt;
        uint256 bcashDebt;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. MDGs to distribute per block.
        uint256 lastRewardBlock; // Last block number that MDGs distribution occurs.
        uint256 accMdgPerShare; // Accumulated MDGs per share, times 1e18. See below.
        uint256 accMdoPerShare;
        uint256 accBcashPerShare;
        uint16 depositFeeBP; // Deposit fee in basis points
        bool isStarted; // if lastRewardBlock has passed
    }

    address public mdg = address(0xC1eDCc306E6faab9dA629efCa48670BE4678779D);
    address public mdo = address(0x35e869B7456462b81cdB5e6e42434bD27f3F788c);
    address public bcash = address(0xc2161d47011C4065648ab9cDFd0071094228fa09);

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    uint256 public rewardPerBlock;
    uint256 public mdoPerBlock;
    uint256 public bcashPerBlock;

    // The block number when mdg mining starts.
    uint256 public startBlock;

    uint256 public lockUntilBlock;

    uint256 public nextHalvingBlock;

    // The liquidity migrator contract. It has a lot of power. Can only be set through governance (owner).
    ILiquidityMigrator public migrator;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    bool public halvingChecked;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, address indexed token, uint256 amount);

    function initialize(
        address _mdg,
        address _mdo,
        address _bcash,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _lockUntilBlock,
        address _mdgLocker,
        address _reserveFund,
        address _operator
    ) public notInitialized {
        require(block.number < _startBlock, "late");
        mdg = _mdg;
        mdo = _mdo;
        bcash = _bcash;
        rewardPerBlock = _rewardPerBlock; // start at 0.2 MDG per block for the first week
        startBlock = _startBlock; // supposed to be 5,383,000 (Thu Mar 04 2021 17:00:00 GMT+8)
        lockUntilBlock = _lockUntilBlock;
        nextHalvingBlock = startBlock.add(BLOCKS_PER_WEEK);
        mdgLocker = IMdgLocker(_mdgLocker);
        reserveFund = _reserveFund;
        operator = _operator;

        reservePercent = 1000; // 10%
        burnPercent = 250; // 2.5%
        lockPercent = 7500; // 75%

        mdoPerBlock = 0.01 ether;
        bcashPerBlock = 0.01 ether;

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    modifier notInitialized() {
        require(!initialized, "initialized");
        _;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "MdgRewardPool: caller is not the operator");
        _;
    }

    modifier checkHalving() {
        if (halvingChecked) {
            halvingChecked = false;
            while (block.number >= nextHalvingBlock) {
                massUpdatePools();
                rewardPerBlock = rewardPerBlock.mul(9750).div(10000); // x97.5% (2.5% decreased every-week)
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
            require(poolInfo[pid].lpToken != _lpToken, "MdgRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _lastRewardBlock
    ) public onlyOperator {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
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
        bool _isStarted =
        (_lastRewardBlock <= startBlock) ||
        (_lastRewardBlock <= block.number);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : _lastRewardBlock,
            accMdgPerShare : 0,
            accMdoPerShare : 0,
            accBcashPerShare : 0,
            depositFeeBP : _depositFeeBP,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's mdg allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) public onlyOperator {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        require(_allocPoint <= 500000, "too high allocation point"); // <= 500x
        require(_depositFeeBP <= 1000, "too high fee"); // <= 10%
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
        pool.depositFeeBP = _depositFeeBP;
    }

    // Return accumulate rewarded blocks over the given _from to _to block.
    function getRewardBlocks(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_from >= _to) return 0;
        if (_to <= startBlock) {
            return 0;
        } else {
            if (_from <= startBlock) {
                return _to.sub(startBlock);
            } else {
                return _to.sub(_from);
            }
        }
    }

    // View function to see pending MDGs on frontend.
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

    function pendingMdo(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMdoPerShare = pool.accMdoPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _generatedReward = getRewardBlocks(pool.lastRewardBlock, block.number).mul(mdoPerBlock);
            uint256 _mdoReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accMdoPerShare = accMdoPerShare.add(_mdoReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMdoPerShare).div(1e18).sub(user.mdoDebt);
    }

    function pendingBcash(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBcashPerShare = pool.accBcashPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _generatedReward = getRewardBlocks(pool.lastRewardBlock, block.number).mul(bcashPerBlock);
            uint256 _bcashReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accBcashPerShare = accBcashPerShare.add(_bcashReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accBcashPerShare).div(1e18).sub(user.bcashDebt);
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
            uint256 _mdoReward = _generatedReward.mul(mdoPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            uint256 _bcashReward = _generatedReward.mul(bcashPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            pool.accMdgPerShare = pool.accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
            pool.accMdoPerShare = pool.accMdoPerShare.add(_mdoReward.mul(1e18).div(lpSupply));
            pool.accBcashPerShare = pool.accBcashPerShare.add(_bcashReward.mul(1e18).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
    }

    function _harvestReward(uint256 _pid, address _account) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        uint256 _pendingReward = user.amount.mul(pool.accMdgPerShare).div(1e18).sub(user.rewardDebt);
        if (_pendingReward > 0) {
            _safeMdgMint(_account, _pendingReward);
            emit RewardPaid(_account, mdg, _pendingReward);
        }
        uint256 _pendingMdo = user.amount.mul(pool.accMdoPerShare).div(1e18).sub(user.mdoDebt);
        if (_pendingMdo > 0) {
            _safeTokenTransfer(mdo, _account, _pendingMdo);
            emit RewardPaid(_account, mdo, _pendingMdo);
        }
        uint256 _pendingBcash = user.amount.mul(pool.accBcashPerShare).div(1e18).sub(user.bcashDebt);
        if (_pendingBcash > 0) {
            _safeTokenTransfer(bcash, _account, _pendingBcash);
            emit RewardPaid(_account, bcash, _pendingBcash);
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
        user.mdoDebt = user.amount.mul(pool.accMdoPerShare).div(1e18);
        user.bcashDebt = user.amount.mul(pool.accBcashPerShare).div(1e18);
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
        user.mdoDebt = user.amount.mul(pool.accMdoPerShare).div(1e18);
        user.bcashDebt = user.amount.mul(pool.accBcashPerShare).div(1e18);
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

    function harvestAndRestake() public {
        harvestAllRewards();
        uint256 _mdgBal = IERC20(mdg).balanceOf(address(this));
        if (_mdgBal > 0) {
            IERC20(mdg).safeIncreaseAllowance(address(this), _mdgBal);
            deposit(8, _mdgBal);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external checkHalving {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.mdoDebt = 0;
        user.bcashDebt = 0;
        pool.lpToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    function _safeMdgMint(address _to, uint256 _amount) internal {
        if (MidasGoldToken(mdg).minters(address(this)) && _to != address(0)) {
            uint256 _totalSupply = MidasGoldToken(mdg).totalSupply();
            uint256 _cap = MidasGoldToken(mdg).cap();
            uint256 _mintAmount = (_totalSupply.add(_amount) <= _cap) ? _amount : _cap.sub(_totalSupply);
            if (_mintAmount > 0) {
                uint256 _burnAmount = (burnPercent == 0) ? 0 : _mintAmount.mul(burnPercent).div(10000);
                if (_totalSupply.add(_mintAmount).add(_burnAmount) > _cap) {
                    _burnAmount = _cap.sub(_totalSupply).sub(_mintAmount);
                }
                MidasGoldToken(mdg).mint(address(this), _mintAmount.add(_burnAmount));
                uint256 _transferAmount = _mintAmount;
                if (block.number < lockUntilBlock) {
                    uint256 _lockAmount = _mintAmount.mul(lockPercent).div(10000);
                    _transferAmount = _mintAmount.sub(_lockAmount);
                    IERC20(mdg).safeIncreaseAllowance(address(mdgLocker), _lockAmount);
                    IMdgLocker(mdgLocker).lock(_to, _lockAmount);
                }
                IERC20(mdg).safeTransfer(_to, _transferAmount);
                if (_burnAmount > 0) {
                    MidasGoldToken(mdg).burn(_burnAmount);
                }
                if (reservePercent > 0 && reserveFund != address(0)) {
                    uint256 _reserveAmount = _mintAmount.mul(reservePercent).div(10000);
                    _totalSupply = MidasGoldToken(mdg).totalSupply();
                    _cap = MidasGoldToken(mdg).cap();
                    _reserveAmount = (_totalSupply.add(_reserveAmount) <= _cap) ? _reserveAmount : _cap.sub(_totalSupply);
                    if (_reserveAmount > 0) {
                        MidasGoldToken(mdg).mint(reserveFund, _reserveAmount);
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

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOperator {
        require(_rewardPerBlock <= 0.2 ether, "too high reward"); // <= 0.2 MDG per block
        _rewardPerBlock = _rewardPerBlock;
    }

    function setMdoPerBlock(uint256 _mdoPerBlock) external onlyOperator {
        require(_mdoPerBlock <= 0.2 ether, "too high reward"); // <= 0.2 MDO per block
        mdoPerBlock = _mdoPerBlock;
    }

    function setBcashPerBlock(uint256 _bcashPerBlock) external onlyOperator {
        require(_bcashPerBlock <= 0.2 ether, "too high reward"); // <= 0.2 bCash per block
        bcashPerBlock = _bcashPerBlock;
    }

    function setHalvingChecked(bool _halvingChecked) external onlyOperator {
        halvingChecked = _halvingChecked;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.number < startBlock + BLOCKS_PER_WEEK * 104) {
            // do not allow to drain lpToken if less than 2 years after farming
            require(address(_token) != mdg, "mdg");
            require(address(_token) != mdo, "mdo");
            require(address(_token) != bcash, "bcash");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.lpToken, "!pool.lpToken");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
