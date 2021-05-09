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

import "./interfaces/IValueLiquidPair.sol";
import "./MidasGoldToken.sol";

contract Bridge { // 'mdg' represents layer token MDG[N], 'MDG' represent MidasGoldToken
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 public constant BLOCKS_PER_10_MINUTES = 200;
    uint256 public constant BLOCKS_PER_2_HOURs = 2400;
    uint256 public constant BLOCKS_PER_6_HOURs = 2400 * 3;
    uint256 public constant BLOCKS_PER_12_HOURs = 2400 * 6;
    uint256 public constant BLOCKS_PER_DAY = 28800; // 86400 / 3;
    address public constant MDG = address(0xC1eDCc306E6faab9dA629efCa48670BE4678779D);
    address public constant BUSD = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address public MDG_BUSD = address(0xB10C30f83eBb92F5BaEf377168C4bFc9740d903c);

    address public operator = address(0xD025628eEe504330f1282C96B28a731E3995ff66);
    bool public initialized = false;
    address public reserveFund = address(0x39d91fb1Cb86c836da6300C0e700717d5dFe289F);
    uint256 public halvingRate = 9500; // 9500/10000 = 0.95
    uint256 public burnRate = 2000; // 2000/10000 = 20%
    uint256 public reserveRate = 2000; // 20%
    uint256 public rewardRate = 3000; //30%
    uint256 public totalMDGBurned = 0;
    mapping(address => bool) private rewardDistributors;
    uint256 public activeDistributorAmount = 0;

    struct RateVector {
        // averageRate = (blockSum + prevBlockSum) / (blockCount + prevBlockCount)
        uint256 blockSum; // each block ~ 6 hours
        uint256 blockCount;
        uint256 startBlock;
        uint256 prevBlockSum;
        uint256 prevBlockCount;
        uint256 lastUpdated;
        uint256 lastRate;
    }

    struct LayerInfo {
        IERC20 mdg;// Mdg[N]
        address mdgBusd;
        uint256 lastRate;
        uint256 startBlock;
        uint256 endBlock;
        uint256 nextHalvingBlock;
        uint256 MDGRewards;
        uint256 MDGBurned;
        uint256 mdgConverted; // mdg[N]
    }

    LayerInfo[] public layerInfo;
    RateVector[] public layerRateVector;


    event Initialized(address indexed executor, uint256 at);
    event Convert(address indexed user, uint256 burnAmount, uint256 MDGOut);

    function initialize() public {
        require(!initialized, "initialized");
        require(MidasGoldToken(MDG).minters(address(this)), "not minter");
        operator = address(0xD025628eEe504330f1282C96B28a731E3995ff66);
        reserveFund = address(0x39d91fb1Cb86c836da6300C0e700717d5dFe289F);
        MDG_BUSD = address(0xB10C30f83eBb92F5BaEf377168C4bFc9740d903c);
        halvingRate = 9500; // 9500/10000 = 0.95
        burnRate = 2000; // 2000/10000 = 20%
        reserveRate = 2000; // 20%
        rewardRate = 3000; //30%
        layerInfo.push(LayerInfo(IERC20(0), address(0), 0, 0, 0, 0, 0, 0, 0)); // fake layer 0
        layerInfo.push(LayerInfo(IERC20(0), address(0), 0, 0, 0, 0, 0, 0, 0)); // fake layer 1
        layerRateVector.push(RateVector(0, 0, 0, 0, 0, 0, 0)); // fake layer 0
        layerRateVector.push(RateVector(0, 0, 0, 0, 0, 0, 0)); // fake layer 1

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    modifier notInitialized() {
        require(!initialized, "initialized");
        _;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "not operator");
        _;
    }

    modifier onlyDistributor() {
        require(msg.sender == operator || rewardDistributors[msg.sender], "!distributor");
        _;
    }

    modifier checkHalving() {
        uint256 _length = layerInfo.length;
        for (uint256 _i = 2; _i < _length; _i++) {
            LayerInfo storage _layer = layerInfo[_i];
            if (_layer.endBlock > block.number) {
                while (_layer.lastRate > 1000 && block.number >= _layer.nextHalvingBlock) {
                    _layer.lastRate = _layer.lastRate.mul(halvingRate).div(10000);
                    _layer.nextHalvingBlock = _layer.nextHalvingBlock.add(BLOCKS_PER_2_HOURs);
                }
                if (_layer.lastRate < 1000) _layer.lastRate = 1000;
            }
        }
        _;
    }

    function updateRate(uint _layerId) external {
        require(_layerId < layerInfo.length, "layer not found");
        LayerInfo storage _layer = layerInfo[_layerId];
        if (_layer.endBlock > block.number) {
            while (_layer.lastRate > 1000 && block.number >= _layer.nextHalvingBlock) {
                _layer.nextHalvingBlock = _layer.nextHalvingBlock.add(BLOCKS_PER_2_HOURs);
                _layer.lastRate = _layer.lastRate.mul(halvingRate).div(10000);
            }
            if (_layer.lastRate < 1000) _layer.lastRate = 1000;
        }
    }

    function setOperator(address _operator) external onlyOperator {
        require(operator != address(0), "zero");
        operator = _operator;
    }

    function setReserveFund(address _reserveFund) external onlyOperator {
        require(_reserveFund != address(0), "zero");
        reserveFund = _reserveFund;
    }

    function setMDGBUSD(address _MDGBUSD) external onlyOperator {
        require(IValueLiquidPair(_MDGBUSD).token0() == MDG, "wrong _MDGBUSD");
        require(IValueLiquidPair(_MDGBUSD).token1() == BUSD, "wrong _MDGBUSD");
        MDG_BUSD = _MDGBUSD;
    }

    function addRewardDistributor(address _distributor) external onlyOperator {
        if (!rewardDistributors[_distributor]) {
            activeDistributorAmount++;
            rewardDistributors[_distributor] = true;
        }
    }

    function removeRewardDistributor(address _distributor) external onlyOperator {
        if (rewardDistributors[_distributor]) {
            rewardDistributors[_distributor] = false;
            activeDistributorAmount--;
        }
    }

    function setRates(uint256 _halvingRate, uint256 _burnRate, uint256 _reserveRate, uint256 _rewardRate) external onlyOperator {
        require(_halvingRate < 10000, "over 100%");
        require(_burnRate.add(_reserveRate).add(_rewardRate) <= 10000, "over 100%");
        halvingRate = _halvingRate;
        burnRate = _burnRate;
        reserveRate = _reserveRate;
        rewardRate = _rewardRate;
    }

    function setLayer(uint256 _layerId, address _mdg, address _mdgBusd, uint256 _lastRate, uint256 _startBlock, uint256 _endBlock) external onlyOperator {
        require(_mdg != address(0), "wrong _mdg");
        require(_lastRate >= 1000, "rate < 0.1"); // 1000/10000 = 0.1
        require(_lastRate <= 10000, "rate > 1"); // 10000/10000 = 1.0
        require(_endBlock == 0 || _endBlock > _startBlock, "startBlock over endBlock");
        require(_layerId <= layerInfo.length, "wrong _layerId");
        require(IValueLiquidPair(_mdgBusd).token0() == _mdg, "wrong _mdgBusd");
        require(IValueLiquidPair(_mdgBusd).token1() == BUSD, "wrong _mdgBusd");

        if (_layerId == layerInfo.length) {
            uint256 _nextHalvingBlock = _startBlock.add(BLOCKS_PER_2_HOURs);
            if (_endBlock == 0) _endBlock = _startBlock + BLOCKS_PER_DAY * 21;
            layerInfo.push(LayerInfo(IERC20(_mdg), _mdgBusd, _lastRate, _startBlock, _endBlock, _nextHalvingBlock, 0, 0, 0));
            layerRateVector.push(RateVector(0, 0, 0, 0, 0, 0, 0));
            updateAverageRate(_layerId);
        } else {
            require(_endBlock > block.number, "late");
            LayerInfo storage _layerInfo = layerInfo[_layerId];
            _layerInfo.mdg = IERC20(_mdg);
            _layerInfo.mdgBusd = _mdgBusd;
            _layerInfo.lastRate = _lastRate;
            _layerInfo.startBlock = _startBlock;
            _layerInfo.endBlock = _endBlock;
        }
    }

    function setLastRate(uint256 _layerId, uint256 _lastRate, uint256 _nextHalvingBlock) external onlyOperator {
        require(_layerId < layerInfo.length, "layer not found");
        LayerInfo storage _layerInfo = layerInfo[_layerId];
        require(_lastRate >= 1000, "rate < 0.1"); // 1000/10000 = 0.1
        require(_lastRate <= 10000, "rate > 1"); // 10000/10000 = 1.0
        require(_nextHalvingBlock > block.number, "late");
        _layerInfo.lastRate = _lastRate;
        _layerInfo.nextHalvingBlock = _nextHalvingBlock;
    }

    function getInstantRate(LayerInfo storage _layer) internal view returns (uint256) {
        (uint112 _R0, uint112 _R1, ) = IValueLiquidPair(MDG_BUSD).getReserves(); // MDG
        (uint112 _r0, uint112 _r1, ) = IValueLiquidPair(_layer.mdgBusd).getReserves(); // mdg[N]
        uint256 rate = uint256(_R0).mul(_r1).div(_R1).mul(10).div(_r0);
        rate = rate < 1 ? 1 : rate >= 10 ? 10
                    : (rate.mul(_r0).mul(_R1) != uint256(_R0).mul(_r1).mul(10)) ? rate + 1 : rate;
        return rate * 1000;
    }

    function getInstantRate(uint256 _layerId) public view returns (uint256) { // returns in [1000, 10000]
        require(_layerId < layerInfo.length, "layer not found");
        return getInstantRate(layerInfo[_layerId]);
    }

    // should call updateAverageRate() before
    function getAverageRate(uint256 _layerId) external view returns (uint256) {
        require(_layerId < layerRateVector.length, "layer not found");
        RateVector storage _vector = layerRateVector[_layerId];
        return _vector.blockSum.add(_vector.prevBlockSum).div(_vector.blockCount + _vector.prevBlockCount);
    }

    function updateAverageRate(uint256 _layerId) public {
        require(_layerId < layerInfo.length, "layer not found");
        LayerInfo storage _layer = layerInfo[_layerId];
        RateVector storage _vector = layerRateVector[_layerId];
        uint256 _rate = getInstantRate(_layer);

        if (_vector.blockCount == 0) { // first rate
            _vector.blockCount = 1;
            _vector.blockSum = _rate;
            _vector.startBlock = block.number;
            _vector.lastUpdated = block.number;
        } else if (block.number > BLOCKS_PER_12_HOURs + _vector.startBlock) { // refresh
            _vector.blockCount = 1;
            _vector.blockSum = _rate;
            _vector.startBlock = block.number;
            _vector.prevBlockCount = 0;
            _vector.prevBlockSum = 0;
            _vector.lastUpdated = block.number;
        } else if (block.number > BLOCKS_PER_6_HOURs + _vector.startBlock) {
            _vector.prevBlockCount = _vector.blockCount;
            _vector.prevBlockSum = _vector.blockSum;
            _vector.blockCount = 1;
            _vector.blockSum = _rate;
            _vector.startBlock = block.number;
            _vector.lastUpdated = block.number;
        } else {
            if (block.number > BLOCKS_PER_10_MINUTES + _vector.lastUpdated || _vector.blockCount + _vector.prevBlockCount == 1) {
                _vector.blockSum += _rate;
                _vector.blockCount++;
                _vector.lastUpdated = block.number;
            } else {
                uint256 _rateSum = _vector.blockSum.add(_vector.prevBlockSum).sub(_vector.lastRate);
                uint256 _rateCount = _vector.blockCount + _vector.prevBlockCount - 1;
                uint256 _averageRate = _rateSum.div(_rateCount);
                if (absDiff(_averageRate, _rate) < absDiff(_averageRate, _vector.lastRate)) {
                    _vector.blockSum = _vector.blockSum.sub(_vector.lastRate).add(_rate);
                }
            }
        }
        _vector.lastRate = _rate;
    }

    function absDiff(uint256 a, uint256 b) pure internal returns(uint256 c) {
        c = a > b ? a - b : b - a;
    }

    function convert(uint256 _layerId, uint256 _mdgAmount) external checkHalving {
        require(_layerId < layerInfo.length, "layer not found");
        LayerInfo storage _layer = layerInfo[_layerId];
        require(_layer.endBlock >= block.number, "closed");
        require(_layer.startBlock <= block.number, "not opened yet");
        address _sender = msg.sender;
        _layer.mdg.safeTransferFrom(_sender, address(this), _mdgAmount);// deposit mdg[N]
        _layer.mdgConverted = _layer.mdgConverted.add(_mdgAmount);

        // mint MDG to user
        uint256 _MDGOut = _mdgAmount.mul(_layer.lastRate).div(10000);
        MidasGoldToken(MDG).mint(_sender, _MDGOut);

        // mint MDG rewards + reserve + burn
        uint256 _excessiveMDG = _mdgAmount.sub(_MDGOut);
        _mintMDG(_excessiveMDG, _layer);

        emit Convert(_sender, _mdgAmount, _MDGOut);
    }

    function _mintMDG(uint256 _excessiveMDG, LayerInfo storage _layer) internal {
        uint256 _toReserve = _excessiveMDG.mul(reserveRate).div(10000);//20%
        uint256 _rewardAmount = _excessiveMDG.mul(rewardRate).div(10000);//30%
        uint256 _burnAmount = _excessiveMDG.mul(burnRate).div(10000);//20%
        MidasGoldToken(MDG).mint(reserveFund, _toReserve);
        MidasGoldToken(MDG).mint(address(this), _rewardAmount.add(_burnAmount));
        _layer.MDGRewards = _layer.MDGRewards.add(_rewardAmount);
        _layer.MDGBurned = _layer.MDGBurned.add(_burnAmount);
    }

    function distributeRewards(address _to, uint256 _layerId) external onlyDistributor {
        require(_layerId < layerInfo.length, "layer not found");
        LayerInfo storage _layer = layerInfo[_layerId];
        require(_layer.endBlock < block.number, "running");
        require(_layer.MDGRewards.add(_layer.MDGBurned) <= IERC20(MDG).balanceOf(address(this)), "over balance");

        // mint unconverted MDG
        uint256 _mdgSupply = _layer.mdg.totalSupply();
        if (_mdgSupply > _layer.mdgConverted) {
            uint256 unconvertedMDG = _mdgSupply.sub(_layer.mdgConverted);
            _mintMDG(unconvertedMDG, _layer);
        }

        // transfer
        uint256 _rewardAmount = _layer.MDGRewards;
        uint256 _burnAmount = _layer.MDGBurned;
        _layer.MDGRewards = 0;
        _layer.MDGBurned = 0;
        IERC20(MDG).safeTransfer(_to, _rewardAmount);
        MidasGoldToken(MDG).burn(_burnAmount);
        totalMDGBurned = totalMDGBurned.add(_burnAmount);
    }

    function governanceRecoverUnsupported(IERC20 _token, address _to, uint256 _amount) external onlyOperator {
        _token.safeTransfer(_to, _amount);
    }
}