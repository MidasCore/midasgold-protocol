// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiquidityMigrator {
    function migrate(IERC20 token) external returns (IERC20);
}
