pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

contract MockERC20 is ERC20Burnable {
    constructor(string memory name, string memory symbol, uint8 _decimals) public ERC20(name, symbol) {
        _setupDecimals(_decimals);
    }

    function mint(address recipient_, uint256 amount_) external {
        _mint(recipient_, amount_);
    }

    function faucet(uint256 amt) external returns (bool) {
        _mint(msg.sender, amt);
        return true;
    }
}
