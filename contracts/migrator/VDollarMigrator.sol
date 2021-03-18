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

import "../interfaces/ILiquidityMigrator.sol";
import "../interfaces/IStableSwapRouter.sol";

contract VDollarMigrator is ILiquidityMigrator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public operator;

    IERC20 public legacyVDollar = IERC20(0x3F6ad3c13E3a6bB5655F09A95cA05B6FF4c3DCd6);
    IERC20 public vDollar = IERC20(0x6334D757FDa9326fa1fAe7f9762485B722403ceE);

    address public legacyVDollarSwap = address(0x0a7E1964355020F85FED96a6D8eB10baaC457645);
    address public vDollarSwap = address(0x7569f9adabC99780B7A91B16666Bb985177D1DCa);

    IStableSwapRouter public router = IStableSwapRouter(0xC437B8D65EcdD43Cda92739E09ebd68BBE1965e1);

    constructor(
        address _legacyVDollar,
        address _vDollar,
        address _legacyVDollarSwap,
        address _vDollarSwap,
        address _router
    ) public {
        if (_legacyVDollar != address(0)) legacyVDollar = IERC20(legacyVDollar);
        if (_vDollar != address(0)) vDollar = IERC20(_vDollar);
        if (_legacyVDollarSwap != address(0)) legacyVDollarSwap = _legacyVDollarSwap;
        if (_vDollarSwap != address(0)) vDollarSwap = _vDollarSwap;
        if (_router != address(0)) router = IStableSwapRouter(_router);

        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "MdgRewardPool: caller is not the operator");
        _;
    }

    function migrate(IERC20 _legacy) external override returns (IERC20) {
        uint256 _legacyAmount = _legacy.balanceOf(msg.sender);
        require(_legacyAmount > 0, "lp balance must be greater than zero");
        require(address(_legacy) == address(legacyVDollar), "only support migrate legacy vDOLLAR");

        // convert legacyVDollar -> vDOLLAR and forward back
        _legacy.safeTransferFrom(msg.sender, address(this), _legacyAmount);
        _legacy.safeIncreaseAllowance(address(router), _legacyAmount);
        router.convert(legacyVDollarSwap, vDollarSwap, _legacyAmount, 1, now.add(60));
        require(vDollar.balanceOf(address(this)) >= _legacyAmount, "short of vDollar amount");
        vDollar.safeTransfer(msg.sender, _legacyAmount);

        return vDollar;
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        _token.safeTransfer(to, amount);
    }
}
