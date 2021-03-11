// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/ISwap.sol";
import "../interfaces/IValueLiquidPair.sol";
import "../interfaces/IValueLiquidRouter.sol";
import "../interfaces/IValueLiquidFormula.sol";
import "../interfaces/IRewardPool.sol";
import "../interfaces/IMdgRewardPool.sol";

interface IBurnabledERC20 {
    function burn(uint256) external;
}

contract ReserveFund {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;
    address public strategist;

    // flags
    bool public initialized = false;
    bool public publicAllowed; // set to true to allow public to call rebalance()

    // price
    uint256 public mdgPriceToSell; // to rebalance if price is high
    uint256 public mdgPriceToBuy; // to rebalance if price is low

    uint256[] public balancePercents; // MDG, WBNB and BUSD portfolio percentage
    uint256[] public contractionPercents; // MDG, WBNB and BUSD portfolio when buyback MDG

    mapping(address => uint256) public maxAmountToTrade; // MDG, WBNB, BUSD

    address public mdg = address(0xC1eDCc306E6faab9dA629efCa48670BE4678779D); // [8]
    address public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c); // [10]
    address public busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56); // [19]
    address public vdollar = address(0x3F6ad3c13E3a6bB5655F09A95cA05B6FF4c3DCd6); // [2]

    address[] public vlpPairsToRemove;
    address[] public cakePairsToRemove;

    // Pancakeswap
    IUniswapV2Router public pancakeRouter = IUniswapV2Router(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    mapping(address => mapping(address => address[])) public pancakeswapPaths;

    IValueLiquidRouter public vswapRouter = IValueLiquidRouter(0xb7e19a1188776f32E8C2B790D9ca578F2896Da7C); // vSwapRouter
    IValueLiquidFormula public vswapFormula = IValueLiquidFormula(0x45f24BaEef268BB6d63AEe5129015d69702BCDfa); // vSwap Formula
    mapping(address => mapping(address => address[])) public vswapPaths;

    ISwap public vDollarSwap = ISwap(0x0a7E1964355020F85FED96a6D8eB10baaC457645);

    address public mdgRewardPool = address(0x8f0A813D39F019a2A98958eDbf5150d3a06Cd20f);

    address public vswapFarmingPool = address(0xd56339F80586c08B7a4E3a68678d16D37237Bd96);
    uint256 public vswapFarmingPoolId = 1;
    address public vswapFarmingPoolLpPairAddress = address(0x522361C3aa0d81D1726Fa7d40aA14505d0e097C9); // BUSD/WBNB
    address public vbswap = address(0x4f0ed527e8A95ecAA132Af214dFd41F30b361600); // vBSWAP (vSwap farming token)
    address public vbswapToWbnbPair = address(0x8DD39f0a49160cDa5ef1E2a2fA7396EEc7DA8267); // vBSWAP/WBNB 50-50

    address public mdgToWbnbPair = address(0x5D69a0e5E91d1E66459A76Da2a4D8863E97cD90d); // MDG/WBNB 70-30
    address public mdgToBusdPair = address(0xB10C30f83eBb92F5BaEf377168C4bFc9740d903c); // MDG/BUSD 70-30
    address public busdToWbnbPair = address(0x522361C3aa0d81D1726Fa7d40aA14505d0e097C9); // BUSD/WBNB 50-50

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ....

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event SwapToken(address inputToken, address outputToken, uint256 amount, uint256 amountReceived);
    event BurnToken(address token, uint256 amount);
    event RemoveLpPair(address pair, uint256 amount);
    event GetBackTokenFromProtocol(address token, uint256 amount);
    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "!operator");
        _;
    }

    modifier onlyStrategist() {
        require(strategist == msg.sender || operator == msg.sender, "!strategist");
        _;
    }

    modifier notInitialized() {
        require(!initialized, "initialized");
        _;
    }

    modifier checkPublicAllow() {
        require(publicAllowed || strategist == msg.sender || msg.sender == operator, "!strategist nor !publicAllowed");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _mdg,
        address _wbnb,
        address _busd,
        address _vdollar,
        IUniswapV2Router _pancakeRouter,
        IValueLiquidRouter _vswapRouter,
        IValueLiquidFormula _vswapFormula,
        ISwap _vDollarSwap
    ) public notInitialized {
        mdg = _mdg;
        wbnb = _wbnb;
        busd = _busd;
        vdollar = _vdollar;
        pancakeRouter = _pancakeRouter;
        vswapRouter = _vswapRouter;
        vswapFormula = _vswapFormula;
        vDollarSwap = _vDollarSwap;

        mdg = address(0xC1eDCc306E6faab9dA629efCa48670BE4678779D);
        wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
        busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
        vdollar = address(0x3F6ad3c13E3a6bB5655F09A95cA05B6FF4c3DCd6);

        vlpPairsToRemove = new address[](2);
        vlpPairsToRemove[0] = address(0x522361C3aa0d81D1726Fa7d40aA14505d0e097C9); // [1] WBNB-BUSD 50/50 Value LP
        vlpPairsToRemove[1] = address(0xeDD5a7b494abDe6C07B0c36775E3372f940e59b3); // [20] bCash-BUSD 70/30 Value LP

        cakePairsToRemove = new address[](3);
        cakePairsToRemove[0] = address(0xA527a61703D82139F8a06Bc30097cC9CAA2df5A6); // [3] CAKE/BNB
        cakePairsToRemove[1] = address(0x99d865Ed50D2C32c1493896810FA386c1Ce81D91); // [7] ETH/BETH
        cakePairsToRemove[2] = address(0xD65F81878517039E39c359434d8D8bD46CC4531F); // [6] MDO/BUSD

        mdgPriceToSell = 8 ether; // 8 BNB (~$2000)
        mdgPriceToBuy = 2 ether; // 2 BNB (~$500)

        balancePercents = [50, 450, 9500]; // MDG (0.5%), WBNB (90%), BUSD (4.5%) for rebalance target
        contractionPercents = [7000, 10, 2990]; // MDG (60%), WBNB (3.9%), BUSD (1%) for buying back MDG
        maxAmountToTrade[mdg] = 0.5 ether; // sell up to 0.5 MDG each time
        maxAmountToTrade[wbnb] = 10 ether; // sell up to 10 BNB each time
        maxAmountToTrade[busd] = 2500 ether; // sell up to 2500 BUSD each time

        mdgRewardPool = address(0x8f0A813D39F019a2A98958eDbf5150d3a06Cd20f);

        vswapFarmingPool = address(0xd56339F80586c08B7a4E3a68678d16D37237Bd96);
        vswapFarmingPoolId = 1;
        vswapFarmingPoolLpPairAddress = address(0x522361C3aa0d81D1726Fa7d40aA14505d0e097C9); // BUSD/WBNB
        vbswap = address(0x4f0ed527e8A95ecAA132Af214dFd41F30b361600); // vBSWAP (vSwap farming token)
        vbswapToWbnbPair = address(0x8DD39f0a49160cDa5ef1E2a2fA7396EEc7DA8267); // vBSWAP/WBNB 50-50

        mdgToWbnbPair = address(0x5D69a0e5E91d1E66459A76Da2a4D8863E97cD90d); // MDG/BUSD 70-30
        mdgToBusdPair = address(0xB10C30f83eBb92F5BaEf377168C4bFc9740d903c); // MDG/BUSD 70-30
        busdToWbnbPair = address(0x522361C3aa0d81D1726Fa7d40aA14505d0e097C9); // BUSD/WBNB 50-50

        vswapPaths[wbnb][busd] = [busdToWbnbPair];
        vswapPaths[busd][wbnb] = [busdToWbnbPair];

        vswapPaths[mdg][wbnb] = [mdgToWbnbPair];
        vswapPaths[wbnb][mdg] = [mdgToWbnbPair];

        vswapPaths[mdg][busd] = [mdgToBusdPair];
        vswapPaths[busd][mdg] = [mdgToBusdPair];

        vswapPaths[vbswap][wbnb] = [vbswapToWbnbPair];
        vswapPaths[wbnb][vbswap] = [vbswapToWbnbPair];

        publicAllowed = true;
        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setStrategist(address _strategist) external onlyOperator {
        strategist = _strategist;
    }

    function setVswapFarmingPool(IValueLiquidRouter _vswapRouter, address _vswapFarmingPool, uint256 _vswapFarmingPoolId, address _vswapFarmingPoolLpPairAddress, address _vbswap, address _vbswapToWbnbPair) external onlyOperator {
        vswapRouter = _vswapRouter;
        vswapFarmingPool = _vswapFarmingPool;
        vswapFarmingPoolId = _vswapFarmingPoolId;
        vswapFarmingPoolLpPairAddress = _vswapFarmingPoolLpPairAddress;
        vbswap = _vbswap;
        vbswapToWbnbPair = _vbswapToWbnbPair;
    }

    function setMdgFarmingPool(address _mdgRewardPool, address _mdg, address _mdgToWbnbPair) external onlyOperator {
        mdgRewardPool = _mdgRewardPool;
        mdg = _mdg;
        mdgToWbnbPair = _mdgToWbnbPair;
    }

    function setVswapPaths(address _inputToken, address _outputToken, address[] memory _path) external onlyOperator {
        delete vswapPaths[_inputToken][_outputToken];
        vswapPaths[_inputToken][_outputToken] = _path;
    }

    function setVlpPairsToRemove(address[] memory _vlpPairsToRemove) external onlyOperator {
        delete vlpPairsToRemove;
        vlpPairsToRemove = _vlpPairsToRemove;
    }

    function addVlpPairToRemove(address _pair) external onlyOperator {
        vlpPairsToRemove.push(_pair);
    }

    function setCakePairsToRemove(address[] memory _cakePairsToRemove) external onlyOperator {
        delete cakePairsToRemove;
        cakePairsToRemove = _cakePairsToRemove;
    }

    function addCakePairToRemove(address _pair) external onlyOperator {
        cakePairsToRemove.push(_pair);
    }

    function setPublicAllowed(bool _publicAllowed) external onlyStrategist {
        publicAllowed = _publicAllowed;
    }

    function setBalancePercents(uint256 _mdgPercent, uint256 _wbnbPercent, uint256 _busdPercent) external onlyStrategist {
        require(_mdgPercent.add(_wbnbPercent).add(_busdPercent) == 10000, "!100%");
        balancePercents[0] = _mdgPercent;
        balancePercents[1] = _wbnbPercent;
        balancePercents[2] = _busdPercent;
    }

    function setContractionPercents(uint256 _mdgPercent, uint256 _wbnbPercent, uint256 _busdPercent) external onlyStrategist {
        require(_mdgPercent.add(_wbnbPercent).add(_busdPercent) == 10000, "!100%");
        contractionPercents[0] = _mdgPercent;
        contractionPercents[1] = _wbnbPercent;
        contractionPercents[2] = _busdPercent;
    }

    function setMaxAmountToTrade(uint256 _mdgAmount, uint256 _wbnbAmount, uint256 _busdAmount) external onlyStrategist {
        maxAmountToTrade[mdg] = _mdgAmount;
        maxAmountToTrade[wbnb] = _wbnbAmount;
        maxAmountToTrade[busd] = _busdAmount;
    }

    function setMdgPriceToSell(uint256 _mdgPriceToSell) external onlyStrategist {
        require(_mdgPriceToSell >= 2 ether && _mdgPriceToSell <= 100 ether, "out of range"); // [2, 100] BNB
        mdgPriceToSell = _mdgPriceToSell;
    }

    function setMdgPriceToBuy(uint256 _mdgPriceToBuy) external onlyStrategist {
        require(_mdgPriceToBuy >= 0.5 ether && _mdgPriceToBuy <= 10 ether, "out of range"); // [0.5, 10] BNB
        mdgPriceToBuy = _mdgPriceToBuy;
    }

    function setPancakeswapPath(address _input, address _output, address[] memory _path) external onlyStrategist {
        pancakeswapPaths[_input][_output] = _path;
    }

    function grandFund(address _token, uint256 _amount, address _to) external onlyOperator {
        IERC20(_token).transfer(_to, _amount);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function tokenBalances() public view returns (uint256 _mdgBal, uint256 _wbnbBal, uint256 _busdBal, uint256 _totalBal) {
        _mdgBal = IERC20(mdg).balanceOf(address(this));
        _wbnbBal = IERC20(wbnb).balanceOf(address(this));
        _busdBal = IERC20(busd).balanceOf(address(this));
        _totalBal = _mdgBal.add(_wbnbBal).add(_busdBal);
    }

    function tokenPercents() public view returns (uint256 _mdgPercent, uint256 _wbnbPercent, uint256 _busdPercent) {
        (uint256 _mdgBal, uint256 _wbnbBal, uint256 _busdBal, uint256 _totalBal) = tokenBalances();
        if (_totalBal > 0) {
            _mdgPercent = _mdgBal.mul(10000).div(_totalBal);
            _wbnbPercent = _wbnbBal.mul(10000).div(_totalBal);
            _busdPercent = _busdBal.mul(10000).div(_totalBal);
        }
    }

    function exchangeRate(address _inputToken, address _outputToken, uint256 _tokenAmount) public view returns (uint256) {
        uint256[] memory amounts = vswapFormula.getAmountsOut(_inputToken, _outputToken, _tokenAmount, vswapPaths[_inputToken][_outputToken]);
        return amounts[amounts.length - 1];
    }

    function getMdgToBnbPrice() public view returns (uint256) {
        return exchangeRate(mdg, wbnb, 1 ether);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function rebalance() public checkPublicAllow {
        uint256 _mdgPrice = getMdgToBnbPrice();
        if (_mdgPrice >= mdgPriceToSell) {// expansion: sell MDG
            (uint256 _mdgBal, uint256 _wbnbBal, uint256 _busdBal, uint256 _totalBal) = tokenBalances();
            if (_totalBal > 0) {
                uint256 _mdgPercent = _mdgBal.mul(10000).div(_totalBal);
                uint256 _wbnbPercent = _wbnbBal.mul(10000).div(_totalBal);
                uint256 _busdPercent = _busdBal.mul(10000).div(_totalBal);
                if (_mdgPercent > balancePercents[0]) {
                    uint256 _sellingMdg = _mdgBal.mul(_mdgPercent.sub(balancePercents[0])).div(10000);
                    if (_wbnbPercent >= balancePercents[1]) {// enough WBNB
                        if (_busdPercent < balancePercents[2]) {// short of BUSD: buy BUSD
                            _vswapSwapToken(mdg, busd, _sellingMdg);
                        } else {
                            if (_wbnbPercent.sub(balancePercents[1]) <= _busdPercent.sub(balancePercents[2])) {// has more BUSD than WBNB: buy WBNB
                                _vswapSwapToken(mdg, wbnb, _sellingMdg);
                            } else {// has more WBNB than BUSD: buy BUSD
                                _vswapSwapToken(mdg, busd, _sellingMdg);
                            }
                        }
                    } else {// short of WBNB
                        if (_busdPercent >= balancePercents[2]) {// enough BUSD: buy WBNB
                            _vswapSwapToken(mdg, wbnb, _sellingMdg);
                        } else {// short of BUSD
                            uint256 _sellingMdgToWbnb = _sellingMdg.mul(95).div(100); // 95% to WBNB
                            _vswapSwapToken(mdg, wbnb, _sellingMdgToWbnb);
                            _vswapSwapToken(mdg, busd, _sellingMdg.sub(_sellingMdgToWbnb));
                        }
                    }
                }
            }
        }
    }

    function checkContraction() public checkPublicAllow {
        uint256 _mdgPrice = getMdgToBnbPrice();
        if (_mdgPrice <= mdgPriceToBuy && (msg.sender == operator || msg.sender == strategist)) {
            // contraction: buy MDG
            (uint256 _mdgBal, uint256 _wbnbBal, uint256 _busdBal, uint256 _totalBal) = tokenBalances();
            if (_totalBal > 0) {
                uint256 _mdgPercent = _mdgBal.mul(10000).div(_totalBal);
                if (_mdgPercent < contractionPercents[0]) {
                    uint256 _wbnbPercent = _wbnbBal.mul(10000).div(_totalBal);
                    uint256 _busdPercent = _busdBal.mul(10000).div(_totalBal);
                    uint256 _before = IERC20(mdg).balanceOf(address(this));
                    if (_wbnbPercent >= contractionPercents[1]) {
                        // enough WBNB
                        if (_busdPercent >= contractionPercents[2] && _busdPercent.sub(contractionPercents[2]) > _wbnbPercent.sub(contractionPercents[1])) {
                            // enough BUSD and has more BUSD than WBNB: sell BUSD
                            uint256 _sellingBusd = _busdBal.mul(_busdPercent.sub(contractionPercents[2])).div(10000);
                            _vswapSwapToken(busd, mdg, _sellingBusd);
                        } else {
                            // not enough BUSD or has less BUSD than WBNB: sell WBNB
                            uint256 _sellingWbnb = _wbnbBal.mul(_wbnbPercent.sub(contractionPercents[1])).div(10000);
                            _vswapSwapToken(wbnb, mdg, _sellingWbnb);
                        }
                    } else {
                        // short of WBNB
                        if (_busdPercent > contractionPercents[2]) {
                            // enough BUSD: sell BUSD
                            uint256 _sellingBusd = _busdBal.mul(_busdPercent.sub(contractionPercents[2])).div(10000);
                            _vswapSwapToken(busd, mdg, _sellingBusd);
                        }
                    }
                    uint256 _after = IERC20(mdg).balanceOf(address(this));
                    uint256 _bought = _after.sub(_before);
                    if (_bought > 0) {
                        IBurnabledERC20(mdg).burn(_bought);
                        emit BurnToken(mdg, _bought);
                    }
                }
            }
        }
    }

    function removeVlpPairs() public checkPublicAllow {
        uint256 _length = vlpPairsToRemove.length;
        for (uint256 i = 0; i < _length; i++) {
            address _pair = vlpPairsToRemove[i];
            uint256 _bal = IERC20(_pair).balanceOf(address(this));
            if (_bal > 0) {
                _vswapRemoveLiquidity(_pair, _bal);
                emit RemoveLpPair(_pair, _bal);
            }
        }
    }

    function removeCakePairs() public checkPublicAllow {
        uint256 _length = cakePairsToRemove.length;
        for (uint256 i = 0; i < _length; i++) {
            address _pair = cakePairsToRemove[i];
            uint256 _bal = IERC20(_pair).balanceOf(address(this));
            if (_bal > 0) {
                _cakeRemoveLiquidity(_pair, _bal);
                emit RemoveLpPair(_pair, _bal);
            }
        }
    }

    function workForReserveFund() external checkPublicAllow {
        rebalance();
        checkContraction();
        claimBuyBackAndBurnMdgFromVswapPool(vswapFarmingPoolId);
        claimAndBurnFromMdgPools();
        removeCakePairs();
    }

    function buyBackAndBurn(address _token, uint256 _amount) public onlyStrategist {
        uint256 _before = IERC20(mdg).balanceOf(address(this));
        _vswapSwapToken(_token, mdg, _amount);
        uint256 _after = IERC20(mdg).balanceOf(address(this));
        uint256 _bought = _after.sub(_before);
        if (_bought > 0) {
            IBurnabledERC20(mdg).burn(_bought);
            emit BurnToken(mdg, _bought);
        }
    }

    function forceSell(address _buyingToken, uint256 _mdgAmount) external onlyStrategist {
        require(getMdgToBnbPrice() >= mdgPriceToBuy, "price is too low to sell");
        _vswapSwapToken(mdg, _buyingToken, _mdgAmount);
    }

    function forceBuy(address _sellingToken, uint256 _sellingAmount) external onlyStrategist {
        require(getMdgToBnbPrice() <= mdgPriceToSell, "price is too high to buy");
        _vswapSwapToken(_sellingToken, mdg, _sellingAmount);
    }

    function forceBurn(uint256 _mdgAmount) external onlyOperator {
        IBurnabledERC20(mdg).burn(_mdgAmount);
        emit BurnToken(mdg, _mdgAmount);
    }

    function trimNonCoreToken(address _sellingToken) public onlyStrategist {
        require(_sellingToken != mdg && _sellingToken != busd && _sellingToken != wbnb, "core");
        uint256 _bal = IERC20(_sellingToken).balanceOf(address(this));
        if (_bal > 0) {
            _vswapSwapToken(_sellingToken, mdg, _bal);
        }
    }

    /* ========== FARM VSWAP POOL: STAKE BUSD/WBNB EARN VBSWAP ========== */

    function depositToVswapPool(uint256 _pid, address _lpAdd, uint256 _lpAmount) external onlyStrategist {
        IERC20(_lpAdd).safeIncreaseAllowance(vswapFarmingPool, _lpAmount);
        IRewardPool(vswapFarmingPool).deposit(_pid, _lpAmount);
    }

    function withdrawFromVswapPool(uint256 _pid, uint256 _lpAmount) public onlyStrategist {
        IRewardPool(vswapFarmingPool).withdraw(_pid, _lpAmount);
    }

    function exitVswapPool(uint256 _pid) external onlyStrategist {
        (uint256 _stakedAmount, ) = IRewardPool(vswapFarmingPool).userInfo(_pid, address(this));
        withdrawFromVswapPool(_pid, _stakedAmount);
    }

    function claimBuyBackAndBurnMdgFromVswapPool(uint256 _pid) public checkPublicAllow {
        IRewardPool(vswapFarmingPool).withdraw(_pid, 0);
        uint256 _vbswapBal = IERC20(vbswap).balanceOf(address(this));
        if (_vbswapBal > 0) {
            uint256 _wbnbBef = IERC20(wbnb).balanceOf(address(this));
            _vswapSwapToken(vbswap, wbnb, _vbswapBal);
            uint256 _wbnbAft = IERC20(wbnb).balanceOf(address(this));
            uint256 _boughtWbnb = _wbnbAft.sub(_wbnbBef);
            if (_boughtWbnb >= 2) {
                uint256 _mdgBef = IERC20(mdg).balanceOf(address(this));
                _vswapSwapToken(wbnb, mdg, _boughtWbnb);
                uint256 _mdgAft = IERC20(mdg).balanceOf(address(this));
                uint256 _boughtMdg = _mdgAft.sub(_mdgBef);
                if (_boughtMdg > 0) {
                    IBurnabledERC20(mdg).burn(_boughtMdg);
                    emit BurnToken(mdg, _boughtMdg);
                }
            }
        }
    }

    function pendingFromVswapPool(uint256 _pid) public view returns(uint256) {
        return IRewardPool(vswapFarmingPool).pendingReward(_pid, address(this));
    }

    function stakeAmountFromVswapPool(uint256 _pid) public view returns(uint256 _stakedAmount) {
        (_stakedAmount, ) = IRewardPool(vswapFarmingPool).userInfo(_pid, address(this));
    }

    /* ========== FARM MDG REWARD POOL: EARN MDG AND BURN ========== */

    function depositToMdgPool(uint256 _pid, address _lpAdd, uint256 _amount) external onlyStrategist {
        IERC20(_lpAdd).safeIncreaseAllowance(mdgRewardPool, _amount);
        IMdgRewardPool(mdgRewardPool).deposit(_pid, _amount);
    }

    function withdrawFromMdgPool(uint256 _pid, uint256 _amount) public onlyStrategist {
        IMdgRewardPool(mdgRewardPool).withdraw(_pid, _amount);
    }

    function exitMdgPool(uint256 _pid) external onlyStrategist {
        (uint256 _stakedAmount,,,) = IMdgRewardPool(mdgRewardPool).userInfo(_pid, address(this));
        withdrawFromMdgPool(_pid, _stakedAmount);
    }

    function claimAndBurnFromMdgPool(uint256 _pid) public checkPublicAllow {
        uint256 _mdgBef = IERC20(mdg).balanceOf(address(this));
        IMdgRewardPool(mdgRewardPool).withdraw(_pid, 0);
        uint256 _mdgAft = IERC20(mdg).balanceOf(address(this));
        uint256 _claimedMdg = _mdgAft.sub(_mdgBef);
        if (_claimedMdg > 0) {
            IBurnabledERC20(mdg).burn(_claimedMdg);
            emit BurnToken(mdg, _claimedMdg);
        }
    }

    function claimAndBurnFromMdgPools() public checkPublicAllow {
        for (uint256 _pid = 0; _pid <= 20; ++_pid) {
            uint256 _pending = pendingFromMdgPool(_pid);
            if (_pending > 0) {
                claimAndBurnFromMdgPool(_pid);
            }
        }
    }

    function pendingFromMdgPool(uint256 _pid) public view returns(uint256) {
        return IMdgRewardPool(mdgRewardPool).pendingReward(_pid, address(this));
    }

    function stakeAmountFromMdgPool(uint256 _pid) public view returns(uint256 _stakedAmount) {
        (_stakedAmount,,,) = IMdgRewardPool(mdgRewardPool).userInfo(_pid, address(this));
    }

    /* ========== VSWAPROUTER: SWAP & ADD LP & REMOVE LP ========== */

    function _vswapSwapToken(address _inputToken, address _outputToken, uint256 _amount) internal {
        IERC20(_inputToken).safeIncreaseAllowance(address(vswapRouter), _amount);
        uint256[] memory amountReceiveds = vswapRouter.swapExactTokensForTokens(_inputToken, _outputToken, _amount, 1, vswapPaths[_inputToken][_outputToken], address(this), block.timestamp.add(60));
        emit SwapToken(_inputToken, _outputToken, _amount, amountReceiveds[amountReceiveds.length - 1]);
    }

    function _vswapAddLiquidity(address _pair, address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired) internal {
        IERC20(_tokenA).safeIncreaseAllowance(address(vswapRouter), _amountADesired);
        IERC20(_tokenB).safeIncreaseAllowance(address(vswapRouter), _amountBDesired);
        vswapRouter.addLiquidity(_pair, _tokenA, _tokenB, _amountADesired, _amountBDesired, 0, 0, address(this), block.timestamp.add(60));
    }

    function _vswapRemoveLiquidity(address _pair, uint256 _liquidity) internal {
        address _tokenA = IValueLiquidPair(_pair).token0();
        address _tokenB = IValueLiquidPair(_pair).token1();
        IERC20(_pair).safeIncreaseAllowance(address(vswapRouter), _liquidity);
        vswapRouter.removeLiquidity(_pair, _tokenA, _tokenB, _liquidity, 1, 1, address(this), block.timestamp.add(60));
    }

    function _cakeRemoveLiquidity(address _pair, uint256 _liquidity) internal {
        address _tokenA = IValueLiquidPair(_pair).token0();
        address _tokenB = IValueLiquidPair(_pair).token1();
        IERC20(_pair).safeIncreaseAllowance(address(pancakeRouter), _liquidity);
        pancakeRouter.removeLiquidity(_tokenA, _tokenB, _liquidity, 1, 1, address(this), now.add(60));
    }

    function vdollarRemoveLiquidity(address _tokenAddress, uint256 _tokenAmount) public onlyStrategist {
        uint8 _tokenIndex = vDollarSwap.getTokenIndex(_tokenAddress);
        IERC20(_tokenAddress).safeIncreaseAllowance(address(vDollarSwap), _tokenAmount);
        vDollarSwap.removeLiquidityOneToken(_tokenAmount, _tokenIndex, _tokenAmount.mul(9000).div(10000), block.timestamp.add(60));
    }

    /* ========== EMERGENCY ========== */

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data) public onlyOperator returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, string("ReserveFund::executeTransaction: Transaction execution reverted."));

        emit ExecuteTransaction(target, value, signature, data);

        return returnData;
    }

    receive() external payable {}
}
