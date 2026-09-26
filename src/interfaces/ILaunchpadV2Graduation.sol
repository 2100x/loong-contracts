// SPDX-License-Identifier: MIT
// Modifications Copyright (c) 2026 Genius
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;

/**
 * @notice Narrow surface a bonding curve needs from its factory: the callback
 * that graduates a token the instant a buy crosses the ETH threshold, and the
 * delay the factory's owner-only rescue waits out. Kept separate from
 * ILaunchpadV2.sol so the curve's compile unit stays free of the factory's
 * full launch-record surface.
 */
interface ILoongLaunchFactoryGraduation {
    function graduate(address token) external;
    // Matches the factory's public constant getter, so the curve and the
    // factory always agree on one rescue delay.
    // forge-lint: disable-next-line(mixed-case-function)
    function GRADUATION_RESCUE_DELAY() external view returns (uint256);
}
