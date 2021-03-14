// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ILayeredMdgToken {

    function cap() external view returns (uint256);

    function burn(uint256 _amount) external;

    function getBurnedAmount() external view returns (uint256);

    function isMinter(address _minter) external view returns (bool);

    function mint(address _to, uint256 _amount) external;
}
