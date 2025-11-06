// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Spark-like savings vault mock that mirrors the real VSR/chi/rho mechanics enough for tests.
///      Key testing conveniences:
///        - withdraw()/redeem() DO NOT require shares allowance (burns owner's shares directly)
///        - explicit yield controls: setVsr(), accrue(seconds), setChi()
///        - deposit cap logic, referral deposit overload, convert views
contract MockSparkVault is ERC20 {
    using SafeERC20 for IERC20;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant RAY = 1e27;
    uint256 public constant MAX_VSR = 1.000000021979553151239153027e27; // ~100% APY cap like real

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable underlying; // ERC-4626 style asset()
    uint8 public immutable decimalsOffset;

    // Spark rate accumulator state
    uint64 public rho; // last drip timestamp
    uint192 public chi; // accumulator in ray (starts at RAY)
    uint256 public vsr; // Vault Savings Rate (ray)

    // Caps (0 = unlimited)
    uint256 public depositCap;

    // Spark-ish signals
    event Drip(uint256 chi, uint256 diff);
    event Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares);
    event DepositCapSet(uint256 oldCap, uint256 newCap);
    event VsrSet(address indexed sender, uint256 oldVsr, uint256 newVsr);

    constructor(ERC20 _asset, string memory n, string memory s) ERC20(n, s) {
        underlying = _asset;
        decimalsOffset = _asset.decimals();
        chi = uint192(RAY);
        rho = uint64(block.timestamp);
        vsr = RAY; // 1.0x
    }

    /*//////////////////////////////////////////////////////////////
                             ERC-4626 SURFACE
    //////////////////////////////////////////////////////////////*/

    function asset() external view returns (address) {
        return address(underlying);
    }

    function decimals() public view override returns (uint8) {
        return decimalsOffset;
    }

    // ----- Core math views -----

    function nowChi() public view returns (uint256) {
        if (block.timestamp <= rho) return uint256(chi);
        return _rpow(vsr, block.timestamp - rho) * uint256(chi) / RAY;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * nowChi() / RAY;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * RAY / nowChi();
    }

    function totalAssets() public view returns (uint256) {
        // Standard Spark semantics: all shares are worth shares * chi / RAY
        return convertToAssets(totalSupply());
    }

    // ----- Limits -----

    function maxDeposit(address) public view returns (uint256) {
        if (depositCap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        return depositCap <= ta ? 0 : (depositCap - ta);
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        uint256 liq = underlying.balanceOf(address(this));
        uint256 usr = assetsOf(owner);
        return liq > usr ? usr : liq;
    }

    // ----- Mutating: deposit/mint/redeem/withdraw -----

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        uint256 md = maxDeposit(receiver);
        require(assets <= md, "deposit-cap");

        underlying.safeTransferFrom(msg.sender, address(this), assets);

        uint256 _chi = drip();
        shares = assets * RAY / _chi;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        emit Transfer(address(0), receiver, shares);
    }

    function deposit(uint256 assets, address receiver, uint16 referral) external returns (uint256 shares) {
        shares = deposit(assets, receiver);
        emit Referral(referral, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        uint256 _chi = drip();
        assets = _divup(shares * _chi, RAY);

        uint256 md = maxDeposit(receiver);
        require(assets <= md, "deposit-cap");

        underlying.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        emit Transfer(address(0), receiver, shares);
    }

    /// @dev Test-friendly: burns owner's shares directly (no allowance branch).
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        uint256 _chi = drip();
        shares = _divup(assets * RAY, _chi);

        _burn(owner, shares);
        _push(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Test-friendly: burns owner's shares directly (no allowance branch).
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        uint256 _chi = drip();
        assets = shares * _chi / RAY;

        _burn(owner, shares);
        _push(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                       SPARK OBSERVABILITY HELPERS
    //////////////////////////////////////////////////////////////*/

    // NOTE: Public state vars `vsr` (uint256) and `chi` (uint192) already
    //       auto-generate getters `vsr()` and `chi()`. No need to redeclare.

    /*//////////////////////////////////////////////////////////////
                            ADMIN-LIKE HOOKS
    //////////////////////////////////////////////////////////////*/

    function setDepositCap(uint256 newCap) external {
        emit DepositCapSet(depositCap, newCap);
        depositCap = newCap;
    }

    /// @notice Set new VSR (bounded to MAX_VSR); used by tests to control growth speed.
    function setVsr(uint256 newVsr) external {
        require(newVsr >= RAY, "vsr<1.0");
        require(newVsr <= MAX_VSR, "vsr>max");
        drip();
        emit VsrSet(msg.sender, vsr, newVsr);
        vsr = newVsr;
    }

    /// @notice Advance time logically and update chi as if `seconds_` elapsed.
    function accrue(uint256 seconds_) external {
        if (seconds_ == 0) return;
        uint256 nChi = _rpow(vsr, seconds_) * uint256(chi) / RAY;
        chi = uint192(nChi);
        rho = uint64(block.timestamp);
        emit Drip(nChi, 0);
    }

    /// @notice Force-set chi (e.g., jump to a target accumulator). Test-only convenience.
    function setChi(uint256 newChiRay) external {
        require(newChiRay <= type(uint192).max, "chi>u192");
        chi = uint192(newChiRay);
        rho = uint64(block.timestamp);
        emit Drip(newChiRay, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL UTILITIES
    //////////////////////////////////////////////////////////////*/

    function assetsOf(address owner_) public view returns (uint256) {
        return convertToAssets(balanceOf(owner_));
    }

    function drip() public returns (uint256 nChi) {
        uint256 chi_ = uint256(chi);
        uint256 rho_ = uint256(rho);
        uint256 diff;
        if (block.timestamp > rho_) {
            nChi = _rpow(vsr, block.timestamp - rho_) * chi_ / RAY;
            chi = uint192(nChi);
            rho = uint64(block.timestamp);
        } else {
            nChi = chi_;
        }
        emit Drip(nChi, diff);
    }

    function _push(address to, uint256 value) internal {
        require(value <= underlying.balanceOf(address(this)), "insufficient-liquidity");
        underlying.safeTransfer(to, value);
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x == 0 ? 0 : ((x - 1) / y) + 1;
        }
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := RAY }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := RAY }
                default { z := x }
                let half := div(RAY, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, RAY)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }
}
