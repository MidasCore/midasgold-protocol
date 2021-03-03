// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IMdgLocker {
    function lockOf(address _account) external view returns (uint256);

    function canUnlockAmount(address _account) external view returns (uint256);

    function lock(address _account, uint256 _amount) external;

    function unlock() external;
}
