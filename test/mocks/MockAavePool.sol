// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPool } from "src/external/aave/IPool.sol";

contract MockAToken is ERC20 {
    address public pool;

    modifier onlyPool() {
        require(msg.sender == pool, "not pool");
        _;
    }

    constructor() ERC20("Mock Aave aToken", "maTOKEN") { }

    function setPool(address _pool) external {
        require(pool == address(0), "pool already set");
        pool = _pool;
    }

    function mint(address _to, uint256 _amount) external onlyPool {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external onlyPool {
        _burn(_from, _amount);
    }
}

contract MockAavePool is IPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    MockAToken public immutable aToken;

    constructor(IERC20 _asset) {
        asset = _asset;
        aToken = new MockAToken();
        aToken.setPool(address(this));
    }

    function supply(address _asset, uint256 _amount, address _onBehalfOf, uint16) external override {
        require(_asset == address(asset), "asset mismatch");
        asset.safeTransferFrom(msg.sender, address(this), _amount);
        aToken.mint(_onBehalfOf, _amount);
    }

    function withdraw(address _asset, uint256 _amount, address _to) external override returns (uint256) {
        require(_asset == address(asset), "asset mismatch");
        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 toWithdraw = _amount > balance ? balance : _amount;
        if (toWithdraw > 0) {
            aToken.burn(msg.sender, toWithdraw);
            asset.safeTransfer(_to, toWithdraw);
        }
        return toWithdraw;
    }

    function accrueInterest(address _onBehalfOf, uint256 _amount) external {
        aToken.mint(_onBehalfOf, _amount);
    }

    function aTokenAddress() external view returns (address) {
        return address(aToken);
    }
}
