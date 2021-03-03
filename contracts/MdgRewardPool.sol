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
import "./interfaces/IMdgLocker.sol";

contract MdgRewardPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator = address(0xD025628eEe504330f1282C96B28a731E3995ff66);

    address public reserveFund;
    uint256 public reservePercent = 1000; // 100 = 1%
    uint256 public burnPercent = 250;

    uint256 public lockPercent = 7500; // 75%
    IMdgLocker mdgLocker = IMdgLocker(0x0000000000000000000000000000000000000000);

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. MDGs to distribute per block.
        uint256 lastRewardBlock; // Last block number that MDGs distribution occurs.
        uint256 accMdgPerShare; // Accumulated MDGs per share, times 1e18. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        bool isStarted; // if lastRewardBlock has passed
    }

    address public mdg = address(0xC1eDCc306E6faab9dA629efCa48670BE4678779D);

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    uint256 public rewardPerBlock;

    // The block number when mdg mining starts.
    uint256 public startBlock;

    uint256 public lockUntilBlock;

    uint256 public nextHalvingBlock;

    uint256 public constant BLOCKS_PER_DAY = 28800; // 86400 / 3;

    uint256 public constant BLOCKS_PER_WEEK = 201600; // 28800 * 7;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _mdg,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _lockUntilBlock,
        address _mdgLocker,
        address _operator
    ) public {
        require(block.number < _startBlock, "late");
        if (_mdg != address(0)) mdg = _mdg;
        rewardPerBlock = _rewardPerBlock; // start at 0.2 MDG per block for the first week
        startBlock = _startBlock; // supposed to be 5,383,000 (Thu Mar 04 2021 17:00:00 GMT+8)
        lockUntilBlock = _lockUntilBlock;
        nextHalvingBlock = startBlock.add(BLOCKS_PER_WEEK);
        if (_mdgLocker != address(0)) mdgLocker = IMdgLocker(_mdgLocker);
        operator = _operator;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "MdgRewardPool: caller is not the operator");
        _;
    }

    modifier checkHalving() {
        while (block.number >= nextHalvingBlock) {
            massUpdatePools();
            rewardPerBlock = rewardPerBlock.mul(9750).div(10000); // x97.5% (2.5% decreased every-week)
            nextHalvingBlock = nextHalvingBlock.add(BLOCKS_PER_WEEK);
        }
        _;
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

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_from >= _to) return 0;
        if (_to <= startBlock) {
            return 0;
        } else {
            if (_from <= startBlock) {
                return rewardPerBlock.mul(_to.sub(startBlock));
            } else {
                return rewardPerBlock.mul(_to.sub(_from));
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
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _mdgReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accMdgPerShare = accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMdgPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public checkHalving {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public checkHalving {
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
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _mdgReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accMdgPerShare = pool.accMdgPerShare.add(_mdgReward.mul(1e18).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) external checkHalving {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accMdgPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeMdgMint(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
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
    function withdraw(uint256 _pid, uint256 _amount) external checkHalving {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accMdgPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeMdgMint(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMdgPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
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

    function safeMdgMint(address _to, uint256 _amount) internal {
        if (MidasGoldToken(mdg).minters(address(this)) && _to != address(0)) {
            uint256 _totalSupply = MidasGoldToken(mdg).totalSupply();
            uint256 _cap = MidasGoldToken(mdg).cap();
            uint256 _mintAmount = (_totalSupply.add(_amount) <= _cap) ? _amount : _cap.sub(_totalSupply);
            if (_mintAmount > 0) {
                uint256 _burnAmount = (burnPercent == 0) ? 0 : _mintAmount.mul(burnPercent).div(10000);
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

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.number < startBlock + BLOCKS_PER_WEEK * 104) {
            // do not allow to drain lpToken if less than 2 years after farming
            require(address(_token) != mdg, "!mdg");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.lpToken, "!pool.lpToken");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
