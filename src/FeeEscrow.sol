// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILoongFeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title FeeEscrow
 * @notice Pull-based ledger where curve, hook and buyback-vault fees wait for
 * their owners. Written to the `ILoongFeeEscrow` interface the forked stack
 * calls; the deployed original's source is not public.
 *
 * No owner, no pause, no admin path. The only way a balance leaves is its own
 * recipient calling `claim`/`claimToken`, so a compromised protocol key cannot
 * touch creator fees already credited.
 *
 * Crediting is permissionless on purpose: the depositor always pays for the
 * credit with its own funds, so an arbitrary caller can only give money away.
 * That keeps the escrow free of an allowlist that would have to be kept in
 * sync with every curve the factory deploys.
 */
contract FeeEscrow is ILoongFeeEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address recipient => uint256) private _native;
    mapping(address recipient => mapping(address token => uint256)) private _tokens;

    event Credited(address indexed recipient, address indexed depositor, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event TokenCredited(address indexed recipient, address indexed token, address indexed depositor, uint256 amount);
    event TokenClaimed(address indexed recipient, address indexed token, uint256 amount);

    error ZeroAddress();
    error NoBalance();
    error InexactTransfer(uint256 expected, uint256 received);
    error NativeTransferFailed();

    function credit(address recipient) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        _native[recipient] += msg.value;
        emit Credited(recipient, msg.sender, msg.value);
    }

    /**
     * @dev Pulls exactly `amount` from the caller. A fee-on-transfer asset would
     * leave the ledger promising more than it holds, so any shortfall reverts;
     * the hook and vault make the same exact-delivery check on their side.
     */
    function creditToken(address recipient, address token, uint256 amount) external nonReentrant {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
        _tokens[recipient][token] += amount;
        emit TokenCredited(recipient, token, msg.sender, amount);
    }

    function claim() external returns (uint256 amount) {
        return _claim(_native[msg.sender]);
    }

    function claim(uint256 amount) external returns (uint256) {
        return _claim(amount);
    }

    function claimToken(address token) external returns (uint256 amount) {
        return _claimToken(token, _tokens[msg.sender][token]);
    }

    function claimToken(address token, uint256 amount) external returns (uint256) {
        return _claimToken(token, amount);
    }

    function balanceOf(address recipient) external view returns (uint256) {
        return _native[recipient];
    }

    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return _tokens[recipient][token];
    }

    function _claim(uint256 amount) private nonReentrant returns (uint256) {
        if (amount == 0 || amount > _native[msg.sender]) revert NoBalance();
        _native[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Claimed(msg.sender, amount);
        return amount;
    }

    function _claimToken(address token, uint256 amount) private nonReentrant returns (uint256) {
        if (amount == 0 || amount > _tokens[msg.sender][token]) revert NoBalance();
        _tokens[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenClaimed(msg.sender, token, amount);
        return amount;
    }
}
