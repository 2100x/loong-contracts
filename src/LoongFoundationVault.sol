// SPDX-License-Identifier: MIT
// Modifications Copyright (c) 2026 Genius
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Shared foundation treasury. Withdrawals always go to its immutable controller.
contract LoongFoundationVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable controller;
    error InvalidController();
    error NotController();
    error InvalidValue();
    error TransferFailed();
    event Deposited(address indexed asset, address indexed depositor, uint256 amount);
    event Withdrawn(address indexed asset, address indexed controller, uint256 amount);

    /// @notice The controller is immutable and is the only native withdrawal destination, so a controller that
    /// cannot receive native would freeze every native destination share once the hook's one-shot
    /// `setFoundationVault` and the curves snapshot this vault. Construction therefore forwards a mandatory
    /// nonzero `msg.value` to the controller with empty calldata, exactly the call the native leg of `withdraw`
    /// makes, and reverts `InvalidController` if it fails. A zero-value probe would not be enough: a contract
    /// whose fallback is non-payable accepts a zero-value call and rejects every later one that carries value,
    /// so only a positive-value transfer proves the controller can be paid. The probe value is forwarded, never
    /// retained, so the vault still starts with a zero native balance; 1 wei is sufficient.
    constructor(address controller_) payable {
        if (controller_ == address(0)) revert InvalidController();
        if (msg.value == 0) revert InvalidValue();
        (bool ok,) = controller_.call{value: msg.value}("");
        if (!ok) revert InvalidController();
        controller = controller_;
    }

    function deposit(address asset, uint256 amount) external payable nonReentrant returns (uint256 received) {
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidValue();
            received = amount;
        } else {
            if (msg.value != 0) revert InvalidValue();
            uint256 senderBalanceBefore = IERC20(asset).balanceOf(msg.sender);
            uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            uint256 senderBalanceAfter = IERC20(asset).balanceOf(msg.sender);
            if (senderBalanceAfter > senderBalanceBefore || senderBalanceBefore - senderBalanceAfter != amount) {
                revert TransferFailed();
            }
            uint256 afterBalance = IERC20(asset).balanceOf(address(this));
            if (afterBalance < beforeBalance) revert TransferFailed();
            received = afterBalance - beforeBalance;
        }
        emit Deposited(asset, msg.sender, received);
    }

    /// @notice Native withdrawals can only ever pay `controller`; there is no alternate recipient.
    function withdraw(address asset, uint256 amount) external nonReentrant {
        if (msg.sender != controller) revert NotController();
        if (asset == address(0)) {
            (bool ok,) = payable(controller).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(controller, amount);
        }
        emit Withdrawn(asset, controller, amount);
    }
}
