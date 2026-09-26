// SPDX-License-Identifier: MIT
// Modifications Copyright (c) 2026 Genius
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct FoundationFeePolicy {
    uint16 destinationBps;
    uint16 platformBps;
    uint16 creatorBps;
    uint16 buybackBps;
    address foundationVault;
}

interface ILoongFoundationFees {
    function currentFoundationFeePolicy() external view returns (FoundationFeePolicy memory);
}

interface ILoongFoundationCurve {
    function foundationFeePolicy() external view returns (FoundationFeePolicy memory);
    function toFoundation() external view returns (bool);
    function handoffBuyback() external returns (uint256);
}

library FoundationFeeMath {
    function total(FoundationFeePolicy memory p) internal pure returns (uint256) {
        return uint256(p.destinationBps) + p.platformBps + p.creatorBps + p.buybackBps;
    }

    function split(uint256 amount, FoundationFeePolicy memory p)
        internal
        pure
        returns (uint256 destination, uint256 platform, uint256 creator, uint256 buyback)
    {
        uint256 sum = total(p);
        if (sum == 0) return (0, 0, 0, 0);
        destination = Math.mulDiv(amount, p.destinationBps, sum);
        platform = Math.mulDiv(amount, p.platformBps, sum);
        buyback = Math.mulDiv(amount, p.buybackBps, sum);
        creator = amount - destination - platform - buyback;
    }

    /// @dev Cumulative apportionment bounds every consumed and remaining liability during a partial fill.
    function consume(uint256 amount, uint256 pending, uint256 destination, uint256 platform, uint256 burnAmount)
        internal
        pure
        returns (uint256 d, uint256 p, uint256 b)
    {
        d = Math.mulDiv(destination, amount, pending);
        uint256 throughPlatform = Math.mulDiv(destination + platform, amount, pending);
        uint256 throughBurn = Math.mulDiv(destination + platform + burnAmount, amount, pending);
        p = throughPlatform - d;
        b = throughBurn - throughPlatform;
    }
}
