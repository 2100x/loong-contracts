// SPDX-License-Identifier: MIT
// Modifications Copyright (c) 2026 Genius
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;

import {LoongBuybackVault} from "../LoongBuybackVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {FeePolicySnapshot, ILoongFeePolicy} from "./ILaunchpadV2.sol";

/**
 * @notice The part of LoongMemeHook the factory depends on (spec 2.3, 2.5). Declared as an
 * interface so the factory (track A) and the hook (track B) never share a source file; the hook
 * satisfies it at the ABI level. Every name is the Pons name (D-11). Infinity types imported here
 * are MIT (spec 2.10), so this file keeps the MIT header.
 */
interface ILoongMemeHook is ILoongFeePolicy {
    function buybackVault() external view returns (LoongBuybackVault);
    function setBuybackEnabled(PoolId poolId, bool enabled) external;
    function factory() external view returns (address);
    function poolManager() external view returns (ICLPoolManager);
    function vault() external view returns (IVault);
    function hookFeeBps() external view returns (uint256);
    function getHooksRegistrationBitmap() external pure returns (uint16);
    function setFactory(address factory_) external;
    function registerPool(
        PoolKey calldata key,
        address memecoin,
        address creator,
        address buybackCreatorRecipient,
        uint16 creatorTaxBps,
        bool buybackEnabled,
        FeePolicySnapshot calldata policy
    ) external;
    function setCreatorFeeRecipient(PoolId poolId, address newRecipient) external;
}
