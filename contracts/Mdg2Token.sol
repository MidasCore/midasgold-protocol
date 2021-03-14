// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/ILayeredMdgToken.sol";

contract Mdg2Token is ERC20, ILayeredMdgToken {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public governance = address(0xD025628eEe504330f1282C96B28a731E3995ff66);
    mapping(address => bool) private minters;
    uint256 public activeMinterAmount = 0;
    uint256 private burnedAmount = 0;

    uint256 private _cap; // 80000

    constructor(uint256 cap_) public ERC20("Midas Gold 2", "MDG2") {
        _cap = cap_;
        governance = msg.sender;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "!governance");
        _;
    }

    modifier onlyMinter() {
        require(msg.sender == governance || minters[msg.sender], "!governance && !minter");
        _;
    }

    function mint(address _to, uint256 _amount) external override onlyMinter {
        require(_cap > totalSupply(), "check _cap and totalSupply");
        if (_amount > _cap.sub(totalSupply())) {
            _amount = _cap.sub(totalSupply());
        }
        _mint(_to, _amount);
    }

    function burn(uint256 _amount) external override {
        uint256 balance = balanceOf(msg.sender);
        if (_amount > balance) {
            _amount = balance;
        }
        burnedAmount = burnedAmount.add(_amount);
        _burn(msg.sender, _amount);
    }

    function burnFrom(address _account, uint256 _amount) external {
        uint256 decreasedAllowance = allowance(_account, msg.sender).sub(_amount, "ERC20: burn amount exceeds allowance");
        _approve(_account, msg.sender, decreasedAllowance);
        burnedAmount = burnedAmount.add(_amount);
        _burn(_account, _amount);
    }

    function getBurnedAmount() external override view returns (uint256) {
        return burnedAmount;
    }

    function cap() external override view returns (uint256) {
        return _cap;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    function addMinter(address _minter) external onlyGovernance {
        if (!minters[_minter]) {
            activeMinterAmount++;
            minters[_minter] = true;
        }
    }

    function removeMinter(address _minter) external onlyGovernance {
        if (minters[_minter]) {
            minters[_minter] = false;
            activeMinterAmount--;
        }
    }

    function isMinter(address _minter) external override view returns (bool) {
        return minters[_minter];
    }

    // This function allows governance to take unsupported tokens out of the contract. This is in an effort to make someone whole, should they seriously mess up.
    // There is no guarantee governance will vote to return these. It also allows for removal of airdropped tokens.
    function governanceRecoverUnsupported(IERC20 _token, address _to, uint256 _amount) external onlyGovernance {
        _token.safeTransfer(_to, _amount);
    }
}
